//! Native-only screen-media endpoint registry.
//!
//! The registry owns opaque endpoint leases, never a peer connection. Each
//! lease captures the runtime/session generation and a weak borrow of the
//! existing `RealtimeIoDriver`; terminal session paths invalidate the lease
//! before the driver is closed.

use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex, Weak,
};
use std::time::Instant;

#[cfg(feature = "ffi-test-support")]
use network_webrtc::media::RtpPacketizer;
use network_webrtc::{
    EncodedVideoFrame, MediaDirection, RealtimeIoDriver, RealtimeIoDriverHandle,
    VideoEnqueueResult, WebRtcError,
};

use crate::runtime::RuntimeState;

static NEXT_RUNTIME_GENERATION: AtomicU64 = AtomicU64::new(1);
static NEXT_ENDPOINT_ID: AtomicU64 = AtomicU64::new(1);

/// Direction permitted for one opaque native endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RealtimeMediaDirection {
    Send,
    Receive,
}

/// Opaque endpoint identifier. It is globally unique for the process so an ID
/// from a prior runtime can never accidentally name a new endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct RealtimeMediaEndpointId(u64);

impl RealtimeMediaEndpointId {
    pub const fn from_raw(value: u64) -> Self {
        Self(value)
    }

    pub const fn raw(self) -> u64 {
        self.0
    }
}

/// Errors at the native media endpoint boundary. Payload contents are never
/// retained or embedded in the error text.
#[derive(Debug, thiserror::Error)]
pub enum RealtimeMediaError {
    #[error("network runtime is not running")]
    RuntimeNotRunning,
    #[error("realtime ID is invalid")]
    InvalidRealtimeId,
    #[error("peer ID is invalid")]
    InvalidPeerId,
    #[error("realtime session does not exist")]
    UnknownRealtimeSession,
    #[error("peer does not match realtime session")]
    PeerMismatch,
    #[error("realtime session has no native I/O driver")]
    DriverUnavailable,
    #[error("endpoint already exists for this session generation and direction")]
    DuplicateEndpoint,
    #[error("endpoint is stale or released")]
    StaleEndpoint,
    #[error("realtime session generation is stale")]
    StaleGeneration,
    #[error("endpoint direction rejects this operation")]
    DirectionMismatch,
    #[error("encoded H.264 frame was rejected")]
    FrameRejected,
    #[error("native media bridge lock failed")]
    Internal,
}

#[derive(Clone)]
struct SessionBinding {
    peer_id: String,
    generation: u64,
    driver: Weak<Mutex<RealtimeIoDriver>>,
}

struct EndpointLease {
    realtime_id: String,
    peer_id: String,
    runtime_generation: u64,
    session_generation: u64,
    direction: RealtimeMediaDirection,
    driver: Weak<Mutex<RealtimeIoDriver>>,
}

/// Runtime-owned registry for native media endpoint leases.
pub(crate) struct RealtimeMediaRegistry {
    runtime_generation: u64,
    session_bindings: HashMap<String, SessionBinding>,
    endpoints: HashMap<RealtimeMediaEndpointId, EndpointLease>,
}

impl RealtimeMediaRegistry {
    pub(crate) fn new() -> Self {
        Self {
            runtime_generation: NEXT_RUNTIME_GENERATION.fetch_add(1, Ordering::Relaxed),
            session_bindings: HashMap::new(),
            endpoints: HashMap::new(),
        }
    }

