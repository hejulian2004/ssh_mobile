use std::sync::Arc;
use std::time::Instant;

use network_relay::RelayDataClient;
use quinn::Connection;

use crate::connection::GenericRouteId;

use super::super::active_route::StreamCarrier;
use super::super::physical::PhysicalPath;
use super::super::PathHandle;
use super::{PathCloseReason, PeerPathManager};

impl PeerPathManager {
    /// Close the current Direct path when `route_id` matches its generic
    /// carrier. `None` closes whatever Direct path is ready. Identity is read
    /// from the carrier and does not consume a business lease.
    pub(crate) fn close_ready_direct(
        &mut self,
        route_id: Option<GenericRouteId>,
    ) -> Option<PathHandle> {
        let matches = match route_id {
            None => self.direct_ready.is_some(),
            Some(route_id) => self.direct_path.as_ref().is_some_and(|path| {
                path.stream_carrier()
                    .is_some_and(|carrier| generic_carrier_id(&carrier) == Some(route_id))
            }),
        };
        if !matches {
            return None;
        }
        let handle = self.direct_ready.clone()?;
        self.hard_close_direct();
        Some(handle)
    }

    /// Close the current Direct path when it still owns this QUIC connection.
    /// The comparison does not acquire a lease, so a saturated borrower set
    /// cannot hide a disconnect.
    pub(crate) fn close_ready_direct_connection(
        &mut self,
        connection: &Connection,
    ) -> Option<PathHandle> {
        let matches = self.direct_path.as_ref().is_some_and(|path| {
            path.connection()
                .is_some_and(|candidate| candidate.stable_id() == connection.stable_id())
        });
        if !matches {
            return None;
        }
        let handle = self.direct_ready.clone()?;
        self.hard_close_direct();
        Some(handle)
    }

    /// Close the current Relay path. When `data` is set, the path must still
    /// own that exact data client.
    pub(crate) fn close_ready_relay(
        &mut self,
        data: Option<&Arc<RelayDataClient>>,
    ) -> Option<PathHandle> {
        let matches = match data {
            None => self.relay_ready.is_some(),
            Some(data) => self.relay_path.as_ref().is_some_and(|path| {
                path.relay_data()
                    .is_some_and(|current| Arc::ptr_eq(&current, data))
            }),
        };
        if !matches {
            return None;
        }
        let handle = self.relay_ready.clone()?;
        self.hard_close_relay();
        Some(handle)
    }

    pub(crate) fn current_relay_data(&self) -> Option<Arc<RelayDataClient>> {
        self.relay_path.as_ref().and_then(|path| path.relay_data())
    }

    pub(crate) fn normal_drain(&mut self) {
        self.draining = true;
        self.direct_probe = None;
        self.retire_all(PathCloseReason::NormalRetire);
        self.reap_draining_paths();
    }

    pub(crate) fn hard_close(&mut self) {
        self.hard_closed = true;
        self.draining = true;
        self.direct_probe = None;
        self.retire_all(PathCloseReason::HardClose);
        self.close_draining_paths(PathCloseReason::HardClose);
    }

    pub(crate) fn hard_close_relay(&mut self) {
        if let Some(path) = self.take_relay() {
            self.retire_path(path, PathCloseReason::HardClose);
        }
    }

    /// Hard-close Relay only when the current owner still matches the
    /// caller's observed handle. The identity check and carrier retirement
    /// deliberately happen under the same manager lock.
    pub(crate) fn hard_close_relay_if_handle(
        &mut self,
        expected: &PathHandle,
    ) -> Option<PathHandle> {
        let current = self.relay_ready.as_ref()?;
        if current != expected {
            return None;
        }
        let closed = current.clone();
        self.hard_close_relay();
        Some(closed)
    }

    pub(crate) fn hard_close_direct(&mut self) {
        self.direct_probe = None;
        if let Some(path) = self.take_direct() {
            self.retire_path(path, PathCloseReason::HardClose);
        }
    }

    /// Hard-close Direct only when the current owner still matches the
    /// caller's observed handle. The identity check and carrier retirement
    /// deliberately happen under the same manager lock.
    pub(crate) fn hard_close_direct_if_handle(
        &mut self,
        expected: &PathHandle,
    ) -> Option<PathHandle> {
        let current = self.direct_ready.as_ref()?;
        if current != expected {
            return None;
        }
        let closed = current.clone();
        self.hard_close_direct();
        Some(closed)
    }

