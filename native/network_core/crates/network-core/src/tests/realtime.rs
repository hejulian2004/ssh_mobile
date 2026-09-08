use super::*;
use network_protocol::{network_event, NetworkErrorCode};
use network_relay::v2::{DiscoveryAck, DiscoverySnapshot, ResolvePeerResponse};
use network_relay::RelayError;
use network_webrtc::media::RtpPacketizer;
use network_webrtc::{
    DataChannelReliability, EncodedVideoFrame, MediaDirection, RealtimeIoDriver, SignalingState,
    VideoCodec, VideoEnqueueResult, WebRtcConfig, WebRtcPeer,
};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::discovery::DiscoveryControlPlane;
use crate::runtime::ConnectDecision;
use crate::runtime::PeerConfig;
use crate::NetworkRuntime;

#[test]
fn media_endpoint_driver_requires_a_current_matching_realtime_session() {
    let realtime_id = "00112233445566778899aabbccddeeff";
    let mut manager = RealtimeManager::default();

    assert!(matches!(
        manager.media_endpoint_driver(realtime_id, "peer-a"),
        Err(crate::realtime_media::RealtimeMediaError::UnknownRealtimeSession)
    ));

    manager.insert_existing_session(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: None,
            driver: None,
            revision: 1,
            remote_revision: 0,
            ice_revision: 1,
            seen_candidates: HashSet::new(),
        },
    );

    assert!(matches!(
        manager.media_endpoint_driver(realtime_id, "peer-b"),
        Err(crate::realtime_media::RealtimeMediaError::PeerMismatch)
    ));
    assert!(matches!(
        manager.media_endpoint_driver(realtime_id, "peer-a"),
        Err(crate::realtime_media::RealtimeMediaError::DriverUnavailable)
    ));
}

#[tokio::test]
async fn delayed_old_generation_cannot_create_an_endpoint_on_a_replacement_session() {
    let (state, _event_rx) = realtime_test_state().await;
    let realtime_id = "00112233445566778899aabbccddeeff";
    let peer_id = "peer-a";
    let first_driver = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("first peer"),
        "127.0.0.1:0".parse().expect("first bind address"),
    )
    .await
    .expect("first driver")
    .into_handle();
    let stale_generation = {
        let mut manager = state.realtime.lock().await;
        manager.insert_new_session(
            realtime_id.into(),
            RealtimeSession {
                peer_id: peer_id.into(),
                connection_session_id: None,
                peer: None,
                driver: Some(first_driver),
                revision: 1,
                remote_revision: 0,
                ice_revision: 1,
                seen_candidates: HashSet::new(),
            },
        );
        manager
            .session_generation(realtime_id)
            .expect("first generation")
    };

    let second_driver = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("replacement peer"),
        "127.0.0.1:0".parse().expect("replacement bind address"),
    )
    .await
    .expect("replacement driver")
    .into_handle();
    let current_generation = {
        let mut manager = state.realtime.lock().await;
        manager.remove_session(realtime_id);
        manager.insert_new_session(
            realtime_id.into(),
            RealtimeSession {
                peer_id: peer_id.into(),
                connection_session_id: None,
                peer: None,
                driver: Some(second_driver),
                revision: 2,
                remote_revision: 0,
                ice_revision: 2,
                seen_candidates: HashSet::new(),
            },
        );
        manager
            .session_generation(realtime_id)
            .expect("replacement generation")
    };
    assert_ne!(stale_generation, current_generation);

    assert!(matches!(
        crate::realtime_media::create_endpoint(
            &state,
            realtime_id,
            peer_id,
            crate::realtime_media::RealtimeMediaDirection::Send,
            stale_generation,
        )
        .await,
        Err(crate::realtime_media::RealtimeMediaError::StaleGeneration)
    ));
    assert!(crate::realtime_media::create_endpoint(
        &state,
        realtime_id,
        peer_id,
        crate::realtime_media::RealtimeMediaDirection::Send,
        current_generation,
    )
    .await
    .is_ok());
}

#[tokio::test]
async fn media_endpoints_bridge_native_h264_without_exposing_a_peer_handle() {
    let (state, _event_rx) = realtime_test_state().await;
    let realtime_id = "00112233445566778899aabbccddeeff";
    let peer_id = "peer-a";
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("native WebRTC peer");
    peer.configure_h264_screen_video(MediaDirection::Sendrecv, Some(0x1357_2468))
        .expect("H.264 screen-video track");
    let driver =
        RealtimeIoDriver::bind(peer, "127.0.0.1:0".parse().expect("loopback bind address"))
            .await
            .expect("native I/O driver")
            .into_handle();
    state.realtime.lock().await.insert_new_session(
        realtime_id.into(),
        RealtimeSession {
            peer_id: peer_id.into(),
            connection_session_id: None,
            peer: None,
            driver: Some(Arc::clone(&driver)),
            revision: 1,
            remote_revision: 0,
            ice_revision: 1,
            seen_candidates: HashSet::new(),
        },
    );
    let generation = state
        .realtime
        .lock()
        .await
        .session_generation(realtime_id)
        .expect("session generation");

    let send = crate::realtime_media::create_endpoint(
        &state,
        realtime_id,
        peer_id,
        crate::realtime_media::RealtimeMediaDirection::Send,
        generation,
    )
    .await
    .expect("send endpoint");
    let receive = crate::realtime_media::create_endpoint(
        &state,
        realtime_id,
        peer_id,
        crate::realtime_media::RealtimeMediaDirection::Receive,
        generation,
    )
    .await
    .expect("receive endpoint");
    let mut payload = vec![
        0, 0, 0, 1, 0x67, 0x42, 0, 0x1f, 0xe5, 0x88, 0x68, 0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80, 0,
        0, 0, 1, 0x65,
    ];
    payload.extend((0..640).map(|index| (index as u8).wrapping_mul(37)));
    let input = EncodedVideoFrame::new(
        VideoCodec::H264,
        42,
        90_000,
        1_280,
        720,
        true,
        payload,
        std::time::Instant::now() + Duration::from_secs(1),
    );

    assert!(matches!(
        crate::realtime_media::push_endpoint(&state, send, input.clone()),
        Ok(VideoEnqueueResult::Accepted)
    ));
    assert_eq!(
        driver
            .lock()
            .expect("driver lock")
            .peer_mut()
            .pending_h264_screen_video_frames(),
        1,
        "the opaque send endpoint reaches the native-only ingress queue"
    );

    let mut packetizer = RtpPacketizer::new(1_200, 102, 0x1357_2468, 1);
    let packets = packetizer.packetize(&input).expect("packetize H.264 input");
    {
        let mut driver = driver.lock().expect("driver lock");
        for packet in &packets {
            driver
                .peer_mut()
                .receive_h264_screen_video_rtp(packet, std::time::Instant::now())
                .expect("native RTP ingress");
        }
    }

    let received = crate::realtime_media::pop_endpoint(&state, receive)
        .expect("opaque receive endpoint")
        .expect("completed native H.264 frame");
    assert_eq!(received.codec, VideoCodec::H264);
    assert_eq!(received.sequence, 0);
    assert_eq!(received.timestamp, input.timestamp);
    assert_eq!(received.width, 1_920);
    assert_eq!(received.height, 1_080);
    assert!(received.keyframe);
    assert_eq!(received.payload, input.payload);

    crate::realtime_media::release_endpoint(&state, send).expect("release send endpoint");
    assert!(matches!(
        crate::realtime_media::push_endpoint(&state, send, input),
        Err(crate::realtime_media::RealtimeMediaError::StaleEndpoint)
    ));
}

#[test]
fn runtime_stop_revokes_live_media_endpoints_before_runtime_state_is_released() {
    let runtime = NetworkRuntime::new().expect("create runtime");
    runtime.start().expect("start runtime");
    let state = runtime
        .state
        .lock()
        .expect("runtime state lock")
        .clone()
        .expect("running runtime state");
    let realtime_id = "00112233445566778899aabbccddeeff";
    let peer_id = "peer-a";
    let driver = runtime.handle().block_on(async {
        let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("native WebRTC peer");
        peer.configure_h264_screen_video(MediaDirection::Sendrecv, Some(0x2468_1357))
            .expect("H.264 screen-video track");
        RealtimeIoDriver::bind(peer, "127.0.0.1:0".parse().expect("loopback bind address"))
            .await
            .expect("native I/O driver")
            .into_handle()
    });
    let generation = runtime.handle().block_on(async {
        state.realtime.lock().await.insert_new_session(
            realtime_id.into(),
            RealtimeSession {
                peer_id: peer_id.into(),
                connection_session_id: None,
                peer: None,
                driver: Some(Arc::clone(&driver)),
                revision: 1,
                remote_revision: 0,
                ice_revision: 1,
                seen_candidates: HashSet::new(),
            },
        );
        state
            .realtime
            .lock()
            .await
            .session_generation(realtime_id)
            .expect("session generation")
    });

    let endpoint = runtime
        .create_realtime_media_endpoint(
            realtime_id,
            peer_id,
            crate::realtime_media::RealtimeMediaDirection::Send,
            generation,
        )
        .expect("create runtime-owned endpoint");

    runtime.stop().expect("stop runtime");

    assert!(matches!(
        crate::realtime_media::push_endpoint(
            &state,
            endpoint,
            EncodedVideoFrame::new(
                VideoCodec::H264,
                1,
                90_000,
                1280,
                720,
                true,
                vec![0x65],
                std::time::Instant::now() + Duration::from_secs(1),
            ),
        ),
        Err(crate::realtime_media::RealtimeMediaError::StaleEndpoint)
    ));
    assert!(runtime.release_realtime_media_endpoint(endpoint).is_ok());
    assert!(matches!(
        runtime.create_realtime_media_endpoint(
            realtime_id,
            peer_id,
            crate::realtime_media::RealtimeMediaDirection::Send,
            1,
        ),
        Err(crate::realtime_media::RealtimeMediaError::RuntimeNotRunning)
    ));
}