    fn create(
        &mut self,
        realtime_id: &str,
        peer_id: &str,
        direction: RealtimeMediaDirection,
        expected_generation: u64,
        session_generation: u64,
        driver: &RealtimeIoDriverHandle,
    ) -> Result<RealtimeMediaEndpointId, RealtimeMediaError> {
        if expected_generation != session_generation {
            return Err(RealtimeMediaError::StaleGeneration);
        }
        let driver_weak = Arc::downgrade(driver);
        let session_generation = match self.session_bindings.get(realtime_id) {
            Some(existing)
                if existing.peer_id == peer_id
                    && existing.generation == session_generation
                    && Weak::ptr_eq(&existing.driver, &driver_weak) =>
            {
                existing.generation
            }
            Some(_) => {
                self.invalidate_realtime(realtime_id);
                self.insert_session_binding(
                    realtime_id,
                    peer_id,
                    session_generation,
                    driver_weak.clone(),
                )
            }
            None => self.insert_session_binding(
                realtime_id,
                peer_id,
                session_generation,
                driver_weak.clone(),
            ),
        };

        if self.endpoints.values().any(|endpoint| {
            endpoint.realtime_id == realtime_id
                && endpoint.peer_id == peer_id
                && endpoint.runtime_generation == self.runtime_generation
                && endpoint.session_generation == session_generation
                && endpoint.direction == direction
        }) {
            return Err(RealtimeMediaError::DuplicateEndpoint);
        }

        let endpoint_id = RealtimeMediaEndpointId(NEXT_ENDPOINT_ID.fetch_add(1, Ordering::Relaxed));
        self.endpoints.insert(
            endpoint_id,
            EndpointLease {
                realtime_id: realtime_id.to_owned(),
                peer_id: peer_id.to_owned(),
                runtime_generation: self.runtime_generation,
                session_generation,
                direction,
                driver: driver_weak,
            },
        );
        Ok(endpoint_id)
    }

    fn insert_session_binding(
        &mut self,
        realtime_id: &str,
        peer_id: &str,
        generation: u64,
        driver: Weak<Mutex<RealtimeIoDriver>>,
    ) -> u64 {
        self.session_bindings.insert(
            realtime_id.to_owned(),
            SessionBinding {
                peer_id: peer_id.to_owned(),
                generation,
                driver,
            },
        );
        generation
    }

    fn release(&mut self, endpoint_id: RealtimeMediaEndpointId) -> Result<(), RealtimeMediaError> {
        let Some((driver_weak, direction)) = self
            .endpoints
            .get(&endpoint_id)
            .map(|endpoint| (endpoint.driver.clone(), endpoint.direction))
        else {
            return Ok(());
        };
        let Some(driver) = driver_weak.upgrade() else {
            self.endpoints.remove(&endpoint_id);
            return Ok(());
        };
        let mut driver = driver
            .lock()
            .map_err(|_| RealtimeMediaError::DriverUnavailable)?;
        let direction = match direction {
            RealtimeMediaDirection::Send => MediaDirection::Sendonly,
            RealtimeMediaDirection::Receive => MediaDirection::Recvonly,
        };
        driver
            .peer_mut()
            .clear_h264_screen_video(direction)
            .map_err(|_| RealtimeMediaError::DriverUnavailable)?;
        // Keep the lease visible until native queue/order cleanup succeeds so
        // a caller can retry a transient driver failure deterministically.
        self.endpoints.remove(&endpoint_id);
        Ok(())
    }

    fn invalidate_realtime(&mut self, realtime_id: &str) {
        self.session_bindings.remove(realtime_id);
        self.endpoints
            .retain(|_, endpoint| endpoint.realtime_id != realtime_id);
    }

    fn invalidate_all(&mut self) {
        self.session_bindings.clear();
        self.endpoints.clear();
    }

    fn with_endpoint<T>(
        &mut self,
        endpoint_id: RealtimeMediaEndpointId,
        direction: RealtimeMediaDirection,
        operation: impl FnOnce(&mut RealtimeIoDriver) -> Result<T, WebRtcError>,
    ) -> Result<T, RealtimeMediaError> {
        let endpoint = self
            .endpoints
            .get(&endpoint_id)
            .ok_or(RealtimeMediaError::StaleEndpoint)?;
        if endpoint.runtime_generation != self.runtime_generation {
            return Err(RealtimeMediaError::StaleEndpoint);
        }
        if endpoint.direction != direction {
            return Err(RealtimeMediaError::DirectionMismatch);
        }
        let driver = endpoint
            .driver
            .upgrade()
            .ok_or(RealtimeMediaError::StaleEndpoint)?;
        let mut driver = driver
            .lock()
            .map_err(|_| RealtimeMediaError::DriverUnavailable)?;
        operation(&mut driver).map_err(|_| RealtimeMediaError::FrameRejected)
    }

    #[cfg(test)]
    fn session_generation(&self, endpoint_id: RealtimeMediaEndpointId) -> Option<u64> {
        self.endpoints
            .get(&endpoint_id)
            .map(|endpoint| endpoint.session_generation)
    }
}

