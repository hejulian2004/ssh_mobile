use super::*;
use network_webrtc::{
    EncodedVideoFrame, MediaDirection, RealtimeIoDriver, VideoCodec, WebRtcConfig, WebRtcPeer,
};
use std::time::{Duration, Instant};

const REALTIME_ID: &str = "00112233445566778899aabbccddeeff";
const PEER_ID: &str = "peer-a";

async fn test_driver() -> RealtimeIoDriverHandle {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("create peer");
    peer.configure_h264_screen_video(MediaDirection::Sendrecv, Some(1))
        .expect("configure H.264 screen video");
    RealtimeIoDriver::bind(peer, "127.0.0.1:0".parse().expect("socket address"))
        .await
        .expect("bind realtime I/O driver")
        .into_handle()
}

fn frame(payload_len: usize) -> EncodedVideoFrame {
    let mut payload = vec![0, 0, 0, 1, 0x65];
    payload.resize(payload_len.max(5), 0x11);
    EncodedVideoFrame::new(
        VideoCodec::H264,
        1,
        90_000,
        1280,
        720,
        true,
        payload,
        Instant::now() + Duration::from_secs(1),
    )
}

#[tokio::test]
async fn endpoint_registry_rejects_duplicate_direction_and_release_is_idempotent() {
    let driver = test_driver().await;
    let mut registry = RealtimeMediaRegistry::new();
    let endpoint = registry
        .create(
            REALTIME_ID,
            PEER_ID,
            RealtimeMediaDirection::Send,
            1,
            1,
            &driver,
        )
        .expect("create send endpoint");

    assert!(matches!(
        registry.create(
            REALTIME_ID,
            PEER_ID,
            RealtimeMediaDirection::Send,
            1,
            1,
            &driver
        ),
        Err(RealtimeMediaError::DuplicateEndpoint)
    ));

    registry.release(endpoint).expect("release endpoint");
    registry.release(endpoint).expect("release endpoint twice");
    assert!(matches!(
        registry.with_endpoint(endpoint, RealtimeMediaDirection::Send, |driver| {
            driver
                .peer_mut()
                .enqueue_h264_screen_video(frame(32), Instant::now())
        }),
        Err(RealtimeMediaError::StaleEndpoint)
    ));
}

#[tokio::test]
async fn releasing_an_endpoint_discards_its_pending_native_video_queue() {
    let driver = test_driver().await;
    let mut registry = RealtimeMediaRegistry::new();
    let endpoint = registry
        .create(
            REALTIME_ID,
            PEER_ID,
            RealtimeMediaDirection::Send,
            1,
            1,
            &driver,
        )
        .expect("create send endpoint");

    registry
        .with_endpoint(endpoint, RealtimeMediaDirection::Send, |driver| {
            driver
                .peer_mut()
                .enqueue_h264_screen_video(frame(32), Instant::now())
        })
        .expect("enqueue native video");
    assert_eq!(
        driver
            .lock()
            .expect("driver lock")
            .peer_mut()
            .pending_h264_screen_video_frames(),
        1
    );

    registry.release(endpoint).expect("release endpoint");
    assert_eq!(
        driver
            .lock()
            .expect("driver lock")
            .peer_mut()
            .pending_h264_screen_video_frames(),
        0
    );

    let replacement = registry
        .create(
            REALTIME_ID,
            PEER_ID,
            RealtimeMediaDirection::Send,
            1,
            1,
            &driver,
        )
        .expect("create replacement send endpoint");
    registry
        .with_endpoint(replacement, RealtimeMediaDirection::Send, |driver| {
            driver
                .peer_mut()
                .enqueue_h264_screen_video(frame(32), Instant::now())
                .map(|_| ())
        })
        .expect("replacement endpoint accepts a fresh sequence");
}

