//! Native-only platform owner capabilities for screen media.
//!
//! This module deliberately stays separate from the endpoint lease ABI. An
//! owner token retains the full endpoint identity and is invalidated before a
//! runtime is stopped or destroyed. Platform code can use the native start,
//! renderer, and H.264 functions without exposing any of them to Dart.

use network_core::{RealtimeMediaDirection, RealtimeMediaEndpointId};
use network_webrtc::{
    EncodedVideoFrame, H264AdaptationReason, H264AdaptationTarget, H264ScreenVideoStats,
    VideoCodec, VideoEnqueueResult, MAX_ENCODED_VIDEO_FRAME_BYTES,
};
use std::collections::HashMap;
use std::panic::catch_unwind;
use std::slice;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use super::{
    identifier, map_error, SshNetBuffer, SshNetRealtimeMediaFrameMetadata,
    SshNetRealtimeMediaStats, SshNetRuntime, SshNetRuntimeHandle, NATIVE_MEDIA_FRAME_MAX_AGE,
    SSH_NET_REALTIME_MEDIA_DIRECTION_RECEIVE, SSH_NET_REALTIME_MEDIA_DIRECTION_SEND,
    SSH_NET_REALTIME_MEDIA_FRAME_DROPPED, SSH_NET_REALTIME_MEDIA_NO_FRAME,
    SSH_NET_REALTIME_MEDIA_STATUS_DIRECTION_MISMATCH,
    SSH_NET_REALTIME_MEDIA_STATUS_DRIVER_UNAVAILABLE,
    SSH_NET_REALTIME_MEDIA_STATUS_DUPLICATE_ENDPOINT, SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL,
    SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT, SSH_NET_REALTIME_MEDIA_STATUS_STALE_OWNER,
};

fn direction_from_native(value: u32) -> Option<RealtimeMediaDirection> {
    match value {
        SSH_NET_REALTIME_MEDIA_DIRECTION_SEND => Some(RealtimeMediaDirection::Send),
        SSH_NET_REALTIME_MEDIA_DIRECTION_RECEIVE => Some(RealtimeMediaDirection::Receive),
        _ => None,
    }
}

static NEXT_MEDIA_OWNER_ID: AtomicU64 = AtomicU64::new(1);
const MIN_KEYFRAME_REQUEST_INTERVAL: Duration = Duration::from_secs(1);

const ADAPTATION_REASON_STEADY: u32 = 0;
const ADAPTATION_REASON_CONGESTION: u32 = 1;
const ADAPTATION_REASON_RECOVERY: u32 = 2;

struct MediaOwnerBinding {
    runtime: usize,
    endpoint: u64,
    realtime_id: String,
    peer_id: String,
    generation: u64,
    direction: RealtimeMediaDirection,
    started: bool,
    renderer_attached: bool,
    last_keyframe_request: Option<Instant>,
}

static MEDIA_OWNER_REGISTRY: OnceLock<Mutex<HashMap<u64, MediaOwnerBinding>>> = OnceLock::new();

fn media_owner_registry() -> &'static Mutex<HashMap<u64, MediaOwnerBinding>> {
    MEDIA_OWNER_REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) fn invalidate_media_owners(runtime: *mut SshNetRuntime) {
    if let Ok(mut owners) = media_owner_registry().lock() {
        let runtime = runtime as usize;
        owners.retain(|_, owner| owner.runtime != runtime);
    }
}

fn owner_with_binding(
    owner: u64,
    operation: impl FnOnce(&mut MediaOwnerBinding) -> Result<i32, i32>,
) -> i32 {
    if owner == 0 {
        return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT;
    }
    let result = catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut owners = media_owner_registry()
            .lock()
            .map_err(|_| SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL)?;
        let binding = owners
            .get_mut(&owner)
            .ok_or(SSH_NET_REALTIME_MEDIA_STATUS_STALE_OWNER)?;
        operation(binding)
    }));
    match result {
        Ok(Ok(value)) => value,
        Ok(Err(value)) => value,
        Err(_) => SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL,
    }
}

