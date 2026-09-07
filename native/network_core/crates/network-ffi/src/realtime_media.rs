//! Additive, payload-free C ABI controls for native screen-media endpoint leases.
//!
//! The ABI only creates and releases opaque IDs. Encoded media stays in native
//! capture/codec/render owners and is never copied into the command or event
//! protobuf queues.

use network_core::{RealtimeMediaDirection, RealtimeMediaEndpointId, RealtimeMediaError};
use network_webrtc::{
    EncodedVideoFrame, VideoCodec, VideoEnqueueResult, MAX_ENCODED_VIDEO_FRAME_BYTES,
};
use std::panic::catch_unwind;
use std::slice;
use std::str;
use std::time::{Duration, Instant};

use super::{SshNetBuffer, SshNetRuntime, SshNetRuntimeHandle};

/// Numeric C ABI values for a one-way screen-media lease.
pub const SSH_NET_REALTIME_MEDIA_DIRECTION_SEND: u32 = 1;
/// Numeric C ABI values for a one-way screen-media lease.
pub const SSH_NET_REALTIME_MEDIA_DIRECTION_RECEIVE: u32 = 2;

/// Metadata for one native-only H.264 access unit.
///
/// This C representation is intentionally unavailable to Dart. Platform
/// capture/decoder code uses it with an opaque endpoint ID while the Dart FFI
/// facade exposes only endpoint lifecycle controls.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SshNetRealtimeMediaFrameMetadata {
    pub sequence: u64,
    /// RTP clock ticks at the fixed 90 kHz H.264 screen-video timebase.
    pub timestamp: u64,
    pub width: u32,
    pub height: u32,
    /// Strict C bool: `0` for a delta frame, `1` for a keyframe.
    pub keyframe: u8,
}

/// Return value for a pull when the bounded native egress queue is empty.
pub const SSH_NET_REALTIME_MEDIA_NO_FRAME: i32 = 1;
/// Return value for a push that was safely dropped by native queue policy.
pub const SSH_NET_REALTIME_MEDIA_FRAME_DROPPED: i32 = 1;

/// Stable lifecycle/data-plane status values for the media ABI. These are
/// deliberately separate from the general command ABI's `-2` status.
pub const SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT: i32 = -1;
pub const SSH_NET_REALTIME_MEDIA_STATUS_UNKNOWN_SESSION: i32 = -2;
pub const SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL: i32 = -3;
pub const SSH_NET_REALTIME_MEDIA_STATUS_RUNTIME_STOPPED: i32 = -4;
pub const SSH_NET_REALTIME_MEDIA_STATUS_STALE_GENERATION: i32 = -5;
pub const SSH_NET_REALTIME_MEDIA_STATUS_STALE_ENDPOINT: i32 = -6;
pub const SSH_NET_REALTIME_MEDIA_STATUS_DIRECTION_MISMATCH: i32 = -7;
pub const SSH_NET_REALTIME_MEDIA_STATUS_DUPLICATE_ENDPOINT: i32 = -8;
pub const SSH_NET_REALTIME_MEDIA_STATUS_DRIVER_UNAVAILABLE: i32 = -9;
pub const SSH_NET_REALTIME_MEDIA_STATUS_PEER_MISMATCH: i32 = -10;
pub const SSH_NET_REALTIME_MEDIA_STATUS_FRAME_REJECTED: i32 = -11;

const NATIVE_MEDIA_FRAME_MAX_AGE: Duration = Duration::from_secs(1);

