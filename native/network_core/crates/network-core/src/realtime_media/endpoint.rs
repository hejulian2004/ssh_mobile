//! Create, validate, and invalidate native media endpoint leases.

use std::time::Instant;

#[cfg(feature = "ffi-test-support")]
use network_webrtc::media::RtpPacketizer;
use network_webrtc::{
    EncodedVideoFrame, H264AdaptationTarget, H264ScreenVideoStats, MediaDirection,
    VideoEnqueueResult,
};

use crate::runtime::RuntimeState;

use super::*;

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
    let endpoint = {
        let registry = state
            .realtime_media
            .lock()
            .map_err(|_| RealtimeMediaError::Internal)?;
        registry.endpoints.get(&endpoint_id).cloned()
    };
    let Some(endpoint) = endpoint else {
        return Ok(());
    };
    let Some(driver) = endpoint.driver.upgrade() else {
        let mut registry = state
            .realtime_media
            .lock()
            .map_err(|_| RealtimeMediaError::Internal)?;
        registry.endpoints.remove(&endpoint_id);
        return Ok(());
    };
    let direction = match endpoint.direction {
        RealtimeMediaDirection::Send => MediaDirection::Sendonly,
        RealtimeMediaDirection::Receive => MediaDirection::Recvonly,
    };
    {
        let mut driver = driver
            .lock()
            .map_err(|_| RealtimeMediaError::DriverUnavailable)?;
        driver
            .peer_mut()
            .clear_h264_screen_video(direction)
            .map_err(|_| RealtimeMediaError::DriverUnavailable)?;
    }
    // Keep the lease visible until native queue/order cleanup succeeds so a
    // caller can retry a transient driver failure deterministically.
    let mut registry = state
        .realtime_media
        .lock()
        .map_err(|_| RealtimeMediaError::Internal)?;
    registry.endpoints.remove(&endpoint_id);
    Ok(())
}

pub(crate) fn validate_endpoint(
    state: &RuntimeState,
    endpoint_id: RealtimeMediaEndpointId,
    realtime_id: &str,
    peer_id: &str,
    generation: u64,
    direction: RealtimeMediaDirection,
) -> Result<(), RealtimeMediaError> {
    let registry = state
        .realtime_media
        .lock()
        .map_err(|_| RealtimeMediaError::Internal)?;
    registry.validate_endpoint(endpoint_id, realtime_id, peer_id, generation, direction)
}

pub(crate) fn push_endpoint(
    state: &RuntimeState,
    endpoint_id: RealtimeMediaEndpointId,
    frame: EncodedVideoFrame,
) -> Result<VideoEnqueueResult, RealtimeMediaError> {
    let endpoint = {
        let registry = state
            .realtime_media
            .lock()
            .map_err(|_| RealtimeMediaError::Internal)?;
        registry.snapshot_endpoint(endpoint_id, RealtimeMediaDirection::Send)?
    };
    let now = Instant::now();
    with_endpoint_lease(endpoint, |driver| {
        driver.peer_mut().enqueue_h264_screen_video(frame, now)
    })
}

pub(crate) fn request_keyframe(
    state: &RuntimeState,
    endpoint_id: RealtimeMediaEndpointId,
) -> Result<(), RealtimeMediaError> {
    let endpoint = {
        let registry = state
            .realtime_media
            .lock()
            .map_err(|_| RealtimeMediaError::Internal)?;
        registry.endpoint_lease(endpoint_id)?
    };
    let direction = match endpoint.direction {
        RealtimeMediaDirection::Send => MediaDirection::Sendonly,
        RealtimeMediaDirection::Receive => MediaDirection::Recvonly,
    };
    with_endpoint_lease(endpoint, |driver| {
        driver
            .peer_mut()
            .request_h264_screen_video_keyframe(direction)
    })
}

pub(crate) fn reset_decoder(
    state: &RuntimeState,
    endpoint_id: RealtimeMediaEndpointId,
) -> Result<(), RealtimeMediaError> {
    let endpoint = {
        let registry = state
            .realtime_media
            .lock()
            .map_err(|_| RealtimeMediaError::Internal)?;
        registry.snapshot_endpoint(endpoint_id, RealtimeMediaDirection::Receive)?
    };
    with_endpoint_lease(endpoint, |driver| {
        driver.peer_mut().reset_h264_screen_video_decoder()
    })
}

pub(crate) fn apply_adaptation(
    state: &RuntimeState,
    endpoint_id: RealtimeMediaEndpointId,
    target: H264AdaptationTarget,
) -> Result<(), RealtimeMediaError> {
    let endpoint = {
        let registry = state
            .realtime_media
            .lock()
            .map_err(|_| RealtimeMediaError::Internal)?;
        registry.snapshot_endpoint(endpoint_id, RealtimeMediaDirection::Send)?
    };
    with_endpoint_lease(endpoint, |driver| {
        driver.peer_mut().apply_h264_screen_video_adaptation(target)
    })
}

pub(crate) fn stats(
    state: &RuntimeState,
    endpoint_id: RealtimeMediaEndpointId,
) -> Result<H264ScreenVideoStats, RealtimeMediaError> {
    let endpoint = {
        let registry = state
            .realtime_media
            .lock()
            .map_err(|_| RealtimeMediaError::Internal)?;
        registry.endpoint_lease(endpoint_id)?
    };
    let direction = match endpoint.direction {
        RealtimeMediaDirection::Send => MediaDirection::Sendonly,
        RealtimeMediaDirection::Receive => MediaDirection::Recvonly,
    };
    with_endpoint_lease(endpoint, |driver| {
        driver.peer_mut().h264_screen_video_stats(direction)
    })
}

pub(crate) fn pop_endpoint(
    state: &RuntimeState,
    endpoint_id: RealtimeMediaEndpointId,
) -> Result<Option<EncodedVideoFrame>, RealtimeMediaError> {
    let endpoint = {
        let registry = state
            .realtime_media
            .lock()
            .map_err(|_| RealtimeMediaError::Internal)?;
        registry.snapshot_endpoint(endpoint_id, RealtimeMediaDirection::Receive)?
    };
    let now = Instant::now();
    with_endpoint_lease(endpoint, |driver| {
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
    let endpoint = {
        let registry = state
            .realtime_media
            .lock()
            .map_err(|_| RealtimeMediaError::Internal)?;
        registry.snapshot_endpoint(endpoint_id, RealtimeMediaDirection::Receive)?
    };
    let now = Instant::now();
    with_endpoint_lease(endpoint, |driver| {
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

pub(crate) fn validate_identifiers(
    realtime_id: &str,
    peer_id: &str,
) -> Result<(), RealtimeMediaError> {
    if realtime_id.len() != 32 || !realtime_id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(RealtimeMediaError::InvalidRealtimeId);
    }
    if peer_id.is_empty() || peer_id.len() > 128 {
        return Err(RealtimeMediaError::InvalidPeerId);
    }
    Ok(())
}