/// Opens a native-only owner capability for an existing endpoint lease.
///
/// # Safety
/// `handle` must be live; both identifier pointers and `out_owner` must be
/// valid for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_realtime_media_owner_open(
    handle: SshNetRuntimeHandle,
    endpoint: u64,
    realtime_id_ptr: *const u8,
    realtime_id_len: usize,
    peer_id_ptr: *const u8,
    peer_id_len: usize,
    expected_generation: u64,
    direction: u32,
    out_owner: *mut u64,
) -> i32 {
    if handle.is_null()
        || endpoint == 0
        || realtime_id_ptr.is_null()
        || peer_id_ptr.is_null()
        || realtime_id_len == 0
        || peer_id_len == 0
        || expected_generation == 0
        || out_owner.is_null()
    {
        return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT;
    }

    let result = catch_unwind(|| -> Result<i32, i32> {
        unsafe { *out_owner = 0 };
        let realtime_id = match unsafe { identifier(realtime_id_ptr, realtime_id_len) } {
            Ok(value) => value,
            Err(()) => return Ok(SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT),
        };
        let peer_id = match unsafe { identifier(peer_id_ptr, peer_id_len) } {
            Ok(value) => value,
            Err(()) => return Ok(SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT),
        };
        let direction = match direction_from_native(direction) {
            Some(value) => value,
            None => return Ok(SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT),
        };
        let runtime = unsafe { &*(handle as *const SshNetRuntime) };
        if let Err(error) = runtime.runtime.validate_realtime_media_endpoint(
            RealtimeMediaEndpointId::from_raw(endpoint),
            realtime_id,
            peer_id,
            expected_generation,
            direction,
        ) {
            return Ok(map_error(error));
        }
        let owner = NEXT_MEDIA_OWNER_ID.fetch_add(1, Ordering::Relaxed);
        if owner == 0 {
            return Ok(SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL);
        }
        let binding = MediaOwnerBinding {
            runtime: handle as usize,
            endpoint,
            realtime_id: realtime_id.to_owned(),
            peer_id: peer_id.to_owned(),
            generation: expected_generation,
            direction,
            started: false,
            renderer_attached: false,
            last_keyframe_request: None,
        };
        let mut owners = media_owner_registry()
            .lock()
            .map_err(|_| SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL)?;
        if owners
            .values()
            .any(|existing| existing.runtime == handle as usize && existing.endpoint == endpoint)
        {
            return Ok(SSH_NET_REALTIME_MEDIA_STATUS_DUPLICATE_ENDPOINT);
        }
        owners.insert(owner, binding);
        unsafe { *out_owner = owner };
        Ok(0)
    });
    match result {
        Ok(Ok(value)) => value,
        Ok(Err(value)) => value,
        Err(_) => SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL,
    }
}

fn validate_owner(binding: &MediaOwnerBinding) -> Result<(), i32> {
    let runtime = unsafe { &*(binding.runtime as *const SshNetRuntime) };
    runtime
        .runtime
        .validate_realtime_media_endpoint(
            RealtimeMediaEndpointId::from_raw(binding.endpoint),
            &binding.realtime_id,
            &binding.peer_id,
            binding.generation,
            binding.direction,
        )
        .map_err(map_error)
}

/// Starts a native platform owner after generation validation.
#[no_mangle]
pub extern "C" fn ssh_net_realtime_media_owner_start(owner: u64) -> i32 {
    owner_with_binding(owner, |binding| {
        validate_owner(binding)?;
        binding.started = true;
        Ok(0)
    })
}

/// Stops capture/codec production for a native platform owner.
#[no_mangle]
pub extern "C" fn ssh_net_realtime_media_owner_stop(owner: u64) -> i32 {
    owner_with_binding(owner, |binding| {
        validate_owner(binding)?;
        binding.started = false;
        binding.renderer_attached = false;
        Ok(0)
    })
}

/// Validates an owner token without changing its started/renderer state.
///
/// Platform adapters use this low-frequency guard before reporting metadata
/// or source status. Keeping validation separate from `owner_start` prevents a
/// stats poll from accidentally reviving a stopped capture worker.
#[no_mangle]
pub extern "C" fn ssh_net_realtime_media_owner_validate(owner: u64) -> i32 {
    owner_with_binding(owner, |binding| {
        validate_owner(binding)?;
        Ok(0)
    })
}

