use network_protocol::RouteType;
use network_transport::TransportKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RouteTopology {
    Direct,
    Relay,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RouteTransport {
    Quic,
    Tcp,
    Udp,
    WebSocket,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Route {
    topology: RouteTopology,
    transport: RouteTransport,
}

impl Route {
    pub const fn direct(transport: RouteTransport) -> Self {
        Self {
            topology: RouteTopology::Direct,
            transport,
        }
    }

    pub const fn relay(transport: RouteTransport) -> Self {
        Self {
            topology: RouteTopology::Relay,
            transport,
        }
    }

    pub const fn topology(self) -> RouteTopology {
        self.topology
    }

    pub const fn transport(self) -> RouteTransport {
        self.transport
    }

    pub const fn supports(self, capability: ConnectionCapability) -> bool {
        matches!(
            (self.topology, self.transport, capability),
            // Direct TCP/QUIC carry both reliable messages and byte streams (§17).
            (
                _,
                RouteTransport::Tcp | RouteTransport::Quic,
                ConnectionCapability::ReliableStream | ConnectionCapability::ReliableMessage
            ) | // WebSocket carries reliable messages only.
            (
                _,
                RouteTransport::WebSocket,
                ConnectionCapability::ReliableMessage
            ) | // Relay data plane forwards opaque bytes: Relay Stream fallback (§17).
            (
                RouteTopology::Relay,
                RouteTransport::WebSocket,
                ConnectionCapability::ReliableStream
            ) | // UDP and QUIC datagrams.
            (
                _,
                RouteTransport::Udp | RouteTransport::Quic,
                ConnectionCapability::UnreliableDatagram
            )
        )
    }

    /// Converts the current wire-era route projection into the composed form.
    /// Generic transports intentionally have no flat legacy enum projection.
    pub const fn from_wire(route: RouteType) -> Option<Self> {
        match route {
            RouteType::QuicDirect | RouteType::Lan => Some(Self::direct(RouteTransport::Quic)),
            RouteType::Relay => Some(Self::relay(RouteTransport::WebSocket)),
            RouteType::Unspecified => None,
        }
    }

    /// Returns the existing event projection when one is defined. Generic
    /// routes use the composed topology/transport event fields instead of
    /// expanding the legacy flat enum.
    pub const fn to_wire(self) -> Option<RouteType> {
        match (self.topology, self.transport) {
            (RouteTopology::Direct, RouteTransport::Quic) => Some(RouteType::QuicDirect),
            (RouteTopology::Relay, RouteTransport::WebSocket) => Some(RouteType::Relay),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionCapability {
    ReliableStream,
    ReliableMessage,
    UnreliableDatagram,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RouteCandidate {
    route: Route,
    available: bool,
}

impl RouteCandidate {
    pub const fn available(route: Route) -> Self {
        Self {
            route,
            available: true,
        }
    }

    pub const fn blocked(route: Route) -> Self {
        Self {
            route,
            available: false,
        }
    }

    pub const fn route(self) -> Route {
        self.route
    }

    pub const fn is_available(self) -> bool {
        self.available
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectionProfile {
    route: Route,
}

impl ConnectionProfile {
    pub const fn new(route: Route) -> Self {
        Self { route }
    }

    pub const fn route(self) -> Route {
        self.route
    }

    pub const fn topology(self) -> RouteTopology {
        self.route.topology()
    }

    pub const fn transport(self) -> RouteTransport {
        self.route.transport()
    }

    pub const fn supports(self, capability: ConnectionCapability) -> bool {
        self.route.supports(capability)
    }

    pub const fn for_route(route: RouteType) -> Option<Self> {
        match Route::from_wire(route) {
            Some(route) => Some(Self::new(route)),
            None => None,
        }
    }

    pub const fn for_generic(kind: TransportKind) -> Self {
        Self::for_generic_with_topology(kind, RouteTopology::Direct)
    }

    pub const fn for_generic_with_topology(kind: TransportKind, topology: RouteTopology) -> Self {
        let transport = match kind {
            TransportKind::Tcp => RouteTransport::Tcp,
            TransportKind::Udp => RouteTransport::Udp,
            TransportKind::WebSocket => RouteTransport::WebSocket,
        };
        let route = match topology {
            RouteTopology::Direct => Route::direct(transport),
            RouteTopology::Relay => Route::relay(transport),
        };
        Self::new(route)
    }
}

/// Selects the first available route that advertises the requested capability.
/// Candidate order is supplied by the Session/Route owner, so this helper does
/// not invent a second priority or retry policy. A blocked candidate is a
/// normal probe result, not a transport error or an application retry.
pub struct ConnectionRouteSelector;

impl ConnectionRouteSelector {
    pub fn select(
        capability: ConnectionCapability,
        candidates: impl IntoIterator<Item = RouteCandidate>,
    ) -> Option<ConnectionProfile> {
        candidates
            .into_iter()
            .filter(|candidate| candidate.is_available())
            .map(RouteCandidate::route)
            .map(ConnectionProfile::new)
            .find(|profile| profile.supports(capability))
    }
}