#[tokio::test]
async fn connection_session_loss_invalidates_bound_media_endpoints() {
    let (state, _event_rx) = realtime_test_state().await;
    let realtime_id = "00112233445566778899aabbccddeeff";
    let peer_id = "peer-a";
    let connection_session_id = SessionId::from_bytes([9u8; 16]);
    let driver = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("native WebRTC peer"),
        "127.0.0.1:0".parse().expect("loopback bind address"),
    )
    .await
    .expect("native I/O driver")
    .into_handle();

    state.realtime.lock().await.insert_new_session(
        realtime_id.into(),
        RealtimeSession {
            peer_id: peer_id.into(),
            connection_session_id: Some(connection_session_id),
            peer: None,
            driver: Some(Arc::clone(&driver)),
            revision: 1,
            remote_revision: 0,
            ice_revision: 1,
            seen_candidates: HashSet::new(),
        },
    );
    let generation = state
        .realtime
        .lock()
        .await
        .session_generation(realtime_id)
        .expect("session generation");
    let endpoint = crate::realtime_media::create_endpoint(
        &state,
        realtime_id,
        peer_id,
        crate::realtime_media::RealtimeMediaDirection::Send,
        generation,
    )
    .await
    .expect("media endpoint");

    close_realtime_sessions_for_session(&state, peer_id, connection_session_id).await;

    assert!(matches!(
        crate::realtime_media::push_endpoint(
            &state,
            endpoint,
            EncodedVideoFrame::new(
                VideoCodec::H264,
                1,
                90_000,
                1280,
                720,
                true,
                vec![0x65],
                std::time::Instant::now() + Duration::from_secs(1),
            ),
        ),
        Err(crate::realtime_media::RealtimeMediaError::StaleEndpoint)
    ));
}

#[tokio::test]
async fn realtime_snapshot_carries_authoritative_state_and_revision_after_connected() {
    let (event_tx, mut event_rx) = unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(std::sync::atomic::AtomicU16::new(0)));
    let realtime_id = "00112233445566778899aabbccddeeff";
    {
        let mut manager = state.realtime.lock().await;
        manager.sessions.insert(
            realtime_id.into(),
            RealtimeSession {
                peer_id: "peer-a".into(),
                connection_session_id: None,
                peer: None,
                driver: None,
                revision: 7,
                remote_revision: 2,
                ice_revision: 3,
                seen_candidates: HashSet::new(),
            },
        );
    }
    let finished = handle_io_event(
        &state,
        realtime_id,
        "peer-a",
        RealtimeIoEvent::PeerConnected,
    )
    .await;
    assert!(!finished);
    let mut state_events = Vec::new();
    let mut snapshots = Vec::new();
    while let Ok(event) = event_rx.try_recv() {
        match event.payload {
            Some(network_event::Payload::RealtimeState(delta)) => state_events.push(delta),
            Some(network_event::Payload::RealtimeSnapshot(snapshot)) => snapshots.push(snapshot),
            _ => {}
        }
    }
    assert_eq!(state_events.len(), 1);
    assert_eq!(
        state_events[0].state,
        RealtimeSessionState::Connected as i32
    );
    assert_eq!(snapshots.len(), 1);
    assert_eq!(snapshots[0].realtime_id, realtime_id);
    assert_eq!(snapshots[0].peer_id, "peer-a");
    assert_eq!(snapshots[0].state, RealtimeSessionState::Connected as i32);
    assert_eq!(snapshots[0].revision, 7);
    assert!(snapshots[0].error.is_none());
}

#[tokio::test]
async fn realtime_io_event_matrix_maps_lifecycle_and_failure_boundaries() {
    let (event_tx, mut event_rx) = unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(std::sync::atomic::AtomicU16::new(0)));
    let realtime_id = "00112233445566778899aabbccddeeff";
    {
        let mut manager = state.realtime.lock().await;
        manager.sessions.insert(
            realtime_id.into(),
            RealtimeSession {
                peer_id: "peer-a".into(),
                connection_session_id: None,
                peer: None,
                driver: None,
                revision: 4,
                remote_revision: 2,
                ice_revision: 3,
                seen_candidates: HashSet::new(),
            },
        );
    }

    assert!(
        !handle_io_event(
            &state,
            realtime_id,
            "peer-a",
            RealtimeIoEvent::LocalIceCandidate(
                network_webrtc::IceCandidate::new(
                    "candidate:1 1 UDP 1 127.0.0.1 9 typ host".into(),
                    None,
                    None,
                    None,
                )
                .expect("valid local candidate"),
            ),
        )
        .await
    );
    assert!(
        !handle_io_event(
            &state,
            realtime_id,
            "wrong-peer",
            RealtimeIoEvent::LocalIceCandidate(network_webrtc::IceCandidate::end_of_candidates()),
        )
        .await
    );
    assert!(
        !handle_io_event(
            &state,
            realtime_id,
            "peer-a",
            RealtimeIoEvent::PeerConnected,
        )
        .await
    );
    assert!(
        !handle_io_event(
            &state,
            realtime_id,
            "peer-a",
            RealtimeIoEvent::DataChannelMessage {
                channel_id: 7,
                is_string: false,
                payload: b"ignored-by-signaling-owner".to_vec(),
            },
        )
        .await
    );
    for event in [
        RealtimeIoEvent::IceConnected,
        RealtimeIoEvent::DataChannelOpened(7),
        RealtimeIoEvent::DataChannelClosed(7),
    ] {
        assert!(!handle_io_event(&state, realtime_id, "peer-a", event).await);
    }

    let mut state_events = Vec::new();
    while let Ok(event) = event_rx.try_recv() {
        state_events.push(event);
    }
    assert!(state_events.iter().any(|event| matches!(
        event.payload,
        Some(network_event::Payload::RealtimeState(ref state))
            if state.state == RealtimeSessionState::Connected as i32
    )));
    assert!(
        handle_io_event(
            &state,
            realtime_id,
            "peer-a",
            RealtimeIoEvent::PeerDisconnected,
        )
        .await,
        "a disconnected peer is terminal: retry needs a new session and PeerConnection"
    );
    let mut terminal_events = Vec::new();
    while let Ok(event) = event_rx.try_recv() {
        terminal_events.push(event);
    }
    assert!(terminal_events.iter().any(|event| matches!(
        event.payload,
        Some(network_event::Payload::RealtimeState(ref state))
            if state.state == RealtimeSessionState::Failed as i32
    )));
    remove_realtime_session(&state, realtime_id, "peer-a").await;
    assert!(!state
        .realtime
        .lock()
        .await
        .sessions
        .contains_key(realtime_id));
}

#[tokio::test]
async fn realtime_session_io_removes_owner_after_driver_failure() {
    let (state, mut event_rx) = realtime_test_state().await;
    let realtime_id = "00112233445566778899aabbccddeeff";
    let driver = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("driver peer"),
        "127.0.0.1:0".parse().expect("driver bind address"),
    )
    .await
    .expect("driver");
    let driver = driver.into_handle();
    state.realtime.lock().await.insert_new_session(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: None,
            driver: Some(Arc::clone(&driver)),
            revision: 5,
            remote_revision: 1,
            ice_revision: 5,
            seen_candidates: HashSet::new(),
        },
    );
    let poison = Arc::clone(&driver);
    let poison_task = std::thread::spawn(move || {
        let _guard = poison.lock().expect("driver lock");
        panic!("inject driver owner failure");
    });
    assert!(poison_task.join().is_err());

    run_realtime_session_io(
        Arc::clone(&state),
        realtime_id.into(),
        "peer-a".into(),
        driver,
    )
    .await;
    assert!(!state
        .realtime
        .lock()
        .await
        .sessions
        .contains_key(realtime_id));
    let mut failed = false;
    while let Ok(event) = event_rx.try_recv() {
        if matches!(
            event.payload,
            Some(network_event::Payload::RealtimeState(ref state))
                if state.state == RealtimeSessionState::Failed as i32
        ) {
            failed = true;
        }
    }
    assert!(
        failed,
        "driver failure must emit a Failed state before removal"
    );
}

