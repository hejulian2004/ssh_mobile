use std::sync::{Arc, Mutex, Weak};
use std::time::Instant;

use network_relay::RelayDataClient;
use quinn::Connection;

use crate::connection::{ConnectionProfile, GenericFrameKind};
use crate::errors::CoreNetworkError;

use super::active_route::{close_carrier, PathCarrier, StreamCarrier};
use super::manager::PathCloseReason;
use super::{PathHandle, MAX_PATH_LEASES};

/// A non-owning runtime projection of a path. It is safe to retain as an
/// index entry, but it cannot keep the physical carrier alive. An operation
/// must explicitly upgrade it into a [`PathLease`] before using the path.
#[derive(Clone)]
pub(crate) struct PathProjection {
    pub(super) handle: PathHandle,
    pub(super) path: Weak<PhysicalPath>,
}

impl PathProjection {
    pub(crate) fn handle(&self) -> &PathHandle {
        &self.handle
    }

    pub(crate) fn is_alive(&self) -> bool {
        self.path.upgrade().is_some_and(|path| path.is_active())
    }

    pub(crate) fn acquire(&self) -> Result<PathLease, CoreNetworkError> {
        let path = self.path.upgrade().ok_or(CoreNetworkError::StaleAttempt)?;
        if path.handle() != &self.handle {
            return Err(CoreNetworkError::StaleAttempt);
        }
        path.try_acquire()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PhysicalPathState {
    Ready,
    Draining,
    Closed(PathCloseReason),
}

struct PhysicalPathInner {
    state: PhysicalPathState,
    carrier: Option<Box<dyn PathCarrier>>,
    leases: usize,
    last_activity: Instant,
}

/// The sole owner of one authenticated Direct or Relay carrier.
pub(crate) struct PhysicalPath {
    handle: PathHandle,
    inner: Mutex<PhysicalPathInner>,
}

impl PhysicalPath {
    pub(super) fn new(
        handle: PathHandle,
        carrier: Box<dyn PathCarrier>,
        created_at: Instant,
    ) -> Arc<Self> {
        Arc::new(Self {
            handle,
            inner: Mutex::new(PhysicalPathInner {
                state: PhysicalPathState::Ready,
                carrier: Some(carrier),
                leases: 0,
                last_activity: created_at,
            }),
        })
    }

    pub(super) fn handle(&self) -> &PathHandle {
        &self.handle
    }

    pub(super) fn profile(&self) -> ConnectionProfile {
        self.handle.profile()
    }

    fn supports(&self, required_capabilities: u8) -> bool {
        self.handle.capability_mask() & required_capabilities == required_capabilities
    }

    pub(super) fn is_ready(&self) -> bool {
        matches!(
            self.inner.lock().expect("physical path lock").state,
            PhysicalPathState::Ready
        )
    }

    pub(super) fn is_active(&self) -> bool {
        matches!(
            self.inner.lock().expect("physical path lock").state,
            PhysicalPathState::Ready | PhysicalPathState::Draining
        )
    }

    pub(super) fn is_acquirable(&self, required_capabilities: u8) -> bool {
        let inner = self.inner.lock().expect("physical path lock");
        matches!(inner.state, PhysicalPathState::Ready) && self.supports(required_capabilities)
    }

    pub(super) fn lease_count(&self) -> usize {
        self.inner.lock().expect("physical path lock").leases
    }

    pub(super) fn has_carrier(&self) -> bool {
        self.inner
            .lock()
            .expect("physical path lock")
            .carrier
            .is_some()
    }

    pub(super) fn connection(&self) -> Option<Connection> {
        self.inner
            .lock()
            .expect("physical path lock")
            .carrier
            .as_ref()
            .and_then(|carrier| carrier.connection())
    }

    pub(super) fn stream_carrier(&self) -> Option<StreamCarrier> {
        self.inner
            .lock()
            .expect("physical path lock")
            .carrier
            .as_ref()
            .and_then(|carrier| carrier.stream_carrier())
    }

    pub(super) fn relay_data(&self) -> Option<Arc<RelayDataClient>> {
        self.inner
            .lock()
            .expect("physical path lock")
            .carrier
            .as_ref()
            .and_then(|carrier| carrier.relay_data())
    }

    async fn send_channel_frame(
        &self,
        relay_token: &str,
        kind: GenericFrameKind,
        payload: &[u8],
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let send = {
            let inner = self.inner.lock().expect("physical path lock");
            inner
                .carrier
                .as_ref()
                .map(|carrier| carrier.send_channel_frame(relay_token, kind, payload))
        };
        match send {
            Some(send) => send.await,
            None => Err(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "physical path unavailable",
            )
            .into()),
        }
    }

    pub(super) fn try_acquire(self: &Arc<Self>) -> Result<PathLease, CoreNetworkError> {
        let mut inner = self.inner.lock().expect("physical path lock");
        if !matches!(inner.state, PhysicalPathState::Ready) {
            return Err(CoreNetworkError::StaleAttempt);
        }
        if inner.leases >= MAX_PATH_LEASES {
            return Err(CoreNetworkError::ResourceLimit("path leases"));
        }
        inner.leases += 1;
        inner.last_activity = Instant::now();
        Ok(PathLease {
            handle: self.handle.clone(),
            path: Arc::clone(self),
            released: false,
        })
    }

    pub(super) fn retire_normal(&self) -> bool {
        let carrier = {
            let mut inner = self.inner.lock().expect("physical path lock");
            match inner.state {
                PhysicalPathState::Ready => {
                    inner.state = PhysicalPathState::Draining;
                }
                PhysicalPathState::Draining => {}
                PhysicalPathState::Closed(_) => return false,
            }
            if inner.leases == 0 {
                inner.state = PhysicalPathState::Closed(PathCloseReason::NormalRetire);
                inner.carrier.take()
            } else {
                None
            }
        };
        close_carrier(carrier, PathCloseReason::NormalRetire);
        true
    }

    pub(super) fn close_with_reason(&self, reason: PathCloseReason) -> bool {
        let carrier = {
            let mut inner = self.inner.lock().expect("physical path lock");
            if matches!(inner.state, PhysicalPathState::Closed(_)) {
                return false;
            }
            inner.state = PhysicalPathState::Closed(reason);
            inner.carrier.take()
        };
        close_carrier(carrier, reason);
        true
    }

    pub(super) fn release_lease(&self) {
        let carrier = {
            let mut inner = self.inner.lock().expect("physical path lock");
            if inner.leases == 0 {
                return;
            }
            inner.leases -= 1;
            if inner.leases == 0 && matches!(inner.state, PhysicalPathState::Draining) {
                inner.state = PhysicalPathState::Closed(PathCloseReason::NormalRetire);
                inner.carrier.take()
            } else {
                if matches!(inner.state, PhysicalPathState::Ready) {
                    inner.last_activity = Instant::now();
                }
                None
            }
        };
        close_carrier(carrier, PathCloseReason::NormalRetire);
    }

    pub(super) fn record_activity(&self) {
        let mut inner = self.inner.lock().expect("physical path lock");
        if matches!(inner.state, PhysicalPathState::Ready) {
            inner.last_activity = Instant::now();
        }
    }

    pub(super) fn is_ephemeral_idle(&self, now: Instant) -> bool {
        let inner = self.inner.lock().expect("physical path lock");
        matches!(inner.state, PhysicalPathState::Ready)
            && inner.leases == 0
            && now.saturating_duration_since(inner.last_activity)
                >= super::super::EPHEMERAL_PATH_IDLE_TIMEOUT
    }
}

impl Drop for PhysicalPath {
    fn drop(&mut self) {
        // A manager normally retires or hard-closes before dropping its last
        // owner. This guard keeps an unexpected owner drop from leaking the
        // transferred carrier.
        let _ = self.close_with_reason(PathCloseReason::HardClose);
    }
}

/// An explicit reservation held by one business operation.
///
/// The lease owns only a reference to the peer-owned [`PhysicalPath`]. It
/// never owns the carrier and cannot make a new lease after retirement.
pub(crate) struct PathLease {
    handle: PathHandle,
    pub(super) path: Arc<PhysicalPath>,
    released: bool,
}

impl PathLease {
    pub(crate) fn handle(&self) -> &PathHandle {
        &self.handle
    }

