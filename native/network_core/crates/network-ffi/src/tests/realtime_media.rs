use super::*;
use crate::realtime_media::{
    ssh_net_realtime_media_endpoint_create, ssh_net_realtime_media_endpoint_pull_h264,
    ssh_net_realtime_media_endpoint_push_h264, ssh_net_realtime_media_endpoint_release,
    SshNetRealtimeMediaFrameMetadata, SSH_NET_REALTIME_MEDIA_DIRECTION_RECEIVE,
    SSH_NET_REALTIME_MEDIA_DIRECTION_SEND, SSH_NET_REALTIME_MEDIA_STATUS_STALE_ENDPOINT,
};
use network_core::RealtimeMediaEndpointId;
use network_webrtc::{EncodedVideoFrame, VideoCodec};
use std::ptr;
use std::time::{Duration, Instant};

const REALTIME_ID: &[u8] = b"00112233445566778899aabbccddeeff";
const PEER_ID: &[u8] = b"peer-a";

fn create_endpoint(handle: SshNetRuntimeHandle, generation: u64, direction: u32) -> (i32, u64) {
    let mut endpoint = 0_u64;
    let status = unsafe {
        ssh_net_realtime_media_endpoint_create(
            handle,
            REALTIME_ID.as_ptr(),
            REALTIME_ID.len(),
            PEER_ID.as_ptr(),
            PEER_ID.len(),
            generation,
            direction,
            &mut endpoint,
        )
    };
    (status, endpoint)
}