#[tokio::test]
async fn task_supervisor_drives_two_runtime_realtime_data_channels() {
    let caller = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("caller peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("caller driver")
    .into_handle();
    let responder = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("responder peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("responder driver")
    .into_handle();

    let channel_id = caller
        .lock()
        .unwrap()
        .peer_mut()
        .create_data_channel("runtime-e2e", DataChannelReliability::default())
        .expect("data channel");
    let offer = caller.lock().unwrap().peer_mut().create_offer().unwrap();
    let answer = {
        let mut responder_driver = responder.lock().unwrap();
        responder_driver
            .peer_mut()
            .accept_remote_offer(offer)
            .unwrap();
        responder_driver.peer_mut().create_answer().unwrap()
    };
    caller
        .lock()
        .unwrap()
        .peer_mut()
        .accept_remote_answer(answer)
        .unwrap();

    let supervisor = crate::task_supervisor::RuntimeTaskSupervisor::new();
    let (caller_tx, mut caller_rx) = mpsc::channel(network_webrtc::REALTIME_IO_EVENT_CAPACITY);
    let (responder_tx, mut responder_rx) =
        mpsc::channel(network_webrtc::REALTIME_IO_EVENT_CAPACITY);
    let caller_task_handle = Arc::clone(&caller);
    let responder_task_handle = Arc::clone(&responder);
    assert!(supervisor
        .spawn_session("realtime:caller", "webrtc-io", async move {
            let _ = run_realtime_io(caller_task_handle, caller_tx).await;
        },)
        .is_some());
    assert!(supervisor
        .spawn_session("realtime:responder", "webrtc-io", async move {
            let _ = run_realtime_io(responder_task_handle, responder_tx).await;
        },)
        .is_some());

    let mut caller_open = false;
    let mut responder_open = false;
    let open_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !(caller_open && responder_open) {
        tokio::select! {
            Some(event) = caller_rx.recv() => {
                caller_open |= matches!(event, RealtimeIoEvent::DataChannelOpened(_));
                assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
            }
            Some(event) = responder_rx.recv() => {
                responder_open |= matches!(event, RealtimeIoEvent::DataChannelOpened(_));
                assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
            }
            _ = tokio::time::sleep_until(open_deadline) => panic!("supervised data channel did not open"),
        }
    }
    caller
        .lock()
        .unwrap()
        .peer_mut()
        .send_data(channel_id, b"runtime-frame")
        .unwrap();
    let payload_deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let payload = loop {
        tokio::select! {
            Some(event) = responder_rx.recv() => {
                if let RealtimeIoEvent::DataChannelMessage { payload, .. } = event {
                    break payload;
                }
            }
            Some(_event) = caller_rx.recv() => {}
            _ = tokio::time::sleep_until(payload_deadline) => panic!("supervised data channel payload not received"),
        }
    };
    assert_eq!(payload, b"runtime-frame");

    supervisor.cancel_session("realtime:caller").await;
    supervisor.cancel_session("realtime:responder").await;
}

#[test]
fn offer_answer_and_stale_revision_are_session_bound() {
    let realtime_id = "00112233445566778899aabbccddeeff";
    let mut caller = WebRtcPeer::new(WebRtcConfig::default()).expect("caller");
    caller
        .create_data_channel("ssh-mobile-realtime", Default::default())
        .expect("data channel");
    let offer = caller.create_offer().expect("offer");
    let caller_revision = caller.signaling_revision();

    let mut responder_manager = RealtimeManager::default();
    let answer = apply_signal(
        &mut responder_manager,
        realtime_id,
        "peer-a",
        RealtimeSignalKind::WebRtcOffer,
        caller_revision,
        offer.sdp.into_bytes(),
    )
    .expect("answer");
    assert_eq!(answer.state, RealtimeSessionState::Negotiating);
    let answer = answer.outbound.expect("answer signal");

    let mut caller_manager = RealtimeManager::default();
    caller_manager.sessions.insert(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-b".into(),
            connection_session_id: None,
            peer: Some(caller),
            driver: None,
            revision: caller_revision,
            remote_revision: 0,
            ice_revision: caller_revision,
            seen_candidates: HashSet::new(),
        },
    );
    let connected = apply_signal(
        &mut caller_manager,
        realtime_id,
        "peer-b",
        RealtimeSignalKind::WebRtcAnswer,
        answer.revision,
        answer.payload,
    )
    .expect("connected");
    assert_eq!(connected.state, RealtimeSessionState::Connected);

    assert!(apply_signal(
        &mut caller_manager,
        realtime_id,
        "peer-b",
        RealtimeSignalKind::WebRtcOffer,
        connected.revision,
        b"invalid-sdp".to_vec(),
    )
    .is_err());
    assert!(caller_manager.sessions.contains_key(realtime_id));
}

#[test]
fn ice_candidates_follow_the_active_generation_and_deduplicate_replays() {
    let realtime_id = "00112233445566778899aabbccddeeff";
    let mut caller = WebRtcPeer::new(WebRtcConfig::default()).expect("caller");
    caller
        .create_data_channel("ssh-mobile-realtime", Default::default())
        .expect("data channel");
    let offer = caller.create_offer().expect("offer");
    let offer_revision = caller.signaling_revision();

    let mut responder_manager = RealtimeManager::default();
    let answer = apply_signal(
        &mut responder_manager,
        realtime_id,
        "peer-a",
        RealtimeSignalKind::WebRtcOffer,
        offer_revision,
        offer.sdp.into_bytes(),
    )
    .expect("answer")
    .outbound
    .expect("answer signal");
    let candidate = b"candidate:1 1 udp 2130706431 192.168.1.100 54321 typ host".to_vec();

    let accepted = apply_signal(
        &mut responder_manager,
        realtime_id,
        "peer-a",
        RealtimeSignalKind::IceCandidate,
        offer_revision,
        candidate.clone(),
    )
    .expect("candidate");
    assert_eq!(accepted.state, RealtimeSessionState::Negotiating);
    assert_eq!(accepted.revision, answer.revision);
    assert!(apply_signal(
        &mut responder_manager,
        realtime_id,
        "peer-a",
        RealtimeSignalKind::IceCandidate,
        offer_revision,
        candidate.clone(),
    )
    .is_err());
    assert!(apply_signal(
        &mut responder_manager,
        realtime_id,
        "peer-a",
        RealtimeSignalKind::IceCandidate,
        answer.revision,
        b"candidate:2 1 udp 2130706431 192.0.2.1 54322 typ host".to_vec(),
    )
    .is_err());
}

#[test]
fn ice_restart_emits_a_new_offer_and_close_rejects_stale_revisions() {
    let realtime_id = "00112233445566778899aabbccddeeff";
    let mut caller = WebRtcPeer::new(WebRtcConfig::default()).expect("caller");
    caller
        .create_data_channel("ssh-mobile-realtime", Default::default())
        .expect("data channel");
    let offer = caller.create_offer().expect("offer");
    let offer_revision = caller.signaling_revision();
    let mut manager = RealtimeManager::default();
    let answer = apply_signal(
        &mut manager,
        realtime_id,
        "peer-a",
        RealtimeSignalKind::WebRtcOffer,
        offer_revision,
        offer.sdp.into_bytes(),
    )
    .expect("answer")
    .outbound
    .expect("answer signal");

    let restart = apply_signal(
        &mut manager,
        realtime_id,
        "peer-a",
        RealtimeSignalKind::IceRestart,
        answer.revision + 1,
        b"restart".to_vec(),
    )
    .expect("restart");
    assert_eq!(restart.state, RealtimeSessionState::Restarting);
    let restart_offer = restart.outbound.expect("restart offer");
    assert_eq!(restart_offer.kind, RealtimeSignalKind::WebRtcOffer);
    assert!(restart_offer.revision > answer.revision);
    assert!(manager.session_generations.contains_key(realtime_id));

    assert!(apply_signal(
        &mut manager,
        realtime_id,
        "peer-a",
        RealtimeSignalKind::WebRtcClose,
        answer.revision,
        b"close".to_vec(),
    )
    .is_err());
    assert!(manager.sessions.contains_key(realtime_id));
    assert!(manager.session_generations.contains_key(realtime_id));
    let closed = apply_signal(
        &mut manager,
        realtime_id,
        "peer-a",
        RealtimeSignalKind::WebRtcClose,
        restart_offer.revision,
        b"close".to_vec(),
    )
    .expect("close");
    assert_eq!(closed.state, RealtimeSessionState::Closed);
    assert!(!manager.sessions.contains_key(realtime_id));
}

#[test]
fn signaling_bounds_reject_oversized_messages_before_peer_mutation() {
    assert!(validate_signal(
        RealtimeSignalKind::WebRtcOffer,
        1,
        &vec![b'x'; MAX_SDP_BYTES + 1],
    )
    .is_err());
    assert!(validate_signal(
        RealtimeSignalKind::IceCandidate,
        1,
        &vec![b'x'; MAX_ICE_CANDIDATE_BYTES + 1],
    )
    .is_err());
}

// -----------------------------------------------------------------------
// §22 / §40 Recovery：ConnectionSession 丢失 → RealtimeSession Closed →
// 重新建立 → 全新 PeerConnection（绝不透明恢复旧 PeerConnection 对象）。
// -----------------------------------------------------------------------

/// 全新 PeerConnection 首个 Offer 的 signaling revision（`WebRtcPeer::create_offer`
/// 把计数器从 0 推进到 1；fresh session 从该起点重启计数，绝不继承旧会话的 revision）。
const FRESH_OFFER_REVISION: u64 = 1;

#[tokio::test]
async fn transport_loss_closes_realtime_session_and_reestablish_uses_a_fresh_peer() {
    let realtime_id = "00112233445566778899aabbccddeeff";
    let s1 = SessionId::from_bytes([1u8; 16]);
    let s2 = SessionId::from_bytes([2u8; 16]);

    // 第一代：responder 从 offer 建立，绑定 ConnectionSession S1，持有 driver1。
    let mut caller = WebRtcPeer::new(WebRtcConfig::default()).expect("caller");
    caller
        .create_data_channel("ssh-mobile-realtime", Default::default())
        .expect("data channel");
    let offer = caller.create_offer().expect("offer");
    let offer_sdp = offer.sdp.clone();
    let offer_revision = caller.signaling_revision();
    let driver1 = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("responder peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("responder driver")
    .into_handle();

    let mut manager = RealtimeManager::default();
    let first = apply_signal_with_driver(
        &mut manager,
        realtime_id,
        "peer-a",
        InboundSignal {
            kind: RealtimeSignalKind::WebRtcOffer,
            revision: offer_revision,
            payload: offer.sdp.into_bytes(),
        },
        Some(driver1.clone()),
        Some(s1),
    )
    .expect("first answer");
    assert_eq!(first.state, RealtimeSessionState::Negotiating);
    assert_eq!(
        manager.sessions[realtime_id].connection_session_id,
        Some(s1)
    );

    // transport 丢失（ConnectionSession S1 销毁）→ RealtimeSession Closed。
    let closed = manager.close_for_connection_session("peer-a", s1);
    assert_eq!(closed.len(), 1);
    assert_eq!(closed[0].0, realtime_id);
    assert_eq!(closed[0].1, "peer-a");
    assert_eq!(closed[0].2, first.revision + 1);
    assert!(!manager.sessions.contains_key(realtime_id));
    // 旧 PeerConnection 对象被销毁，其 DTLS/ICE 状态不可复用。
    assert!(matches!(
        driver1.lock().unwrap().peer_mut().signaling_state(),
        SignalingState::Closed
    ));

    // 第二代：新的 Resolve → Connection S2 → 重新 signaling → 全新 PeerConnection。
    let mut caller2 = WebRtcPeer::new(WebRtcConfig::default()).expect("caller 2");
    caller2
        .create_data_channel("ssh-mobile-realtime", Default::default())
        .expect("data channel");
    let offer2 = caller2.create_offer().expect("offer 2");
    let offer2_sdp = offer2.sdp.clone();
    let offer2_revision = caller2.signaling_revision();
    let driver2 = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("responder peer 2"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("responder driver 2")
    .into_handle();
    let second = apply_signal_with_driver(
        &mut manager,
        realtime_id,
        "peer-a",
        InboundSignal {
            kind: RealtimeSignalKind::WebRtcOffer,
            revision: offer2_revision,
            payload: offer2.sdp.into_bytes(),
        },
        Some(driver2.clone()),
        Some(s2),
    )
    .expect("second answer");
    assert_eq!(second.state, RealtimeSessionState::Negotiating);
    assert_eq!(
        manager.sessions[realtime_id].connection_session_id,
        Some(s2)
    );
    // 新会话是全新 PeerConnection（对象不复用、SDP 是新 DTLS/ICE 状态），
    // 且计数从该会话自己的起点重启。
    assert!(
        !Arc::ptr_eq(&driver1, &driver2),
        "new PeerConnection must be a fresh object, never the old one"
    );
    assert_ne!(
        offer_sdp, offer2_sdp,
        "new offer must carry fresh DTLS/ICE state"
    );
    assert_eq!(manager.sessions[realtime_id].revision, second.revision);
}

#[test]
fn close_for_connection_session_only_affects_bound_realtime_sessions() {
    let realtime_id = "00112233445566778899aabbccddeeff";
    let other_realtime_id = "ffeeddccbbaa99887766554433221100";
    let s1 = SessionId::from_bytes([1u8; 16]);
    let s2 = SessionId::from_bytes([2u8; 16]);
    let mut manager = RealtimeManager::default();
    let insert = |manager: &mut RealtimeManager,
                  id: &str,
                  peer_id: &str,
                  connection_session_id: Option<SessionId>| {
        manager.sessions.insert(
            id.to_string(),
            RealtimeSession {
                peer_id: peer_id.to_string(),
                connection_session_id,
                peer: Some(
                    WebRtcPeer::new(WebRtcConfig::default())
                        .expect("validated default WebRTC configuration"),
                ),
                driver: None,
                revision: 1,
                remote_revision: 0,
                ice_revision: 1,
                seen_candidates: HashSet::new(),
            },
        );
    };
    // 目标：peer-a 绑定 S1 → 应被关闭。
    insert(&mut manager, realtime_id, "peer-a", Some(s1));
    // peer-a 绑定 S2 → 不受影响。
    insert(&mut manager, other_realtime_id, "peer-a", Some(s2));
    // peer-b 绑定 S1 → 不同 peer，不受影响。
    insert(
        &mut manager,
        "01010101010101010101010101010101",
        "peer-b",
        Some(s1),
    );
    // peer-a 未绑定 ConnectionSession → 不受影响。
    insert(
        &mut manager,
        "02020202020202020202020202020202",
        "peer-a",
        None,
    );

    let closed = manager.close_for_connection_session("peer-a", s1);
    assert_eq!(closed.len(), 1);
    assert_eq!(closed[0].0, realtime_id);
    assert!(!manager.sessions.contains_key(realtime_id));
    assert!(manager.sessions.contains_key(other_realtime_id));
    assert!(manager
        .sessions
        .contains_key("01010101010101010101010101010101"));
    assert!(manager
        .sessions
        .contains_key("02020202020202020202020202020202"));
}

/// 记录 v2 控制面 WebRTC 信令的 mock（可配置发送失败模拟信令丢失）。
#[derive(Clone)]
struct SignalCall {
    realtime_id: String,
    target_device_id: String,
    kind: V2RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
}

struct RecordingControl {
    signals: Mutex<Vec<SignalCall>>,
    fail_signals: AtomicBool,
    usable: AtomicBool,
}

impl RecordingControl {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            signals: Mutex::new(Vec::new()),
            fail_signals: AtomicBool::new(false),
            usable: AtomicBool::new(true),
        })
    }

    fn signal_calls(&self) -> Vec<SignalCall> {
        self.signals.lock().unwrap().clone()
    }

    fn set_usable(&self, usable: bool) {
        self.usable.store(usable, Ordering::Release);
    }
}