/// Reads bounded native queue/recovery counters for one valid owner.
///
/// This is an observational bridge: it does not pull or copy an encoded
/// access unit and cannot revive a stopped or stale owner. Statistics remain
/// readable while an owner is stopped so teardown and recovery code can take a
/// final snapshot. The caller must provide writable storage for the fixed-width
/// result structure.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_realtime_media_owner_read_stats(
    owner: u64,
    out_stats: *mut SshNetRealtimeMediaStats,
) -> i32 {
    if owner == 0 || out_stats.is_null() {
        return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT;
    }
    let result = catch_unwind(|| {
        unsafe { *out_stats = SshNetRealtimeMediaStats::default() };
        owner_with_binding(owner, |binding| {
            validate_owner(binding)?;
            let runtime = unsafe { &*(binding.runtime as *const SshNetRuntime) };
            let stats = runtime
                .runtime
                .read_realtime_media_stats(RealtimeMediaEndpointId::from_raw(binding.endpoint))
                .map_err(map_error)?;
            let H264ScreenVideoStats {
                enqueued,
                dequeued,
                dropped,
                keyframe_requests,
                packets_sent,
                packets_received,
                packets_lost,
                frames_recovered,
                jitter_ms,
                rtt_ms,
                queue_depth,
                queue_capacity,
            } = stats;
            unsafe {
                *out_stats = SshNetRealtimeMediaStats {
                    enqueued,
                    dequeued,
                    dropped,
                    keyframe_requests,
                    packets_sent,
                    packets_received,
                    packets_lost,
                    frames_recovered,
                    jitter_ms,
                    rtt_ms,
                    queue_depth,
                    queue_capacity,
                };
            }
            Ok(0)
        })
    });
    match result {
        Ok(value) => value,
        Err(_) => SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL,
    }
}

/// Requests a fresh H.264 keyframe through the generation-bound owner.
///
/// Requests are rate-limited and coalesced by the native queue so a loss burst
/// cannot create an unbounded control storm. The platform caller receives only
/// a status code; the request itself never enters Dart or the Relay path.
#[no_mangle]
pub extern "C" fn ssh_net_realtime_media_owner_request_keyframe(owner: u64) -> i32 {
    owner_with_binding(owner, |binding| {
        validate_owner(binding)?;
        if !binding.started {
            return Err(SSH_NET_REALTIME_MEDIA_STATUS_DRIVER_UNAVAILABLE);
        }
        let now = Instant::now();
        if binding
            .last_keyframe_request
            .is_some_and(|last| now.saturating_duration_since(last) < MIN_KEYFRAME_REQUEST_INTERVAL)
        {
            return Ok(0);
        }
        let runtime = unsafe { &*(binding.runtime as *const SshNetRuntime) };
        runtime
            .runtime
            .request_realtime_media_keyframe(RealtimeMediaEndpointId::from_raw(binding.endpoint))
            .map_err(map_error)?;
        binding.last_keyframe_request = Some(now);
        Ok(0)
    })
}

/// Resets a receive-side H.264 decoder and requests a recovery keyframe.
#[no_mangle]
pub extern "C" fn ssh_net_realtime_media_owner_reset_decoder(owner: u64) -> i32 {
    owner_with_binding(owner, |binding| {
        if binding.direction != RealtimeMediaDirection::Receive {
            return Err(SSH_NET_REALTIME_MEDIA_STATUS_DIRECTION_MISMATCH);
        }
        validate_owner(binding)?;
        if !binding.started {
            return Err(SSH_NET_REALTIME_MEDIA_STATUS_DRIVER_UNAVAILABLE);
        }
        let runtime = unsafe { &*(binding.runtime as *const SshNetRuntime) };
        runtime
            .runtime
            .reset_realtime_media_decoder(RealtimeMediaEndpointId::from_raw(binding.endpoint))
            .map_err(map_error)?;
        binding.last_keyframe_request = Some(Instant::now());
        Ok(0)
    })
}