pub(crate) async fn create_endpoint(
    state: &RuntimeState,
    realtime_id: &str,
    peer_id: &str,
    direction: RealtimeMediaDirection,
    expected_generation: u64,
) -> Result<RealtimeMediaEndpointId, RealtimeMediaError> {
    validate_identifiers(realtime_id, peer_id)?;
    // Keep session validation and endpoint insertion under the same Realtime
    // manager lock. A close can only remove the session after this insertion,
    // at which point its invalidation removes the just-created endpoint.
    let sessions = state.realtime.lock().await;
    let (driver, session_generation) = sessions.media_endpoint_driver(realtime_id, peer_id)?;
    if expected_generation != session_generation {
        return Err(RealtimeMediaError::StaleGeneration);
    }
    let mut registry = state
        .realtime_media
        .lock()
        .map_err(|_| RealtimeMediaError::Internal)?;
    registry.create(
        realtime_id,
        peer_id,
        direction,
        expected_generation,
        session_generation,
        &driver,
    )
}

pub(crate) fn release_endpoint(
    state: &RuntimeState,
    endpoint_id: RealtimeMediaEndpointId,
) -> Result<(), RealtimeMediaError> {
    let mut registry = state
        .realtime_media
        .lock()
        .map_err(|_| RealtimeMediaError::Internal)?;
    registry.release(endpoint_id)
}

pub(crate) fn push_endpoint(
    state: &RuntimeState,
    endpoint_id: RealtimeMediaEndpointId,
    frame: EncodedVideoFrame,
) -> Result<VideoEnqueueResult, RealtimeMediaError> {
    let mut registry = state
        .realtime_media
        .lock()
        .map_err(|_| RealtimeMediaError::Internal)?;
    let now = Instant::now();
    registry.with_endpoint(endpoint_id, RealtimeMediaDirection::Send, |driver| {
        driver.peer_mut().enqueue_h264_screen_video(frame, now)
    })
}

pub(crate) fn pop_endpoint(
    state: &RuntimeState,
    endpoint_id: RealtimeMediaEndpointId,
) -> Result<Option<EncodedVideoFrame>, RealtimeMediaError> {
    let mut registry = state
        .realtime_media
        .lock()
        .map_err(|_| RealtimeMediaError::Internal)?;
    let now = Instant::now();
    registry.with_endpoint(endpoint_id, RealtimeMediaDirection::Receive, |driver| {
        Ok(driver.peer_mut().pop_remote_h264_screen_video(now))
    })
}

/// Injects one packetized frame into a receive endpoint for the C-ABI
/// success-path test. It is not available to production callers: real RTP is
/// delivered by `RealtimeIoDriver` from the negotiated socket.
#[cfg(feature = "ffi-test-support")]
pub(crate) fn inject_test_endpoint_frame(
    state: &RuntimeState,
    endpoint_id: RealtimeMediaEndpointId,
    frame: EncodedVideoFrame,
) -> Result<(), RealtimeMediaError> {
    let packets = RtpPacketizer::new(1_200, 102, 0x1357_2468, 1)
        .packetize(&frame)
        .map_err(|_| RealtimeMediaError::FrameRejected)?;
    let mut registry = state
        .realtime_media
        .lock()
        .map_err(|_| RealtimeMediaError::Internal)?;
    let now = Instant::now();
    registry.with_endpoint(endpoint_id, RealtimeMediaDirection::Receive, |driver| {
        for packet in &packets {
            driver
                .peer_mut()
                .receive_h264_screen_video_rtp(packet, now)?;
        }
        Ok(())
    })
}

pub(crate) fn invalidate_realtime(state: &RuntimeState, realtime_id: &str) {
    if let Ok(mut registry) = state.realtime_media.lock() {
        registry.invalidate_realtime(realtime_id);
    }
}

pub(crate) fn invalidate_all(state: &RuntimeState) {
    if let Ok(mut registry) = state.realtime_media.lock() {
        registry.invalidate_all();
    }
}

fn validate_identifiers(realtime_id: &str, peer_id: &str) -> Result<(), RealtimeMediaError> {
    if realtime_id.len() != 32 || !realtime_id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(RealtimeMediaError::InvalidRealtimeId);
    }
    if peer_id.is_empty() || peer_id.len() > 128 {
        return Err(RealtimeMediaError::InvalidPeerId);
    }
    Ok(())
}

#[cfg(test)]
#[path = "tests/realtime_media.rs"]
mod tests;
