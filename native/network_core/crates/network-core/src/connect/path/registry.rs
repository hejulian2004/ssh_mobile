use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Instant;

use crate::connection::{ConnectionProfile, RouteTopology, RouteTransport};
use crate::errors::CoreNetworkError;

use super::super::peer_supervisor::PeerId;
use super::active_route::PathCarrier;
use super::manager::PathCloseReason;
use super::physical::{PathLease, PhysicalPath};
use super::{PathHandle, MAX_READY_PATHS_PER_PEER};

/// Weak path index used by runtime-level peer teardown and by borrowed handle
/// lookup. It never owns a carrier; the corresponding
/// [`PeerPathManager`](super::manager::PeerPathManager) owns every strong
/// [`PhysicalPath`] reference.
#[derive(Default)]
pub(crate) struct PathRegistry {
    next_id: AtomicU64,
    paths: Mutex<HashMap<PeerId, HashMap<u64, Weak<PhysicalPath>>>>,
}

impl PathRegistry {
    pub(crate) fn new() -> Self {
        Self {
            next_id: AtomicU64::new(1),
            paths: Mutex::new(HashMap::new()),
        }
    }

    pub(super) fn create_path(
        &self,
        peer_id: &PeerId,
        profile: ConnectionProfile,
        carrier: Box<dyn PathCarrier>,
        created_at: Instant,
    ) -> Result<Arc<PhysicalPath>, CoreNetworkError> {
        let capability_mask = super::super::profile_capability_mask(profile);
        if capability_mask == 0 {
            carrier.close(PathCloseReason::HardClose);
            return Err(CoreNetworkError::CapabilityUnavailable);
        }

        let mut paths = self.paths.lock().expect("path registry lock");
        let peer_paths = paths.entry(peer_id.clone()).or_default();
        peer_paths.retain(|_, path| path.strong_count() > 0);
        if peer_paths.len() >= MAX_READY_PATHS_PER_PEER {
            carrier.close(PathCloseReason::HardClose);
            return Err(CoreNetworkError::ResourceLimit("ready paths"));
        }

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let handle = PathHandle {
            id,
            peer_id: peer_id.clone(),
            profile,
            capability_mask,
        };
        let path = PhysicalPath::new(handle, carrier, created_at);
        peer_paths.insert(id, Arc::downgrade(&path));
        Ok(path)
    }

    pub(super) fn lookup(&self, handle: &PathHandle) -> Option<Arc<PhysicalPath>> {
        let mut paths = self.paths.lock().expect("path registry lock");
        let peer_id = handle.peer_id().clone();
        let (path, empty) = match paths.get_mut(&peer_id) {
            Some(peer_paths) => {
                let path = peer_paths
                    .get(&handle.id())
                    .and_then(Weak::upgrade)
                    .filter(|path| path.handle() == handle);
                if path.is_none() {
                    peer_paths.remove(&handle.id());
                }
                (path, peer_paths.is_empty())
            }
            None => (None, false),
        };
        if empty {
            paths.remove(&peer_id);
        }
        path
    }

    fn take_entry(&self, handle: &PathHandle) -> Option<Weak<PhysicalPath>> {
        let mut paths = self.paths.lock().expect("path registry lock");
        let peer_id = handle.peer_id().clone();
        let (entry, empty) = match paths.get_mut(&peer_id) {
            Some(peer_paths) => {
                let entry = peer_paths.remove(&handle.id());
                (entry, peer_paths.is_empty())
            }
            None => (None, false),
        };
        if empty {
            paths.remove(&peer_id);
        }
        entry
    }

    pub(crate) fn acquire(&self, handle: &PathHandle) -> Result<PathLease, CoreNetworkError> {
        self.lookup(handle)
            .ok_or(CoreNetworkError::StaleAttempt)?
            .try_acquire()
    }

    /// Select the best indexed ready path for a capability without making the
    /// registry a route owner. A stale weak entry is simply skipped.
    pub(crate) fn select_compatible_ready_path(
        &self,
        peer_id: &PeerId,
        required_capabilities: u8,
    ) -> Result<PathLease, CoreNetworkError> {
        let candidates = {
            let mut paths = self.paths.lock().expect("path registry lock");
            let Some(peer_paths) = paths.get_mut(peer_id) else {
                return Err(CoreNetworkError::NoRoute);
            };
            let candidates = peer_paths
                .values()
                .filter_map(Weak::upgrade)
                .collect::<Vec<_>>();
            peer_paths.retain(|_, path| path.strong_count() > 0);
            candidates
        };

        let mut candidates = candidates;
        candidates.sort_by_key(|path| (path_preference(path.profile()), path.handle().id()));
        for path in candidates.into_iter().rev() {
            if !path.is_acquirable(required_capabilities) {
                continue;
            }
            match path.try_acquire() {
                Ok(lease) => return Ok(lease),
                Err(CoreNetworkError::StaleAttempt) => continue,
                Err(error) => return Err(error),
            }
        }
        Err(CoreNetworkError::NoRoute)
    }

    pub(crate) fn revoke(&self, handle: &PathHandle) -> bool {
        let Some(entry) = self.take_entry(handle) else {
            return false;
        };
        if let Some(path) = entry.upgrade() {
            path.close_with_reason(PathCloseReason::HardClose);
        }
        true
    }

    /// Normal retirement removes the weak index immediately, then lets the
    /// physical owner close after any existing leases drain.
    pub(crate) fn drain(&self, handle: &PathHandle) -> bool {
        let Some(entry) = self.take_entry(handle) else {
            return false;
        };
        if let Some(path) = entry.upgrade() {
            path.retire_normal();
        }
        true
    }

    pub(crate) fn security_failure(&self, handle: &PathHandle) -> bool {
        let Some(entry) = self.take_entry(handle) else {
            return false;
        };
        if let Some(path) = entry.upgrade() {
            path.close_with_reason(PathCloseReason::SecurityFailure);
        }
        true
    }

    pub(crate) fn lease_count(&self, handle: &PathHandle) -> Option<usize> {
        self.lookup(handle).map(|path| path.lease_count())
    }

    pub(super) fn is_acquirable(&self, handle: &PathHandle) -> bool {
        self.lookup(handle)
            .is_some_and(|path| path.is_acquirable(0))
    }

    pub(crate) fn revoke_peer(&self, peer_id: &PeerId) -> usize {
        let entries = self
            .paths
            .lock()
            .expect("path registry lock")
            .remove(peer_id)
            .map(|paths| paths.into_values().collect::<Vec<_>>())
            .unwrap_or_default();
        let count = entries.len();
        for entry in entries {
            if let Some(path) = entry.upgrade() {
                path.close_with_reason(PathCloseReason::HardClose);
            }
        }
        count
    }
}

fn path_preference(profile: ConnectionProfile) -> u8 {
    match (profile.topology(), profile.transport()) {
        (RouteTopology::Direct, RouteTransport::Quic) => 4,
        (RouteTopology::Direct, RouteTransport::Tcp) => 3,
        (RouteTopology::Direct, RouteTransport::WebSocket) => 2,
        (RouteTopology::Relay, _) => 1,
        _ => 0,
    }
}