#[tokio::test]
async fn endpoint_registry_invalidates_all_leases_when_its_runtime_stops() {
    let driver = test_driver().await;
    let mut registry = RealtimeMediaRegistry::new();
    let endpoint = registry
        .create(
            REALTIME_ID,
            PEER_ID,
            RealtimeMediaDirection::Receive,
            1,
            1,
            &driver,
        )
        .expect("create receive endpoint");

    registry.invalidate_all();

    assert!(matches!(
        registry.with_endpoint(endpoint, RealtimeMediaDirection::Receive, |_| Ok(())),
        Err(RealtimeMediaError::StaleEndpoint)
    ));
}

#[tokio::test]
async fn endpoint_registry_invalidates_prior_session_generation_before_new_driver() {
    let first_driver = test_driver().await;
    let mut registry = RealtimeMediaRegistry::new();
    let first = registry
        .create(
            REALTIME_ID,
            PEER_ID,
            RealtimeMediaDirection::Send,
            1,
            1,
            &first_driver,
        )
        .expect("create first endpoint");
    let first_generation = registry
        .session_generation(first)
        .expect("first endpoint generation");

    registry.invalidate_realtime(REALTIME_ID);
    assert!(matches!(
        registry.with_endpoint(first, RealtimeMediaDirection::Send, |_| Ok(())),
        Err(RealtimeMediaError::StaleEndpoint)
    ));

    let second_driver = test_driver().await;
    let second = registry
        .create(
            REALTIME_ID,
            PEER_ID,
            RealtimeMediaDirection::Send,
            2,
            2,
            &second_driver,
        )
        .expect("create endpoint for replacement driver");
    assert_ne!(
        registry
            .session_generation(second)
            .expect("replacement endpoint generation"),
        first_generation
    );
}

#[tokio::test]
async fn endpoint_registry_enforces_direction_and_queue_frame_limits() {
    let driver = test_driver().await;
    let mut registry = RealtimeMediaRegistry::new();
    let receive = registry
        .create(
            REALTIME_ID,
            PEER_ID,
            RealtimeMediaDirection::Receive,
            1,
            1,
            &driver,
        )
        .expect("create receive endpoint");
    assert!(matches!(
        registry.with_endpoint(receive, RealtimeMediaDirection::Send, |_| Ok(())),
        Err(RealtimeMediaError::DirectionMismatch)
    ));

    let send = registry
        .create(
            REALTIME_ID,
            PEER_ID,
            RealtimeMediaDirection::Send,
            1,
            1,
            &driver,
        )
        .expect("create send endpoint");
    assert!(matches!(
        registry.with_endpoint(send, RealtimeMediaDirection::Send, |driver| {
            driver.peer_mut().enqueue_h264_screen_video(
                frame(network_webrtc::MAX_ENCODED_VIDEO_FRAME_BYTES + 1),
                Instant::now(),
            )
        }),
        Err(RealtimeMediaError::FrameRejected)
    ));
}

#[tokio::test]
async fn release_keeps_the_lease_retryable_when_queue_cleanup_fails() {
    let driver = test_driver().await;
    let mut registry = RealtimeMediaRegistry::new();
    let endpoint = registry
        .create(
            REALTIME_ID,
            PEER_ID,
            RealtimeMediaDirection::Send,
            1,
            1,
            &driver,
        )
        .expect("create send endpoint");

    let poisoned_driver = driver.clone();
    std::thread::spawn(move || {
        let _guard = poisoned_driver.lock().expect("driver lock");
        panic!("force cleanup lock failure");
    })
    .join()
    .expect_err("thread must poison the driver mutex");

    assert!(matches!(
        registry.release(endpoint),
        Err(RealtimeMediaError::DriverUnavailable)
    ));
    assert_eq!(registry.session_generation(endpoint), Some(1));

    driver.clear_poison();
    registry.release(endpoint).expect("retry cleanup");
    assert_eq!(registry.session_generation(endpoint), None);
}

#[test]
fn endpoint_registry_validates_identifiers_without_retaining_input() {
    assert!(matches!(
        validate_identifiers("invalid", PEER_ID),
        Err(RealtimeMediaError::InvalidRealtimeId)
    ));
    assert!(matches!(
        validate_identifiers(REALTIME_ID, ""),
        Err(RealtimeMediaError::InvalidPeerId)
    ));
}
