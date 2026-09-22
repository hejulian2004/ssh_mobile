use std::sync::Arc;
use std::time::Instant;

use crate::connection::{ConnectionProfile, RouteTopology};

use super::super::peer_supervisor::PeerId;
use super::physical::PhysicalPath;
use super::registry::PathRegistry;
use super::PathHandle;

// Child modules so split impls can use `PeerPathManager`'s private fields.
#[path = "manager_close.rs"]
mod manager_close;
#[path = "manager_publish.rs"]
mod manager_publish;

/// The two path topologies owned by one peer supervisor.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PathKind {
    Direct,
    Relay,
}

impl PathKind {
    pub(super) fn from_profile(profile: ConnectionProfile) -> Self {
        match profile.topology() {
            RouteTopology::Direct => Self::Direct,
            RouteTopology::Relay => Self::Relay,
        }
    }
}

/// A bounded Direct probe can coexist with an already Ready Direct path.
/// Candidate execution remains in `ConnectivityAttempt`; this value is only
/// the peer-owned lifecycle/selection record.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct DirectProbe {
    pub(crate) generation: u64,
    pub(crate) required_capabilities: u8,
    pub(crate) deadline: Instant,
}

impl DirectProbe {
    fn extend(&mut self, required_capabilities: u8, deadline: Instant) {
        self.required_capabilities |= required_capabilities;
        self.deadline = self.deadline.max(deadline);
    }

    pub(crate) fn is_expired(&self, now: Instant) -> bool {
        now >= self.deadline
    }
}

/// Result of selecting a physical path. The enum never owns a carrier; the
/// caller must acquire a [`PathLease`](super::physical::PathLease) for the
/// selected topology.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PathSelection {
    Direct,
    Relay,
}

/// The lifecycle reason delivered to a carrier when its owner closes it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PathCloseReason {
    NormalRetire,
    HardClose,
    SecurityFailure,
}

/// Direct path state. A ready Direct path may have a separate bounded probe
/// in flight; [`PeerPathManager::direct_probe`] exposes that demand.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DirectPathState {
    None,
    Probe,
    Ready,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RelayPathState {
    None,
    Ready,
}

/// Per-peer physical path owner. Direct and Relay are independent slots, so
/// both may be Ready at once; business selection happens only when a caller
/// requests a capability and acquires a lease.
pub(crate) struct PeerPathManager {
    peer_id: PeerId,
    registry: Arc<PathRegistry>,
    direct_path: Option<Arc<PhysicalPath>>,
    direct_ready: Option<PathHandle>,
    relay_path: Option<Arc<PhysicalPath>>,
    relay_ready: Option<PathHandle>,
    draining_paths: Vec<Arc<PhysicalPath>>,
    direct_probe: Option<DirectProbe>,
    draining: bool,
    hard_closed: bool,
}
