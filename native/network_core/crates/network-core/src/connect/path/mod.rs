//! Peer-owned physical paths and bounded business leases.
//!
//! A [`PeerPathManager`] owns the physical carriers for one peer.  The
//! registry only indexes weak references so it can revoke paths during peer
//! teardown without becoming a second carrier owner.  [`PathHandle`] is a
//! copyable, non-owning identity; [`PathLease`] holds the explicit reference
//! that keeps one [`PhysicalPath`] alive for a borrower and releases it when
//! the operation ends.

use std::sync::Arc;
#[cfg(test)]
use std::sync::Mutex;
#[cfg(test)]
use std::time::{Duration, Instant};

use network_relay::RelayDataClient;
use quinn::Connection;

use crate::connection::{ConnectionProfile, GenericRouteHandle};
#[cfg(test)]
use crate::connection::{GenericFrameKind, RouteTopology};
#[cfg(test)]
use crate::errors::CoreNetworkError;

use super::peer_supervisor::PeerId;

mod active_route;
mod generic_route;
mod manager;
mod physical;
mod registry;

#[cfg(test)]
pub(crate) use active_route::PathCarrier;
pub(crate) use active_route::{callback_path_carrier, ActiveRoute, StreamCarrier};
pub(crate) use generic_route::GenericRouteScope;
#[cfg(test)]
pub(crate) use manager::{DirectPathState, PathCloseReason, RelayPathState};
pub(crate) use manager::{DirectProbe, PathKind, PathSelection, PeerPathManager};
pub(crate) use physical::{PathLease, PathProjection};
pub(crate) use registry::PathRegistry;

#[cfg(test)]
use active_route::send_route_view;

pub(crate) const MAX_READY_PATHS_PER_PEER: usize = 8;
pub(crate) const MAX_PATH_LEASES: usize = 32;

#[derive(Clone)]
enum RouteViewCarrier {
    Quic(Connection),
    Generic(GenericRouteHandle),
    #[cfg(test)]
    GenericTest(GenericRouteHandle),
    Relay(Option<Arc<RelayDataClient>>),
}

#[derive(Clone)]
struct RouteView {
    profile: ConnectionProfile,
    carrier: RouteViewCarrier,
}

/// A metadata-only carrier used by the compatibility helper and unit tests.
/// Real connection admission should use
/// [`PeerPathManager::publish_ready_with_carrier`].
struct NoopPathCarrier;

/// Adapter used by the path owner when a caller has an authenticated
/// [`ActiveRoute`] in hand. The route is moved into the physical path; a
/// projection or handle never receives a clone of it.
struct ActiveRouteCarrier {
    route: Option<ActiveRoute>,
}

/// A non-owning identity for one physical path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PathHandle {
    id: u64,
    peer_id: PeerId,
    profile: ConnectionProfile,
    capability_mask: u8,
}

impl PathHandle {
    pub(crate) fn id(&self) -> u64 {
        self.id
    }

    pub(crate) fn peer_id(&self) -> &PeerId {
        &self.peer_id
    }

    pub(crate) fn profile(&self) -> ConnectionProfile {
        self.profile
    }

    pub(crate) fn capability_mask(&self) -> u8 {
        self.capability_mask
    }

    pub(crate) fn kind(&self) -> PathKind {
        PathKind::from_profile(self.profile)
    }
}

#[cfg(test)]
#[path = "../../tests/connect/path.rs"]
mod tests;