    pub(crate) fn profile(&self) -> ConnectionProfile {
        self.handle.profile()
    }

    /// Borrow the underlying QUIC connection for the duration of this lease.
    /// The returned connection is an I/O handle, never an independent path
    /// owner.
    pub(crate) fn connection(&self) -> Option<Connection> {
        self.path.connection()
    }

    /// Borrow a cloneable transport I/O view while this lease is active.
    pub(crate) fn stream_carrier(&self) -> Option<StreamCarrier> {
        self.path.stream_carrier()
    }

    pub(crate) fn relay_data(&self) -> Option<Arc<RelayDataClient>> {
        self.path.relay_data()
    }

    pub(crate) async fn send_channel_frame(
        &self,
        relay_token: &str,
        kind: GenericFrameKind,
        payload: &[u8],
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.path
            .send_channel_frame(relay_token, kind, payload)
            .await
    }

    /// A hard close or security failure becomes visible to existing borrowers
    /// immediately. A normal drain remains active until the last lease is
    /// released, at which point the carrier is closed.
    pub(crate) fn is_active(&self) -> bool {
        self.path.is_active()
    }

    /// Explicitly release this business reservation. `Drop` remains the
    /// safety net for callers that leave the operation through an error path.
    pub(crate) fn release(mut self) {
        self.release_inner();
    }

    #[cfg(test)]
    pub(super) fn lease_count(&self) -> usize {
        self.path.lease_count()
    }

    fn release_inner(&mut self) {
        if !self.released {
            self.released = true;
            self.path.release_lease();
        }
    }
}

impl Drop for PathLease {
    fn drop(&mut self) {
        self.release_inner();
    }
}
