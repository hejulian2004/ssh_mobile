//! Native-only screen-media endpoint registry.
//!
//! The registry owns opaque endpoint leases, never a peer connection. Each
//! lease captures the runtime/session generation and a weak borrow of the
//! existing `RealtimeIoDriver`; terminal session paths invalidate the lease
//! before the driver is closed.

mod endpoint;
mod registry;

#[cfg(test)]
use network_webrtc::RealtimeIoDriverHandle;

pub(crate) use endpoint::{
    apply_adaptation, create_endpoint, invalidate_all, invalidate_realtime, pop_endpoint,
    push_endpoint, release_endpoint, request_keyframe, reset_decoder, stats, validate_endpoint,
};
pub(crate) use registry::{with_endpoint_lease, RealtimeMediaRegistry};

#[cfg(feature = "ffi-test-support")]
pub(crate) use endpoint::inject_test_endpoint_frame;

#[cfg(test)]
pub(crate) use endpoint::validate_identifiers;

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

#[cfg(test)]
#[path = "../tests/realtime_media.rs"]
mod tests;
