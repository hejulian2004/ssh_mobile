//! Connection-layer capabilities shared by route selection and generic native
//! transport primitives.
//!
//! This layer deliberately does not own a Session, Delivery queue, or
//! application payload. It translates the transport primitive into a stable
//! capability and lets higher layers choose a route without depending on a
//! concrete TCP/UDP/WebSocket implementation.

mod generic;
mod profile;

/// Identity of one generic TCP/WebSocket route carrier.
///
/// This counter is independent of [`crate::connect::PathHandle`] ids. Loss
/// detection and inbound frame routing must compare this value with the
/// carrier stored on the physical path, never with the path registry id.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub(crate) struct GenericRouteId(u64);

impl GenericRouteId {
    pub(crate) const fn new(raw: u64) -> Self {
        Self(raw)
    }

    pub(crate) const fn raw(self) -> u64 {
        self.0
    }
}

impl std::fmt::Display for GenericRouteId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

#[allow(unused_imports)]
pub(crate) use generic::ConnectionError;
pub use generic::GenericConnection;
pub(crate) use generic::{
    decode_generic_frame, prepare_generic_route, GenericFrameKind, GenericInboundFrame,
    GenericRouteHandle, GenericRouteRuntime, GENERIC_FRAME_HEADER_BYTES,
    GENERIC_ROUTE_CHANNEL_CAPACITY,
};
pub use profile::{
    ConnectionCapability, ConnectionProfile, ConnectionRouteSelector, Route, RouteCandidate,
    RouteTopology, RouteTransport,
};

#[cfg(test)]
use generic::encode_generic_frame;
#[cfg(test)]
pub(crate) use generic::{test_blocking_generic_route, TestBlockingGenericRoute};

#[cfg(test)]
use network_transport::TransportError;
#[cfg(test)]
use std::sync::Arc;
#[cfg(test)]
use tokio::sync::mpsc;

#[cfg(test)]
use network_protocol::RouteType;

#[cfg(test)]
use crate::task_supervisor::CancellationToken;

#[cfg(test)]
#[path = "../tests/connection.rs"]
mod tests;