/// Creates an opaque endpoint lease for the active native realtime generation.
///
/// The ID strings are bounded UTF-8 identifiers; no media bytes, socket, peer,
/// or renderer handle crosses this boundary. Returns zero on success or one of
/// the stable media status codes below. `expected_generation` is compared
/// under the same manager lock as session/driver lookup; it is never inferred
/// from whichever driver happens to be registered now.
///
/// # Safety
/// `handle` is a live runtime handle; both identifier ranges and `out_endpoint`
/// must point to valid memory for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_realtime_media_endpoint_create(
    handle: SshNetRuntimeHandle,
    realtime_id_ptr: *const u8,
    realtime_id_len: usize,
    peer_id_ptr: *const u8,
    peer_id_len: usize,
    expected_generation: u64,
    direction: u32,
    out_endpoint: *mut u64,
) -> i32 {
    if handle.is_null()
        || realtime_id_ptr.is_null()
        || realtime_id_len == 0
        || peer_id_ptr.is_null()
        || peer_id_len == 0
        || expected_generation == 0
        || out_endpoint.is_null()
    {
        return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT;
    }

    let result = catch_unwind(|| {
        unsafe { *out_endpoint = 0 };
        let realtime_id = match unsafe { identifier(realtime_id_ptr, realtime_id_len) } {
            Ok(value) => value,
            Err(()) => return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT,
        };
        let peer_id = match unsafe { identifier(peer_id_ptr, peer_id_len) } {
            Ok(value) => value,
            Err(()) => return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT,
        };
        let direction = match direction {
            SSH_NET_REALTIME_MEDIA_DIRECTION_SEND => RealtimeMediaDirection::Send,
            SSH_NET_REALTIME_MEDIA_DIRECTION_RECEIVE => RealtimeMediaDirection::Receive,
            _ => return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT,
        };
        let runtime = unsafe { &*(handle as *const SshNetRuntime) };
        match runtime.runtime.create_realtime_media_endpoint(
            realtime_id,
            peer_id,
            direction,
            expected_generation,
        ) {
            Ok(endpoint) => {
                unsafe { *out_endpoint = endpoint.raw() };
                0
            }
            Err(error) => map_error(error),
        }
    });

    result.unwrap_or(SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL)
}

/// Releases a previously created endpoint lease. Repeating a release remains
/// safe and does not require the realtime session to still exist.
///
/// # Safety
/// `handle` is a runtime handle created by `ssh_net_runtime_create`.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_realtime_media_endpoint_release(
    handle: SshNetRuntimeHandle,
    endpoint: u64,
) -> i32 {
    if handle.is_null() || endpoint == 0 {
        return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT;
    }

    let result = catch_unwind(|| {
        let runtime = unsafe { &*(handle as *const SshNetRuntime) };
        match runtime
            .runtime
            .release_realtime_media_endpoint(RealtimeMediaEndpointId::from_raw(endpoint))
        {
            Ok(()) => 0,
            Err(error) => map_error(error),
        }
    });

    result.unwrap_or(SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL)
}

/// Pushes one encoded H.264 access unit from a platform-native capture owner.
///
/// This is the high-frequency native data-plane ABI. It is deliberately not
/// declared by the Dart FFI facade and never serializes data into commands or
/// events. The frame is copied into the existing bounded native H.264 queue;
/// native queue policy returns `SSH_NET_REALTIME_MEDIA_FRAME_DROPPED` when it
/// discards the input rather than allowing backlog growth.
///
/// # Safety
/// `handle` is a live runtime handle and `payload_ptr` must address
/// `payload_len` readable bytes for this call. The caller retains the input
/// memory after return.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_realtime_media_endpoint_push_h264(
    handle: SshNetRuntimeHandle,
    endpoint: u64,
    metadata: SshNetRealtimeMediaFrameMetadata,
    payload_ptr: *const u8,
    payload_len: usize,
) -> i32 {
    if handle.is_null()
        || endpoint == 0
        || payload_ptr.is_null()
        || payload_len == 0
        || payload_len > MAX_ENCODED_VIDEO_FRAME_BYTES
        || metadata.keyframe > 1
    {
        return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT;
    }

    let result = catch_unwind(|| {
        let payload = unsafe { slice::from_raw_parts(payload_ptr, payload_len) }.to_vec();
        let frame = EncodedVideoFrame::new(
            VideoCodec::H264,
            metadata.sequence,
            metadata.timestamp,
            metadata.width,
            metadata.height,
            metadata.keyframe == 1,
            payload,
            Instant::now() + NATIVE_MEDIA_FRAME_MAX_AGE,
        );
        let runtime = unsafe { &*(handle as *const SshNetRuntime) };
        match runtime
            .runtime
            .push_realtime_media_h264(RealtimeMediaEndpointId::from_raw(endpoint), frame)
        {
            Ok(VideoEnqueueResult::Accepted | VideoEnqueueResult::AcceptedAfterDropping { .. }) => {
                0
            }
            Ok(VideoEnqueueResult::DroppedIncoming | VideoEnqueueResult::DroppedStale) => {
                SSH_NET_REALTIME_MEDIA_FRAME_DROPPED
            }
            Err(error) => map_error(error),
        }
    });

    result.unwrap_or(SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL)
}