impl DiscoveryControlPlane for RecordingControl {
    fn publish_discovery(
        &self,
        _request_id: u64,
        _snapshot: DiscoverySnapshot,
    ) -> Pin<Box<dyn Future<Output = Result<DiscoveryAck, RelayError>> + Send + '_>> {
        Box::pin(async move { Err(RelayError::NotConnected) })
    }

    fn resolve_peer(
        &self,
        _target_device_id: &str,
    ) -> Pin<Box<dyn Future<Output = Result<ResolvePeerResponse, RelayError>> + Send + '_>> {
        Box::pin(async move { Err(RelayError::NotConnected) })
    }

    fn is_usable(&self) -> Pin<Box<dyn Future<Output = bool> + Send + '_>> {
        let usable = self.usable.load(Ordering::Acquire);
        Box::pin(async move { usable })
    }

    fn signal_webrtc(
        &self,
        realtime_id: &str,
        target_device_id: &str,
        kind: V2RealtimeSignalKind,
        revision: u64,
        payload: &[u8],
    ) -> Pin<Box<dyn Future<Output = Result<(), RelayError>> + Send + '_>> {
        let fail = self.fail_signals.load(Ordering::Acquire);
        let call = SignalCall {
            realtime_id: realtime_id.to_string(),
            target_device_id: target_device_id.to_string(),
            kind,
            revision,
            payload: payload.to_vec(),
        };
        Box::pin(async move {
            if fail {
                Err(RelayError::NotConnected)
            } else {
                self.signals.lock().unwrap().push(call);
                Ok(())
            }
        })
    }
}

async fn realtime_test_state() -> (
    Arc<RuntimeState>,
    tokio::sync::mpsc::UnboundedReceiver<network_protocol::NetworkEvent>,
) {
    let (event_tx, event_rx) = unbounded_channel();
    (
        Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        )),
        event_rx,
    )
}

#[tokio::test]
async fn inbound_v2_signal_uses_established_realtime_peer_binding_not_target() {
    let (state, _event_rx) = realtime_test_state().await;
    register_realtime_peer(&state, "peer-a").await;

    let realtime_id = "00112233445566778899aabbccddeeff";
    let mut caller = WebRtcPeer::new(WebRtcConfig::default()).expect("caller peer");
    caller
        .create_data_channel("ssh-mobile-realtime", Default::default())
        .expect("data channel");
    let offer = caller.create_offer().expect("offer");
    let offer_revision = caller.signaling_revision();
    let mut responder = WebRtcPeer::new(WebRtcConfig::default()).expect("responder peer");
    responder
        .accept_remote_offer(offer)
        .expect("responder accepts offer");
    let answer = responder.create_answer().expect("answer");

    state.realtime.lock().await.sessions.insert(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: Some(caller),
            driver: None,
            revision: offer_revision,
            remote_revision: 0,
            ice_revision: offer_revision,
            seen_candidates: HashSet::new(),
        },
    );

    let outcome = handle_v2_realtime_signal(
        &state,
        &V2RealtimeSignal {
            request_id: 1,
            realtime_id: realtime_id.into(),
            target_device_id: "local-device-b".into(),
            kind: V2RealtimeSignalKind::Answer as i32,
            revision: offer_revision + 1,
            payload: answer.sdp.into_bytes(),
        },
    )
    .await;
    assert!(outcome.is_ok(), "inbound answer: {outcome:?}");

    assert_eq!(
        state.realtime.lock().await.sessions[realtime_id].peer_id,
        "peer-a",
        "the authenticated sender is the remote WebRTC peer"
    );
}