#[test]
fn media_endpoint_ffi_success_path_round_trips_native_h264_and_releases_cleanly() {
    let mut handle = ptr::null_mut();
    assert_eq!(unsafe { ssh_net_runtime_create(&mut handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_start(handle) }, 0);

    let runtime = unsafe { &*(handle as *const SshNetRuntime) };
    let generation = runtime
        .runtime
        .install_ffi_test_realtime_session(
            std::str::from_utf8(REALTIME_ID).expect("realtime ID"),
            std::str::from_utf8(PEER_ID).expect("peer ID"),
        )
        .expect("live test realtime session");

    let (status, send_endpoint) =
        create_endpoint(handle, generation, SSH_NET_REALTIME_MEDIA_DIRECTION_SEND);
    assert_eq!(status, 0);
    assert_ne!(send_endpoint, 0);
    let (status, receive_endpoint) =
        create_endpoint(handle, generation, SSH_NET_REALTIME_MEDIA_DIRECTION_RECEIVE);
    assert_eq!(status, 0);
    assert_ne!(receive_endpoint, 0);
    let (status, duplicate_endpoint) =
        create_endpoint(handle, generation, SSH_NET_REALTIME_MEDIA_DIRECTION_SEND);
    assert_eq!(
        status,
        crate::realtime_media::SSH_NET_REALTIME_MEDIA_STATUS_DUPLICATE_ENDPOINT
    );
    assert_eq!(duplicate_endpoint, 0);
    let (status, stale_endpoint) = create_endpoint(
        handle,
        generation.saturating_add(1),
        SSH_NET_REALTIME_MEDIA_DIRECTION_RECEIVE,
    );
    assert_eq!(
        status,
        crate::realtime_media::SSH_NET_REALTIME_MEDIA_STATUS_STALE_GENERATION
    );
    assert_eq!(stale_endpoint, 0);

    let metadata = SshNetRealtimeMediaFrameMetadata {
        sequence: 7,
        timestamp: 90_000,
        width: 1_920,
        height: 1_080,
        keyframe: 1,
    };
    let payload = [0, 0, 0, 1, 0x65, 0x01, 0x02];
    assert_eq!(
        unsafe {
            ssh_net_realtime_media_endpoint_push_h264(
                handle,
                send_endpoint,
                metadata,
                payload.as_ptr(),
                payload.len(),
            )
        },
        0
    );

    let malformed_payload = [0, 0, 0, 1];
    assert_eq!(
        unsafe {
            ssh_net_realtime_media_endpoint_push_h264(
                handle,
                send_endpoint,
                SshNetRealtimeMediaFrameMetadata {
                    sequence: 8,
                    timestamp: 93_000,
                    ..metadata
                },
                malformed_payload.as_ptr(),
                malformed_payload.len(),
            )
        },
        crate::realtime_media::SSH_NET_REALTIME_MEDIA_STATUS_FRAME_REJECTED
    );

    runtime
        .runtime
        .inject_ffi_test_realtime_media_frame(
            RealtimeMediaEndpointId::from_raw(receive_endpoint),
            EncodedVideoFrame::new(
                VideoCodec::H264,
                8,
                96_000,
                1_920,
                1_080,
                true,
                payload.to_vec(),
                Instant::now() + Duration::from_secs(1),
            ),
        )
        .expect("inject one packetized receive frame");

    let mut returned_metadata = SshNetRealtimeMediaFrameMetadata::default();
    let mut returned_payload = SshNetBuffer {
        ptr: ptr::null_mut(),
        len: 0,
    };
    assert_eq!(
        unsafe {
            ssh_net_realtime_media_endpoint_pull_h264(
                handle,
                receive_endpoint,
                &mut returned_metadata,
                &mut returned_payload,
            )
        },
        0
    );
    assert_eq!(returned_metadata.sequence, 0);
    assert_eq!(returned_metadata.timestamp, 96_000);
    assert_eq!(returned_metadata.keyframe, 1);
    let returned =
        unsafe { std::slice::from_raw_parts(returned_payload.ptr, returned_payload.len) };
    assert_eq!(returned, payload);
    unsafe { ssh_net_buffer_free(returned_payload) };

    assert_eq!(
        unsafe { ssh_net_realtime_media_endpoint_release(handle, send_endpoint) },
        0
    );
    assert_eq!(
        unsafe { ssh_net_realtime_media_endpoint_release(handle, receive_endpoint) },
        0
    );
    assert_eq!(
        unsafe {
            ssh_net_realtime_media_endpoint_push_h264(
                handle,
                send_endpoint,
                metadata,
                payload.as_ptr(),
                payload.len(),
            )
        },
        SSH_NET_REALTIME_MEDIA_STATUS_STALE_ENDPOINT
    );
    assert_eq!(unsafe { ssh_net_runtime_stop(handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_destroy(handle) }, 0);
}

#[test]
fn media_endpoint_ffi_is_payload_free_and_enforces_runtime_lifecycle() {
    let mut handle = ptr::null_mut();
    assert_eq!(unsafe { ssh_net_runtime_create(&mut handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_start(handle) }, 0);

    let mut endpoint = 99_u64;
    assert_eq!(
        unsafe {
            crate::realtime_media::ssh_net_realtime_media_endpoint_create(
                handle,
                REALTIME_ID.as_ptr(),
                REALTIME_ID.len(),
                PEER_ID.as_ptr(),
                PEER_ID.len(),
                1,
                crate::realtime_media::SSH_NET_REALTIME_MEDIA_DIRECTION_SEND,
                &mut endpoint,
            )
        },
        -2,
    );
    assert_eq!(endpoint, 0);
    assert_eq!(
        unsafe { crate::realtime_media::ssh_net_realtime_media_endpoint_release(handle, 0) },
        -1,
    );

    assert_eq!(unsafe { ssh_net_runtime_stop(handle) }, 0);
    assert_eq!(
        unsafe {
            crate::realtime_media::ssh_net_realtime_media_endpoint_create(
                handle,
                REALTIME_ID.as_ptr(),
                REALTIME_ID.len(),
                PEER_ID.as_ptr(),
                PEER_ID.len(),
                1,
                crate::realtime_media::SSH_NET_REALTIME_MEDIA_DIRECTION_SEND,
                &mut endpoint,
            )
        },
        -4,
    );
    assert_eq!(
        unsafe { crate::realtime_media::ssh_net_realtime_media_endpoint_release(handle, 42) },
        0,
    );
    assert_eq!(unsafe { ssh_net_runtime_destroy(handle) }, 0);
}

#[test]
fn native_h264_bridge_rejects_unknown_or_stopped_endpoint_without_returning_media() {
    let mut handle = ptr::null_mut();
    assert_eq!(unsafe { ssh_net_runtime_create(&mut handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_start(handle) }, 0);

    let metadata = crate::realtime_media::SshNetRealtimeMediaFrameMetadata {
        sequence: 1,
        timestamp: 90_000,
        width: 1280,
        height: 720,
        keyframe: 1,
    };
    let payload = [0, 0, 0, 1, 0x65];
    assert_eq!(
        unsafe {
            crate::realtime_media::ssh_net_realtime_media_endpoint_push_h264(
                handle,
                42,
                metadata,
                payload.as_ptr(),
                payload.len(),
            )
        },
        crate::realtime_media::SSH_NET_REALTIME_MEDIA_STATUS_STALE_ENDPOINT,
    );

    let mut returned_metadata = Default::default();
    let mut returned_payload = SshNetBuffer {
        ptr: ptr::null_mut(),
        len: 99,
    };
    assert_eq!(
        unsafe {
            crate::realtime_media::ssh_net_realtime_media_endpoint_pull_h264(
                handle,
                42,
                &mut returned_metadata,
                &mut returned_payload,
            )
        },
        crate::realtime_media::SSH_NET_REALTIME_MEDIA_STATUS_STALE_ENDPOINT,
    );
    assert!(returned_payload.ptr.is_null());
    assert_eq!(returned_payload.len, 0);

    assert_eq!(unsafe { ssh_net_runtime_stop(handle) }, 0);
    assert_eq!(
        unsafe {
            crate::realtime_media::ssh_net_realtime_media_endpoint_push_h264(
                handle,
                42,
                metadata,
                payload.as_ptr(),
                payload.len(),
            )
        },
        -4,
    );
    assert_eq!(unsafe { ssh_net_runtime_destroy(handle) }, 0);
}