    /// Security failures use the hard-close path so no existing lease can
    /// keep a compromised carrier usable.
    pub(crate) fn security_failure(&mut self) {
        self.hard_closed = true;
        self.draining = true;
        self.direct_probe = None;
        self.retire_all(PathCloseReason::SecurityFailure);
        self.close_draining_paths(PathCloseReason::SecurityFailure);
    }

    pub(crate) fn record_activity(&self) {
        if let Some(path) = self.direct_path.as_ref() {
            path.record_activity();
        }
        if let Some(path) = self.relay_path.as_ref() {
            path.record_activity();
        }
    }

    /// Retire every Ready path that has had no borrower for the fixed 60s
    /// ephemeral-path window. The caller supplies `now` so tests do not sleep.
    pub(crate) fn retire_ephemeral(&mut self, now: Instant) -> usize {
        if self.draining || self.hard_closed {
            return 0;
        }

        let direct_expired = self
            .direct_path
            .as_ref()
            .is_some_and(|path| path.is_ephemeral_idle(now));
        let relay_expired = self
            .relay_path
            .as_ref()
            .is_some_and(|path| path.is_ephemeral_idle(now));
        let mut retired = 0;
        if direct_expired {
            if let Some(path) = self.take_direct() {
                self.retire_path(path, PathCloseReason::NormalRetire);
                retired += 1;
            }
        }
        if relay_expired {
            if let Some(path) = self.take_relay() {
                self.retire_path(path, PathCloseReason::NormalRetire);
                retired += 1;
            }
        }
        retired
    }

    pub(crate) fn ephemeral_idle(&self, now: Instant) -> bool {
        !self.draining
            && !self.hard_closed
            && (self.direct_path.is_some() || self.relay_path.is_some())
            && self
                .direct_path
                .as_ref()
                .is_none_or(|path| path.is_ephemeral_idle(now))
            && self
                .relay_path
                .as_ref()
                .is_none_or(|path| path.is_ephemeral_idle(now))
    }

    pub(super) fn take_direct(&mut self) -> Option<Arc<PhysicalPath>> {
        self.direct_ready = None;
        self.direct_path.take()
    }

    pub(super) fn take_relay(&mut self) -> Option<Arc<PhysicalPath>> {
        self.relay_ready = None;
        self.relay_path.take()
    }

    pub(super) fn path_for_handle(&self, handle: &PathHandle) -> Option<&Arc<PhysicalPath>> {
        self.direct_path
            .as_ref()
            .filter(|path| path.handle() == handle)
            .or_else(|| {
                self.relay_path
                    .as_ref()
                    .filter(|path| path.handle() == handle)
            })
            .or_else(|| {
                self.draining_paths
                    .iter()
                    .find(|path| path.handle() == handle)
            })
    }

    pub(super) fn retire_path(&mut self, path: Arc<PhysicalPath>, reason: PathCloseReason) {
        let handle = path.handle().clone();
        match reason {
            PathCloseReason::NormalRetire => {
                let _ = self.registry.drain(&handle);
                path.retire_normal();
                if path.is_active() {
                    self.draining_paths.push(path);
                }
            }
            PathCloseReason::HardClose => {
                let _ = self.registry.revoke(&handle);
                path.close_with_reason(PathCloseReason::HardClose);
            }
            PathCloseReason::SecurityFailure => {
                let _ = self.registry.security_failure(&handle);
                path.close_with_reason(PathCloseReason::SecurityFailure);
            }
        }
    }

    fn close_draining_paths(&mut self, reason: PathCloseReason) {
        for path in self.draining_paths.drain(..) {
            path.close_with_reason(reason);
        }
    }

    fn reap_draining_paths(&mut self) {
        self.draining_paths.retain(|path| path.is_active());
    }

    fn retire_all(&mut self, reason: PathCloseReason) {
        let direct = self.take_direct();
        let relay = self.take_relay();
        if let Some(path) = direct {
            self.retire_path(path, reason);
        }
        if let Some(path) = relay {
            self.retire_path(path, reason);
        }
    }
}

impl Drop for PeerPathManager {
    fn drop(&mut self) {
        self.hard_close();
    }
}

fn generic_carrier_id(carrier: &StreamCarrier) -> Option<GenericRouteId> {
    match carrier {
        StreamCarrier::Generic(handle) => Some(handle.id()),
        #[cfg(test)]
        StreamCarrier::GenericTest(handle) => Some(handle.id()),
        StreamCarrier::Quic(_) | StreamCarrier::Relay(_) => None,
    }
}