async fn register_realtime_peer(state: &RuntimeState, peer_id: &str) {
    state.peers.write().await.insert(
        peer_id.to_string(),
        PeerConfig {
            endpoint: None,
            identity_public_key: [7u8; 32],
            e2e_public_key: [8u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
}

#[tokio::test]
async fn signaling_flows_over_v2_control_plane_and_transport_loss_then_reestablishes() {
    let (state, mut event_rx) = realtime_test_state().await;
    let control = RecordingControl::new();
    *state.relay.control.write().await = Some(control.clone());
    register_realtime_peer(&state, "peer-a").await;
    let s1 = match state
        .begin_connect("peer-a", crate::connect::DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let realtime_id = "00112233445566778899aabbccddeeff";

    // 首次建立：Offer 经 v2 控制面发出（signal_webrtc），并绑定 ConnectionSession S1。
    start_session(
        state.clone(),
        StartRealtimeSessionCommand {
            realtime_id: realtime_id.into(),
            peer_id: "peer-a".into(),
        },
    )
    .await
    .expect("first realtime session");
    let first_calls = control.signal_calls();
    assert_eq!(first_calls.len(), 1);
    assert_eq!(first_calls[0].kind, V2RealtimeSignalKind::Offer);
    assert_eq!(first_calls[0].realtime_id, realtime_id);
    assert_eq!(first_calls[0].target_device_id, "peer-a");
    // 全新 PeerConnection 的计数从该会话自己的起点重启（create_offer → revision 1）。
    assert_eq!(first_calls[0].revision, FRESH_OFFER_REVISION);
    let driver1 = state.realtime.lock().await.sessions[realtime_id]
        .driver
        .clone()
        .expect("first driver");

    // transport 丢失：ConnectionSession 销毁 → RealtimeSession Closed（§22）。
    state.cancel_session_tasks("peer-a", s1).await;
    assert!(
        !state
            .realtime
            .lock()
            .await
            .sessions
            .contains_key(realtime_id),
        "transport loss must tear down the realtime session"
    );
    let mut closed_seen = false;
    while let Ok(event) = event_rx.try_recv() {
        if let Some(network_event::Payload::RealtimeState(state_event)) = event.payload {
            if state_event.realtime_id == realtime_id
                && state_event.state == RealtimeSessionState::Closed as i32
            {
                closed_seen = true;
            }
        }
    }
    assert!(
        closed_seen,
        "transport loss must emit RealtimeSessionState::Closed"
    );

    // 新 ConnectionSession（用户重新 Resolve → Connection，§22）。
    let _ = state.close_transport_path("peer-a").await;
    let _ = state.connection_sessions.retire_session("peer-a", s1).await;
    let s2 = match state
        .begin_connect("peer-a", crate::connect::DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    assert_ne!(s1, s2);

    // 重新请求：新 PeerConnection + 信令经新鲜连接重发。
    start_session(
        state.clone(),
        StartRealtimeSessionCommand {
            realtime_id: realtime_id.into(),
            peer_id: "peer-a".into(),
        },
    )
    .await
    .expect("re-established realtime session");
    let driver2 = state.realtime.lock().await.sessions[realtime_id]
        .driver
        .clone()
        .expect("second driver");
    assert!(
        !Arc::ptr_eq(&driver1, &driver2),
        "new PeerConnection must not reuse the old object"
    );

    let all_calls = control.signal_calls();
    assert_eq!(
        all_calls.len(),
        2,
        "re-establishment resends the offer over the fresh connection"
    );
    assert_eq!(all_calls[1].kind, V2RealtimeSignalKind::Offer);
    assert_eq!(
        all_calls[1].revision, FRESH_OFFER_REVISION,
        "new session restarts its counters"
    );
    assert_ne!(
        all_calls[0].payload, all_calls[1].payload,
        "fresh offer carries new DTLS/ICE state"
    );
}

#[tokio::test]
async fn signaling_lost_mid_negotiation_closes_cleanly_and_re_request_succeeds() {
    let (state, _event_rx) = realtime_test_state().await;
    let control = RecordingControl::new();
    control.fail_signals.store(true, Ordering::Release);
    *state.relay.control.write().await = Some(control.clone());
    register_realtime_peer(&state, "peer-a").await;
    let realtime_id = "00112233445566778899aabbccddeeff";

    // 信令在协商中途丢失（控制面发送失败）→ start_session 干净失败并清理会话。
    let error = start_session(
        state.clone(),
        StartRealtimeSessionCommand {
            realtime_id: realtime_id.into(),
            peer_id: "peer-a".into(),
        },
    )
    .await
    .expect_err("signaling loss must fail start_session");
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);
    assert!(
        !state
            .realtime
            .lock()
            .await
            .sessions
            .contains_key(realtime_id),
        "failed session must be torn down"
    );

    // 信令路径恢复后重新请求 → 成功，Offer 经 v2 控制面发出。
    control.fail_signals.store(false, Ordering::Release);
    start_session(
        state.clone(),
        StartRealtimeSessionCommand {
            realtime_id: realtime_id.into(),
            peer_id: "peer-a".into(),
        },
    )
    .await
    .expect("re-request after signaling recovery");
    let calls = control.signal_calls();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].kind, V2RealtimeSignalKind::Offer);
    assert!(state
        .realtime
        .lock()
        .await
        .sessions
        .contains_key(realtime_id));
}

#[tokio::test]
async fn start_realtime_cleans_the_driver_when_supervisor_is_stopping() {
    let (state, _event_rx) = realtime_test_state().await;
    let control = RecordingControl::new();
    *state.relay.control.write().await = Some(control);
    register_realtime_peer(&state, "peer-a").await;
    state.task_supervisor.cancel_root();

    let realtime_id = "00112233445566778899aabbccddeeff";
    let error = start_session(
        Arc::clone(&state),
        StartRealtimeSessionCommand {
            realtime_id: realtime_id.into(),
            peer_id: "peer-a".into(),
        },
    )
    .await
    .expect_err("stopping supervisor must reject the realtime worker");
    assert_eq!(error.code, NetworkErrorCode::Cancelled as i32);
    assert!(!state
        .realtime
        .lock()
        .await
        .sessions
        .contains_key(realtime_id));
}

#[tokio::test]
async fn duplicate_start_realtime_rejects_without_retaining_a_bound_driver() {
    let (state, _event_rx) = realtime_test_state().await;
    let control = RecordingControl::new();
    *state.relay.control.write().await = Some(control.clone());
    register_realtime_peer(&state, "peer-a").await;
    let realtime_id = "00112233445566778899aabbccddeeff";

    start_session(
        state.clone(),
        StartRealtimeSessionCommand {
            realtime_id: realtime_id.into(),
            peer_id: "peer-a".into(),
        },
    )
    .await
    .expect("first start");
    let first_driver = {
        let sessions = state.realtime.lock().await;
        assert_eq!(
            sessions.sessions.len(),
            1,
            "exactly one session after the first start"
        );
        sessions.sessions[realtime_id]
            .driver
            .clone()
            .expect("first driver")
    };
    // 基线：会话表 + 已 spawn 的 realtime-io 任务 + 本测试克隆各持有一份。
    let baseline_refs = Arc::strong_count(&first_driver);
    assert_eq!(
        baseline_refs, 3,
        "expected session map, io task and test clone to hold the driver"
    );

    // 同一 realtime_id 重复启动：必须在绑定任何 socket 之前拒绝，不得让
    // 第二次调用创建并丢弃一个已绑定的驱动（泄漏）。
    let error = start_session(
        state.clone(),
        StartRealtimeSessionCommand {
            realtime_id: realtime_id.into(),
            peer_id: "peer-a".into(),
        },
    )
    .await
    .expect_err("duplicate start must be rejected");
    assert_eq!(error.code, NetworkErrorCode::InvalidArgument as i32);

    // 没有泄漏：会话表未被覆盖或新增；原驱动的 Arc 未变，且引用计数与
    // 基线一致——重复调用没有额外保留任何已绑定驱动。
    let sessions = state.realtime.lock().await;
    assert_eq!(
        sessions.sessions.len(),
        1,
        "duplicate start must not add a session"
    );
    let still_driver = sessions.sessions[realtime_id]
        .driver
        .as_ref()
        .expect("driver");
    assert!(
        Arc::ptr_eq(&first_driver, still_driver),
        "duplicate start must not overwrite the existing session"
    );
    assert_eq!(
        Arc::strong_count(&first_driver),
        baseline_refs,
        "no extra bound driver handle may be retained by the rejected start"
    );
}

#[tokio::test]
async fn healthy_realtime_survives_environment_reprobe() {
    let (state, _event_rx) = realtime_test_state().await;
    register_realtime_peer(&state, "peer-a").await;
    crate::discovery::begin_epoch(&state).await;
    let control = RecordingControl::new();
    *state.relay.control.write().await = Some(control);
    let realtime_id = "00112233445566778899aabbccddeeff";
    let peer = WebRtcPeer::new(WebRtcConfig::default()).expect("realtime peer");

    state.realtime.lock().await.sessions.insert(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: Some(peer),
            driver: None,
            revision: 1,
            remote_revision: 0,
            ice_revision: 1,
            seen_candidates: HashSet::new(),
        },
    );

    crate::discovery::on_network_environment_changed(&state, 7, true)
        .await
        .expect("environment reprobe");
    assert!(preserve_for_environment_reprobe(&state, "peer-a").await);
    assert!(
        state
            .realtime
            .lock()
            .await
            .sessions
            .contains_key(realtime_id),
        "discovery reprobe must not remove the healthy Realtime owner"
    );
}

#[test]
fn realtime_wire_validation_covers_identity_revision_and_payload_bounds() {
    assert!(validate_realtime_id("00112233445566778899aabbccddeeff").is_ok());
    for invalid in [
        "",
        "00112233445566778899aabbccddeef",   // 31 chars
        "00112233445566778899aabbccddeeff0", // 33 chars
        "00112233445566778899aabbccddeefg",  // non-hex
        "00112233445566778899AABBCCDDEEFF",  // uppercase
    ] {
        assert!(validate_realtime_id(invalid).is_err(), "{invalid:?}");
    }

    assert!(validate_signal(RealtimeSignalKind::WebRtcOffer, 1, b"offer").is_ok());
    assert!(validate_signal(RealtimeSignalKind::WebRtcClose, 1, &[]).is_ok());
    assert!(validate_signal(RealtimeSignalKind::IceRestart, 1, &[]).is_ok());
    assert!(validate_signal(RealtimeSignalKind::WebRtcOffer, 0, b"offer").is_err());
    assert!(validate_signal(
        RealtimeSignalKind::WebRtcOffer,
        1,
        &vec![0; MAX_SDP_BYTES + 1]
    )
    .is_err());
    assert!(validate_signal(
        RealtimeSignalKind::IceCandidate,
        1,
        &vec![0; MAX_ICE_CANDIDATE_BYTES + 1]
    )
    .is_err());
    assert!(validate_signal(RealtimeSignalKind::WebRtcAnswer, 1, &[]).is_err());
}

#[test]
fn realtime_signal_kind_mapping_and_owner_errors_are_explicit() {
    for (native, v2) in [
        (
            RealtimeSignalKind::Unspecified,
            V2RealtimeSignalKind::Unspecified,
        ),
        (RealtimeSignalKind::WebRtcOffer, V2RealtimeSignalKind::Offer),
        (
            RealtimeSignalKind::WebRtcAnswer,
            V2RealtimeSignalKind::Answer,
        ),
        (
            RealtimeSignalKind::IceCandidate,
            V2RealtimeSignalKind::IceCandidate,
        ),
        (
            RealtimeSignalKind::IceRestart,
            V2RealtimeSignalKind::IceRestart,
        ),
        (RealtimeSignalKind::WebRtcClose, V2RealtimeSignalKind::Close),
    ] {
        assert_eq!(to_v2_signal_kind(native), v2 as i32);
    }
    assert_eq!(
        to_v2_signal_kind(RealtimeSignalKind::ScreenShareConsent),
        6,
        "Network V2 consent uses a forward-compatible Relay wire kind"
    );

    let mut empty = RealtimeSession {
        peer_id: "peer-a".into(),
        connection_session_id: None,
        peer: None,
        driver: None,
        revision: 1,
        remote_revision: 0,
        ice_revision: 1,
        seen_candidates: HashSet::new(),
    };
    let error = with_session_peer(&mut empty, WebRtcPeer::close).expect_err("missing peer owner");
    assert!(error.to_string().contains("no WebRTC peer owner"));
}

#[tokio::test]
async fn realtime_peer_and_session_helpers_fail_closed_and_remove_exact_owner() {
    let (state, _event_rx) = realtime_test_state().await;
    assert!(validate_peer(&state, "missing").await.is_err());
    state.peers.write().await.insert(
        "peer-a".into(),
        PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    assert!(validate_peer(&state, "peer-a").await.is_ok());
    assert!(validate_peer(&state, &"x".repeat(129)).await.is_err());

    let realtime_id = "00112233445566778899aabbccddeeff";
    state.realtime.lock().await.sessions.insert(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: Some(WebRtcPeer::new(WebRtcConfig::default()).unwrap()),
            driver: None,
            revision: 4,
            remote_revision: 2,
            ice_revision: 3,
            seen_candidates: HashSet::new(),
        },
    );
    assert_eq!(session_revision(&state, realtime_id).await, 4);
    assert_eq!(session_revision(&state, "missing").await, 0);
    assert!(preserve_for_environment_reprobe(&state, "peer-a").await);
    assert!(!preserve_for_environment_reprobe(&state, "peer-b").await);

    remove_realtime_session(&state, realtime_id, "peer-b").await;
    assert!(state
        .realtime
        .lock()
        .await
        .sessions
        .contains_key(realtime_id));
    remove_realtime_session(&state, realtime_id, "peer-a").await;
    assert!(!state
        .realtime
        .lock()
        .await
        .sessions
        .contains_key(realtime_id));
}

#[tokio::test]
async fn stale_realtime_cleanup_does_not_remove_a_replacement_driver() {
    let (state, _event_rx) = realtime_test_state().await;
    let realtime_id = "00112233445566778899aabbccddeeff";
    let old_driver = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("old driver peer"),
        "127.0.0.1:0".parse().expect("old driver bind address"),
    )
    .await
    .expect("old driver")
    .into_handle();
    let replacement_driver = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("replacement peer"),
        "127.0.0.1:0"
            .parse()
            .expect("replacement driver bind address"),
    )
    .await
    .expect("replacement driver")
    .into_handle();
    state.realtime.lock().await.sessions.insert(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: None,
            driver: Some(Arc::clone(&replacement_driver)),
            revision: 1,
            remote_revision: 0,
            ice_revision: 1,
            seen_candidates: HashSet::new(),
        },
    );

    remove_realtime_session_if_owned(&state, realtime_id, "peer-a", &old_driver).await;

    let sessions = state.realtime.lock().await;
    let session = sessions
        .sessions
        .get(realtime_id)
        .expect("replacement session remains registered");
    assert!(session
        .driver
        .as_ref()
        .is_some_and(|driver| Arc::ptr_eq(driver, &replacement_driver)));
}