fn adaptation_reason_from_native(value: u32) -> Option<H264AdaptationReason> {
    match value {
        ADAPTATION_REASON_STEADY => Some(H264AdaptationReason::Steady),
        ADAPTATION_REASON_CONGESTION => Some(H264AdaptationReason::Congestion),
        ADAPTATION_REASON_RECOVERY => Some(H264AdaptationReason::Recovery),
        _ => None,
    }
}

/// Applies one bounded H.264 sender target through the native peer owner.
///
/// The platform owner remains responsible for changing its hardware encoder;
/// this call is the generation-bound native source of truth and rejects a
/// target before any platform codec mutation can occur.
#[no_mangle]
pub extern "C" fn ssh_net_realtime_media_owner_apply_adaptation(
    owner: u64,
    bitrate_kbps: u32,
    framerate: u32,
    width: u32,
    height: u32,
    reason: u32,
) -> i32 {
    owner_with_binding(owner, |binding| {
        if binding.direction != RealtimeMediaDirection::Send {
            return Err(SSH_NET_REALTIME_MEDIA_STATUS_DIRECTION_MISMATCH);
        }
        validate_owner(binding)?;
        if !binding.started {
            return Err(SSH_NET_REALTIME_MEDIA_STATUS_DRIVER_UNAVAILABLE);
        }
        let Some(reason) = adaptation_reason_from_native(reason) else {
            return Err(SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT);
        };
        let target = H264AdaptationTarget {
            bitrate_kbps,
            framerate,
            width,
            height,
            reason,
        };
        if !target.is_valid() {
            return Err(SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT);
        }
        let runtime = unsafe { &*(binding.runtime as *const SshNetRuntime) };
        runtime
            .runtime
            .apply_realtime_media_adaptation(
                RealtimeMediaEndpointId::from_raw(binding.endpoint),
                target,
            )
            .map_err(map_error)?;
        Ok(0)
    })
}

/// Attaches a native renderer capability to a receive owner.
#[no_mangle]
pub extern "C" fn ssh_net_realtime_media_owner_attach_renderer(owner: u64) -> i32 {
    owner_with_binding(owner, |binding| {
        if binding.direction != RealtimeMediaDirection::Receive {
            return Err(SSH_NET_REALTIME_MEDIA_STATUS_DIRECTION_MISMATCH);
        }
        validate_owner(binding)?;
        if binding.renderer_attached {
            return Err(SSH_NET_REALTIME_MEDIA_STATUS_DUPLICATE_ENDPOINT);
        }
        binding.renderer_attached = true;
        Ok(0)
    })
}

/// Detaches a native renderer capability. Detach is idempotent.
#[no_mangle]
pub extern "C" fn ssh_net_realtime_media_owner_detach_renderer(owner: u64) -> i32 {
    owner_with_binding(owner, |binding| {
        validate_owner(binding)?;
        binding.renderer_attached = false;
        Ok(0)
    })
}

/// Closes a native platform owner. Unknown tokens are terminal and idempotent.
#[no_mangle]
pub extern "C" fn ssh_net_realtime_media_owner_close(owner: u64) -> i32 {
    if owner == 0 {
        return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT;
    }
    match media_owner_registry().lock() {
        Ok(mut owners) => {
            owners.remove(&owner);
            0
        }
        Err(_) => SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL,
    }
}