/// Pulls one encoded H.264 access unit for a platform-native decoder owner.
///
/// On success, `out_payload` is a Rust-owned buffer which the platform caller
/// must release with `ssh_net_buffer_free`. A return value of
/// `SSH_NET_REALTIME_MEDIA_NO_FRAME` leaves both outputs empty. This function
/// is native-only and is not a Dart FFI entry point.
///
/// # Safety
/// `handle` is a live runtime handle. `out_metadata` and `out_payload` must
/// point to writable memory for this call. A non-null returned payload pointer
/// must be passed unchanged to `ssh_net_buffer_free` exactly once.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_realtime_media_endpoint_pull_h264(
    handle: SshNetRuntimeHandle,
    endpoint: u64,
    out_metadata: *mut SshNetRealtimeMediaFrameMetadata,
    out_payload: *mut SshNetBuffer,
) -> i32 {
    if handle.is_null() || endpoint == 0 || out_metadata.is_null() || out_payload.is_null() {
        return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT;
    }

    let result = catch_unwind(|| {
        unsafe {
            *out_metadata = SshNetRealtimeMediaFrameMetadata::default();
            *out_payload = SshNetBuffer {
                ptr: std::ptr::null_mut(),
                len: 0,
            };
        }
        let runtime = unsafe { &*(handle as *const SshNetRuntime) };
        match runtime
            .runtime
            .pop_realtime_media_h264(RealtimeMediaEndpointId::from_raw(endpoint))
        {
            Ok(Some(frame)) => {
                let metadata = SshNetRealtimeMediaFrameMetadata {
                    sequence: frame.sequence,
                    timestamp: frame.timestamp,
                    width: frame.width,
                    height: frame.height,
                    keyframe: u8::from(frame.keyframe),
                };
                let len = frame.payload.len();
                let mut payload = frame.payload.into_boxed_slice();
                let ptr = payload.as_mut_ptr();
                std::mem::forget(payload);
                unsafe {
                    *out_metadata = metadata;
                    *out_payload = SshNetBuffer { ptr, len };
                }
                0
            }
            Ok(None) => SSH_NET_REALTIME_MEDIA_NO_FRAME,
            Err(error) => map_error(error),
        }
    });

    result.unwrap_or(SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL)
}

unsafe fn identifier<'a>(pointer: *const u8, length: usize) -> Result<&'a str, ()> {
    if length > 128 {
        return Err(());
    }
    let bytes = unsafe { slice::from_raw_parts(pointer, length) };
    str::from_utf8(bytes).map_err(|_| ())
}

fn map_error(error: RealtimeMediaError) -> i32 {
    match error {
        RealtimeMediaError::RuntimeNotRunning => SSH_NET_REALTIME_MEDIA_STATUS_RUNTIME_STOPPED,
        RealtimeMediaError::InvalidRealtimeId | RealtimeMediaError::InvalidPeerId => {
            SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT
        }
        RealtimeMediaError::UnknownRealtimeSession => SSH_NET_REALTIME_MEDIA_STATUS_UNKNOWN_SESSION,
        RealtimeMediaError::StaleGeneration => SSH_NET_REALTIME_MEDIA_STATUS_STALE_GENERATION,
        RealtimeMediaError::StaleEndpoint => SSH_NET_REALTIME_MEDIA_STATUS_STALE_ENDPOINT,
        RealtimeMediaError::DirectionMismatch => SSH_NET_REALTIME_MEDIA_STATUS_DIRECTION_MISMATCH,
        RealtimeMediaError::DuplicateEndpoint => SSH_NET_REALTIME_MEDIA_STATUS_DUPLICATE_ENDPOINT,
        RealtimeMediaError::DriverUnavailable => SSH_NET_REALTIME_MEDIA_STATUS_DRIVER_UNAVAILABLE,
        RealtimeMediaError::PeerMismatch => SSH_NET_REALTIME_MEDIA_STATUS_PEER_MISMATCH,
        RealtimeMediaError::FrameRejected => SSH_NET_REALTIME_MEDIA_STATUS_FRAME_REJECTED,
        RealtimeMediaError::Internal => SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL,
    }
}