#[tokio::test]
async fn realtime_manager_close_all_and_connection_close_are_owner_scoped() {
    let mut manager = RealtimeManager::default();
    let s1 = SessionId::from_bytes([1; 16]);
    let s2 = SessionId::from_bytes([2; 16]);
    for (id, peer, session) in [
        ("00112233445566778899aabbccddeeff", "peer-a", Some(s1)),
        ("11112233445566778899aabbccddeeff", "peer-a", Some(s2)),
        ("22112233445566778899aabbccddeeff", "peer-b", Some(s1)),
    ] {
        manager.sessions.insert(
            id.into(),
            RealtimeSession {
                peer_id: peer.into(),
                connection_session_id: session,
                peer: Some(WebRtcPeer::new(WebRtcConfig::default()).unwrap()),
                driver: None,
                revision: 1,
                remote_revision: 0,
                ice_revision: 1,
                seen_candidates: HashSet::new(),
            },
        );
    }
    let closed = manager.close_for_connection_session("peer-a", s1);
    assert_eq!(
        closed,
        vec![(
            "00112233445566778899aabbccddeeff".into(),
            "peer-a".into(),
            2,
            0,
        )]
    );
    assert_eq!(manager.sessions.len(), 2);
    manager.close_all();
    assert!(manager.sessions.is_empty());
}

#[tokio::test]
async fn realtime_signal_route_reports_missing_control_plane() {
    let (state, _event_rx) = realtime_test_state().await;
    let signal = OutboundSignal {
        realtime_id: "00112233445566778899aabbccddeeff".into(),
        peer_id: "peer-a".into(),
        kind: RealtimeSignalKind::WebRtcOffer,
        revision: 1,
        payload: b"offer".to_vec(),
    };
    let error = send_signal(&state, &signal)
        .await
        .expect_err("missing Relay control plane must reject signaling");
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);
}

#[tokio::test]
async fn realtime_command_boundaries_reject_invalid_identity_peer_and_revision() {
    let (state, _event_rx) = realtime_test_state().await;
    let valid_id = "00112233445566778899aabbccddeeff";
    assert!(
        start_session(Arc::clone(&state), StartRealtimeSessionCommand::default(),)
            .await
            .is_err()
    );
    assert!(stop_session(&state, StopRealtimeSessionCommand::default(),)
        .await
        .is_err());
    let missing_stop = stop_session(
        &state,
        StopRealtimeSessionCommand {
            realtime_id: valid_id.into(),
        },
    )
    .await
    .expect_err("a valid but unknown realtime id must be rejected");
    assert_eq!(missing_stop.code, NetworkErrorCode::InvalidArgument as i32);
    assert!(send_signal_command(
        &state,
        SendRealtimeSignalCommand {
            realtime_id: valid_id.into(),
            peer_id: "missing-peer".into(),
            kind: RealtimeSignalKind::WebRtcOffer as i32,
            revision: 1,
            payload: b"offer".to_vec(),
        },
    )
    .await
    .is_err());

    register_realtime_peer(&state, "peer-a").await;
    for command in [
        SendRealtimeSignalCommand {
            realtime_id: valid_id.into(),
            peer_id: "peer-a".into(),
            kind: 99,
            revision: 1,
            payload: b"offer".to_vec(),
        },
        SendRealtimeSignalCommand {
            realtime_id: valid_id.into(),
            peer_id: "peer-a".into(),
            kind: RealtimeSignalKind::WebRtcOffer as i32,
            revision: 0,
            payload: b"offer".to_vec(),
        },
        SendRealtimeSignalCommand {
            realtime_id: valid_id.into(),
            peer_id: "peer-a".into(),
            kind: RealtimeSignalKind::WebRtcOffer as i32,
            revision: 1,
            payload: Vec::new(),
        },
        SendRealtimeSignalCommand {
            realtime_id: "missing-session".into(),
            peer_id: "peer-a".into(),
            kind: RealtimeSignalKind::WebRtcClose as i32,
            revision: 1,
            payload: Vec::new(),
        },
    ] {
        assert!(send_signal_command(&state, command).await.is_err());
    }

    state.realtime.lock().await.sessions.insert(
        valid_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: None,
            driver: None,
            revision: 3,
            remote_revision: 2,
            ice_revision: 2,
            seen_candidates: HashSet::new(),
        },
    );
    for command in [
        SendRealtimeSignalCommand {
            realtime_id: valid_id.into(),
            peer_id: "other-peer".into(),
            kind: RealtimeSignalKind::WebRtcOffer as i32,
            revision: 4,
            payload: b"offer".to_vec(),
        },
        SendRealtimeSignalCommand {
            realtime_id: valid_id.into(),
            peer_id: "peer-a".into(),
            kind: RealtimeSignalKind::WebRtcOffer as i32,
            revision: 3,
            payload: b"offer".to_vec(),
        },
        SendRealtimeSignalCommand {
            realtime_id: valid_id.into(),
            peer_id: "peer-a".into(),
            kind: RealtimeSignalKind::IceCandidate as i32,
            revision: 1,
            payload: b"candidate".to_vec(),
        },
    ] {
        assert!(send_signal_command(&state, command).await.is_err());
    }
    let missing_control = send_signal_command(
        &state,
        SendRealtimeSignalCommand {
            realtime_id: valid_id.into(),
            peer_id: "peer-a".into(),
            kind: RealtimeSignalKind::WebRtcOffer as i32,
            revision: 4,
            payload: b"offer".to_vec(),
        },
    )
    .await
    .expect_err("valid signal must still require the Relay control route");
    assert_eq!(missing_control.code, NetworkErrorCode::RelayError as i32);

    let unknown_v2 = handle_v2_realtime_signal(
        &state,
        &V2RealtimeSignal {
            realtime_id: "unknown".into(),
            kind: V2RealtimeSignalKind::Offer as i32,
            revision: 1,
            payload: b"offer".to_vec(),
            ..Default::default()
        },
    )
    .await;
    assert!(unknown_v2.is_err());
    let invalid_v2 = handle_v2_realtime_signal(
        &state,
        &V2RealtimeSignal {
            realtime_id: valid_id.into(),
            kind: 99,
            revision: 4,
            payload: b"offer".to_vec(),
            ..Default::default()
        },
    )
    .await;
    assert!(invalid_v2.is_err());
}