/// Pushes one native-resident H.264 access unit through a send owner.
///
/// # Safety
/// `payload_ptr` must address `payload_len` readable bytes for the duration of
/// this call. The caller retains ownership of the input buffer.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_realtime_media_owner_push_h264(
    owner: u64,
    metadata: SshNetRealtimeMediaFrameMetadata,
    payload_ptr: *const u8,
    payload_len: usize,
) -> i32 {
    if owner == 0 || payload_ptr.is_null() || payload_len == 0 {
        return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT;
    }
    if payload_len > MAX_ENCODED_VIDEO_FRAME_BYTES || metadata.keyframe > 1 {
        return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT;
    }
    let result = catch_unwind(|| -> Result<i32, i32> {
        let owners = media_owner_registry()
            .lock()
            .map_err(|_| SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL)?;
        let binding = owners
            .get(&owner)
            .ok_or(SSH_NET_REALTIME_MEDIA_STATUS_STALE_OWNER)?;
        if binding.direction != RealtimeMediaDirection::Send {
            return Ok(SSH_NET_REALTIME_MEDIA_STATUS_DIRECTION_MISMATCH);
        }
        // Re-validate the complete endpoint identity for every data-plane
        // operation. A token may outlive a session replacement; checking only
        // `started` would let a late native callback reach a stale lease.
        validate_owner(binding)?;
        if !binding.started {
            return Ok(SSH_NET_REALTIME_MEDIA_STATUS_DRIVER_UNAVAILABLE);
        }
        let runtime = unsafe { &*(binding.runtime as *const SshNetRuntime) };
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
        match runtime
            .runtime
            .push_realtime_media_h264(RealtimeMediaEndpointId::from_raw(binding.endpoint), frame)
        {
            Ok(VideoEnqueueResult::Accepted | VideoEnqueueResult::AcceptedAfterDropping { .. }) => {
                Ok(0)
            }
            Ok(VideoEnqueueResult::DroppedIncoming | VideoEnqueueResult::DroppedStale) => {
                Ok(SSH_NET_REALTIME_MEDIA_FRAME_DROPPED)
            }
            Err(error) => Ok(map_error(error)),
        }
    });
    match result {
        Ok(Ok(value)) => value,
        Ok(Err(value)) => value,
        Err(_) => SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL,
    }
}

/// Pulls one native-resident H.264 access unit through a receive owner.
///
/// # Safety
/// `out_metadata` and `out_payload` must point to writable memory for the
/// duration of this call. A returned payload must be released with
/// `ssh_net_buffer_free` exactly once.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_realtime_media_owner_pull_h264(
    owner: u64,
    out_metadata: *mut SshNetRealtimeMediaFrameMetadata,
    out_payload: *mut SshNetBuffer,
) -> i32 {
    if owner == 0 || out_metadata.is_null() || out_payload.is_null() {
        return SSH_NET_REALTIME_MEDIA_STATUS_INVALID_ARGUMENT;
    }
    let result = catch_unwind(|| -> Result<i32, i32> {
        unsafe {
            *out_metadata = SshNetRealtimeMediaFrameMetadata::default();
            *out_payload = SshNetBuffer {
                ptr: std::ptr::null_mut(),
                len: 0,
            };
        }
        let owners = media_owner_registry()
            .lock()
            .map_err(|_| SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL)?;
        let binding = owners
            .get(&owner)
            .ok_or(SSH_NET_REALTIME_MEDIA_STATUS_STALE_OWNER)?;
        if binding.direction != RealtimeMediaDirection::Receive {
            return Ok(SSH_NET_REALTIME_MEDIA_STATUS_DIRECTION_MISMATCH);
        }
        // Pull has the same generation guard as push. Decoder workers can
        // still have a queued callback after stop/replacement, so never read
        // from the runtime until the binding is current.
        validate_owner(binding)?;
        if !binding.started {
            return Ok(SSH_NET_REALTIME_MEDIA_STATUS_DRIVER_UNAVAILABLE);
        }
        let runtime = unsafe { &*(binding.runtime as *const SshNetRuntime) };
        match runtime
            .runtime
            .pop_realtime_media_h264(RealtimeMediaEndpointId::from_raw(binding.endpoint))
        {
            Ok(Some(frame)) => {
                let metadata = SshNetRealtimeMediaFrameMetadata {
                    sequence: frame.sequence,
                    timestamp: frame.timestamp,
                    width: frame.width,
                    height: frame.height,
                    keyframe: u8::from(frame.keyframe),
                };
                let mut payload = frame.payload.into_boxed_slice();
                let payload_len = payload.len();
                let payload_ptr = payload.as_mut_ptr();
                std::mem::forget(payload);
                unsafe {
                    *out_metadata = metadata;
                    *out_payload = SshNetBuffer {
                        ptr: payload_ptr,
                        len: payload_len,
                    };
                }
                Ok(0)
            }
            Ok(None) => Ok(SSH_NET_REALTIME_MEDIA_NO_FRAME),
            Err(error) => Ok(map_error(error)),
        }
    });
    match result {
        Ok(Ok(value)) => value,
        Ok(Err(value)) => value,
        Err(_) => SSH_NET_REALTIME_MEDIA_STATUS_INTERNAL,
    }
}