#[tokio::test]
async fn start_realtime_cancellation_closes_driver_when_supervisor_is_stopping() {
    let (state, _event_rx) = realtime_test_state().await;
    let control = RecordingControl::new();
    *state.relay.control.write().await = Some(control);
    register_realtime_peer(&state, "peer-a").await;
    state.task_supervisor.cancel_root();

    let realtime_id = "00112233445566778899aabbccddeeff";
    let error = start_session(
        Arc::clone(&state),
        StartRealtimeSessionCommand {
            realtime_id: realtime_id.into(),
            peer_id: "peer-a".into(),
        },
    )
    .await
    .expect_err("a stopping supervisor must reject realtime startup");
    assert_eq!(error.code, NetworkErrorCode::Cancelled as i32);
    assert!(!state
        .realtime
        .lock()
        .await
        .sessions
        .contains_key(realtime_id));
}

#[tokio::test]
async fn stop_realtime_ignores_close_signal_loss_after_removing_owner() {
    let (state, _event_rx) = realtime_test_state().await;
    let realtime_id = "00112233445566778899aabbccddeeff";
    state.realtime.lock().await.sessions.insert(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: None,
            driver: None,
            revision: 4,
            remote_revision: 1,
            ice_revision: 4,
            seen_candidates: HashSet::new(),
        },
    );
    stop_session(
        &state,
        StopRealtimeSessionCommand {
            realtime_id: realtime_id.into(),
        },
    )
    .await
    .expect("local realtime owner must close even if Relay signaling is gone");
    assert!(state.realtime.lock().await.sessions.is_empty());
}

#[tokio::test]
async fn v2_signal_rejects_an_empty_established_peer_binding() {
    let (state, _event_rx) = realtime_test_state().await;
    let realtime_id = "00112233445566778899aabbccddeeff";
    state.realtime.lock().await.sessions.insert(
        realtime_id.into(),
        RealtimeSession {
            peer_id: String::new(),
            connection_session_id: None,
            peer: None,
            driver: None,
            revision: 1,
            remote_revision: 0,
            ice_revision: 1,
            seen_candidates: HashSet::new(),
        },
    );

    let error = handle_v2_realtime_signal(
        &state,
        &V2RealtimeSignal {
            realtime_id: realtime_id.into(),
            kind: V2RealtimeSignalKind::Close as i32,
            revision: 1,
            payload: Vec::new(),
            ..Default::default()
        },
    )
    .await
    .expect_err("a signal must not use an empty established peer binding");
    assert!(error.to_string().contains("empty established peer"));
}

#[tokio::test]
async fn realtime_turn_configuration_is_parsed_and_invalid_driver_setup_fails_closed() {
    let config = runtime_webrtc_config_from_values(
        Some(" turn:a.example, ,turn:b.example ".into()),
        Some("turn-user".into()),
        Some("turn-credential".into()),
        Some("yes".into()),
    );
    assert_eq!(config.ice_servers.len(), 2);
    assert_eq!(config.ice_servers[0].urls, vec!["turn:a.example"]);
    assert!(config.relay_only);

    let (state, _event_rx) = realtime_test_state().await;
    register_realtime_peer(&state, "peer-a").await;
    let invalid_config = runtime_webrtc_config_from_values(
        Some("x".repeat(2049)),
        Some("turn-user".into()),
        Some("turn-credential".into()),
        Some("yes".into()),
    );
    let error = start_session_with_config(
        Arc::clone(&state),
        StartRealtimeSessionCommand {
            realtime_id: "00112233445566778899aabbccddeeff".into(),
            peer_id: "peer-a".into(),
        },
        invalid_config,
    )
    .await
    .expect_err("an invalid TURN URL must fail before creating a driver");
    assert_eq!(error.code, NetworkErrorCode::IoError as i32);
}

#[tokio::test]
async fn local_ice_candidate_without_a_realtime_owner_is_dropped() {
    let (state, mut event_rx) = realtime_test_state().await;
    forward_local_candidate(
        &state,
        "00112233445566778899aabbccddeeff",
        "peer-a",
        network_webrtc::IceCandidate::new(
            "candidate:1 1 UDP 1 127.0.0.1 9 typ host".into(),
            None,
            None,
            None,
        )
        .expect("valid candidate"),
    )
    .await;
    assert!(event_rx.try_recv().is_err());
}

#[test]
fn apply_signal_rejects_unknown_peer_and_restores_failed_offer_state() {
    let realtime_id = "00112233445566778899aabbccddeeff";
    let mut manager = RealtimeManager::default();
    let missing = match apply_signal_with_driver(
        &mut manager,
        realtime_id,
        "peer-a",
        InboundSignal {
            kind: RealtimeSignalKind::WebRtcAnswer,
            revision: 1,
            payload: b"answer".to_vec(),
        },
        None,
        None,
    ) {
        Ok(_) => panic!("an answer for an unknown realtime session unexpectedly succeeded"),
        Err(error) => error,
    };
    assert!(missing.to_string().contains("does not exist"));

    let invalid_offer = match apply_signal_with_driver(
        &mut manager,
        realtime_id,
        "peer-a",
        InboundSignal {
            kind: RealtimeSignalKind::WebRtcOffer,
            revision: 1,
            payload: b"not-an-sdp".to_vec(),
        },
        None,
        None,
    ) {
        Ok(_) => panic!("a malformed offer unexpectedly succeeded"),
        Err(error) => error,
    };
    assert!(!invalid_offer.to_string().is_empty());
    assert!(!manager.sessions.contains_key(realtime_id));

    manager.sessions.insert(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: Some(WebRtcPeer::new(WebRtcConfig::default()).expect("peer")),
            driver: None,
            revision: 1,
            remote_revision: 0,
            ice_revision: 1,
            seen_candidates: HashSet::new(),
        },
    );
    let mismatch = match apply_signal_with_driver(
        &mut manager,
        realtime_id,
        "peer-b",
        InboundSignal {
            kind: RealtimeSignalKind::WebRtcAnswer,
            revision: 2,
            payload: b"not-an-answer".to_vec(),
        },
        None,
        None,
    ) {
        Ok(_) => panic!("a mismatched peer signal unexpectedly succeeded"),
        Err(error) => error,
    };
    assert!(mismatch.to_string().contains("peer does not match"));
    assert_eq!(manager.sessions[realtime_id].peer_id, "peer-a");
}

#[tokio::test]
async fn send_realtime_signal_routes_valid_revision_and_emits_event() {
    let (state, mut event_rx) = realtime_test_state().await;
    let control = RecordingControl::new();
    *state.relay.control.write().await = Some(control.clone());
    register_realtime_peer(&state, "peer-a").await;
    let realtime_id = "00112233445566778899aabbccddeeff";
    state.realtime.lock().await.sessions.insert(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: None,
            driver: None,
            revision: 3,
            remote_revision: 2,
            ice_revision: 3,
            seen_candidates: HashSet::new(),
        },
    );

    send_signal_command(
        &state,
        SendRealtimeSignalCommand {
            realtime_id: realtime_id.into(),
            peer_id: "peer-a".into(),
            kind: RealtimeSignalKind::WebRtcOffer as i32,
            revision: 4,
            payload: b"offer".to_vec(),
        },
    )
    .await
    .expect("valid signaling command");

    let calls = control.signal_calls();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].realtime_id, realtime_id);
    assert_eq!(calls[0].target_device_id, "peer-a");
    assert_eq!(calls[0].kind, V2RealtimeSignalKind::Offer);
    assert_eq!(calls[0].revision, 4);
    assert_eq!(calls[0].payload, b"offer");

    let event = event_rx.try_recv().expect("signal event");
    let Some(network_event::Payload::RealtimeSignal(event)) = event.payload else {
        panic!("expected realtime signal event");
    };
    assert_eq!(event.realtime_id, realtime_id);
    assert_eq!(event.peer_id, "peer-a");
    assert_eq!(event.kind, RealtimeSignalKind::WebRtcOffer as i32);
    assert_eq!(event.revision, 4);
    assert_eq!(event.payload, b"offer");
}

#[tokio::test]
async fn stop_realtime_session_closes_session_routes_close_and_emits_event() {
    let (state, mut event_rx) = realtime_test_state().await;
    let control = RecordingControl::new();
    *state.relay.control.write().await = Some(control.clone());
    let realtime_id = "00112233445566778899aabbccddeeff";
    let driver = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("driver peer"),
        "127.0.0.1:0".parse().expect("driver bind address"),
    )
    .await
    .expect("driver")
    .into_handle();
    state.realtime.lock().await.insert_new_session(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: None,
            driver: Some(Arc::clone(&driver)),
            revision: 7,
            remote_revision: 5,
            ice_revision: 7,
            seen_candidates: HashSet::new(),
        },
    );
    let generation = state
        .realtime
        .lock()
        .await
        .session_generation(realtime_id)
        .expect("session generation");
    let endpoint = crate::realtime_media::create_endpoint(
        &state,
        realtime_id,
        "peer-a",
        crate::realtime_media::RealtimeMediaDirection::Send,
        generation,
    )
    .await
    .expect("media endpoint");

    stop_session(
        &state,
        StopRealtimeSessionCommand {
            realtime_id: realtime_id.into(),
        },
    )
    .await
    .expect("existing realtime session stops");

    assert!(state.realtime.lock().await.sessions.is_empty());
    assert!(matches!(
        crate::realtime_media::push_endpoint(
            &state,
            endpoint,
            EncodedVideoFrame::new(
                VideoCodec::H264,
                1,
                90_000,
                1280,
                720,
                true,
                vec![0, 0, 0, 1, 0x65],
                Instant::now() + Duration::from_secs(1),
            ),
        ),
        Err(crate::realtime_media::RealtimeMediaError::StaleEndpoint)
    ));
    let calls = control.signal_calls();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].kind, V2RealtimeSignalKind::Close);
    assert_eq!(calls[0].revision, 8);
    assert_eq!(calls[0].payload, b"close");

    let event = event_rx.try_recv().expect("closed state event");
    let Some(network_event::Payload::RealtimeState(event)) = event.payload else {
        panic!("expected realtime state event");
    };
    assert_eq!(event.realtime_id, realtime_id);
    assert_eq!(event.peer_id, "peer-a");
    assert_eq!(event.state, RealtimeSessionState::Closed as i32);
    assert_eq!(event.revision, 8);
}

#[tokio::test]
async fn realtime_signal_route_rejects_disconnected_control_and_forwards_local_candidate() {
    let (state, mut event_rx) = realtime_test_state().await;
    let control = RecordingControl::new();
    *state.relay.control.write().await = Some(control.clone());
    let realtime_id = "00112233445566778899aabbccddeeff";
    state.realtime.lock().await.sessions.insert(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: None,
            driver: None,
            revision: 3,
            remote_revision: 2,
            ice_revision: 3,
            seen_candidates: HashSet::new(),
        },
    );

    control.set_usable(false);
    let error = send_signal(
        &state,
        &OutboundSignal {
            realtime_id: realtime_id.into(),
            peer_id: "peer-a".into(),
            kind: RealtimeSignalKind::WebRtcOffer,
            revision: 4,
            payload: b"offer".to_vec(),
        },
    )
    .await
    .expect_err("a disconnected Relay control route must fail closed");
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);

    control.set_usable(true);
    forward_local_candidate(
        &state,
        realtime_id,
        "peer-a",
        network_webrtc::IceCandidate::new(
            "candidate:1 1 UDP 1 127.0.0.1 9 typ host".into(),
            None,
            None,
            None,
        )
        .expect("valid candidate"),
    )
    .await;
    assert_eq!(control.signal_calls().len(), 1);
    let event = event_rx.try_recv().expect("forwarded ICE event");
    let Some(network_event::Payload::RealtimeSignal(signal)) = event.payload else {
        panic!("expected realtime signal event");
    };
    assert_eq!(signal.kind, RealtimeSignalKind::IceCandidate as i32);
    assert_eq!(signal.revision, 3);
}

#[test]
fn realtime_validation_and_wire_kind_mapping_cover_all_signal_boundaries() {
    for invalid_id in [
        "",
        "00112233445566778899aabbccddeef",
        "00112233445566778899aabbccddeeff0",
        "00112233445566778899AABBCCDDEEFF",
        "zz112233445566778899aabbccddeeff",
    ] {
        assert!(validate_realtime_id(invalid_id).is_err(), "{invalid_id:?}");
    }
    validate_realtime_id("00112233445566778899aabbccddeeff").expect("valid realtime id");

    assert!(validate_signal(RealtimeSignalKind::WebRtcOffer, 1, b"offer").is_ok());
    assert!(validate_signal(RealtimeSignalKind::WebRtcClose, 1, &[]).is_ok());
    assert!(validate_signal(RealtimeSignalKind::IceRestart, 1, &[]).is_ok());
    assert!(validate_signal(RealtimeSignalKind::WebRtcOffer, 1, &[]).is_err());
    assert!(validate_signal(RealtimeSignalKind::IceCandidate, 1, b"candidate").is_ok());

    for (kind, expected) in [
        (
            RealtimeSignalKind::Unspecified,
            V2RealtimeSignalKind::Unspecified,
        ),
        (RealtimeSignalKind::WebRtcOffer, V2RealtimeSignalKind::Offer),
        (
            RealtimeSignalKind::WebRtcAnswer,
            V2RealtimeSignalKind::Answer,
        ),
        (
            RealtimeSignalKind::IceCandidate,
            V2RealtimeSignalKind::IceCandidate,
        ),
        (
            RealtimeSignalKind::IceRestart,
            V2RealtimeSignalKind::IceRestart,
        ),
        (RealtimeSignalKind::WebRtcClose, V2RealtimeSignalKind::Close),
    ] {
        assert_eq!(to_v2_signal_kind(kind), expected as i32);
    }
}

#[test]
fn realtime_session_without_peer_owner_fails_closed() {
    let mut session = RealtimeSession {
        peer_id: "peer-a".into(),
        connection_session_id: None,
        peer: None,
        driver: None,
        revision: 0,
        remote_revision: 0,
        ice_revision: 0,
        seen_candidates: HashSet::new(),
    };
    let error = with_session_peer(&mut session, WebRtcPeer::close)
        .expect_err("session without a peer owner must be rejected");
    assert!(error.to_string().contains("no WebRTC peer owner"));
}

#[test]
fn realtime_close_and_unsupported_signal_boundaries_fail_closed() {
    let realtime_id = "00112233445566778899aabbccddeeff";
    let mut manager = RealtimeManager::default();
    let unknown_close = match apply_signal_with_driver(
        &mut manager,
        realtime_id,
        "peer-a",
        InboundSignal {
            kind: RealtimeSignalKind::WebRtcClose,
            revision: 1,
            payload: Vec::new(),
        },
        None,
        None,
    ) {
        Ok(_) => panic!("close for an unknown realtime session succeeded"),
        Err(error) => error,
    };
    assert!(unknown_close.to_string().contains("does not exist"));

    manager.sessions.insert(
        realtime_id.into(),
        RealtimeSession {
            peer_id: "peer-a".into(),
            connection_session_id: None,
            peer: Some(WebRtcPeer::new(WebRtcConfig::default()).expect("peer")),
            driver: None,
            revision: 3,
            remote_revision: 2,
            ice_revision: 3,
            seen_candidates: HashSet::new(),
        },
    );
    let mismatch = match apply_signal_with_driver(
        &mut manager,
        realtime_id,
        "peer-b",
        InboundSignal {
            kind: RealtimeSignalKind::WebRtcClose,
            revision: 4,
            payload: Vec::new(),
        },
        None,
        None,
    ) {
        Ok(_) => panic!("close from a different peer succeeded"),
        Err(error) => error,
    };
    assert!(mismatch.to_string().contains("peer does not match"));
    let stale = match apply_signal_with_driver(
        &mut manager,
        realtime_id,
        "peer-a",
        InboundSignal {
            kind: RealtimeSignalKind::WebRtcClose,
            revision: 2,
            payload: Vec::new(),
        },
        None,
        None,
    ) {
        Ok(_) => panic!("stale close revision succeeded"),
        Err(error) => error,
    };
    assert!(stale.to_string().contains("stale"));

    let unsupported = match apply_signal_with_driver(
        &mut manager,
        realtime_id,
        "peer-a",
        InboundSignal {
            kind: RealtimeSignalKind::Unspecified,
            revision: 4,
            payload: Vec::new(),
        },
        None,
        None,
    ) {
        Ok(_) => panic!("unspecified signal kind succeeded"),
        Err(error) => error,
    };
    assert!(unsupported.to_string().contains("unsupported"));
}

#[test]
fn realtime_protocol_error_boxing_preserves_the_wire_message() {
    let error = realtime_error(
        NetworkErrorCode::InvalidArgument,
        "invalid realtime payload",
        "test_realtime",
        "peer-a",
    );
    let boxed = boxed_protocol_error(error);
    assert_eq!(boxed.to_string(), "invalid realtime payload");

    let boxed_message = boxed_message("standalone realtime error");
    assert_eq!(boxed_message.to_string(), "standalone realtime error");
}
