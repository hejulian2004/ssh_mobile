use super::*;
use crate::{
    DataChannelReliability, EncodedVideoFrame, IceServerConfig, KeyframeRequestReason,
    MediaDirection, VideoCodec, WebRtcConfig,
};
use rtc::peer_connection::event::{
    RTCDataChannelEvent, RTCPeerConnectionEvent, RTCPeerConnectionIceEvent,
};
use rtc::peer_connection::state::{RTCIceConnectionState, RTCPeerConnectionState};
use rtc::peer_connection::transport::{RTCIceCandidate, RTCIceCandidateType, RTCIceProtocol};
use std::time::Duration;
use tokio::sync::mpsc::channel;

fn host_rtc_candidate(address: impl Into<String>) -> RTCIceCandidate {
    RTCIceCandidate {
        id: "host".to_owned(),
        foundation: "1".to_owned(),
        priority: 2_130_706_431,
        address: address.into(),
        protocol: RTCIceProtocol::Udp,
        port: 45_000,
        typ: RTCIceCandidateType::Host,
        component: 1,
        ..Default::default()
    }
}

fn synthetic_h264_access_unit(sequence: u64, timestamp: u64) -> EncodedVideoFrame {
    let mut payload = vec![
        0, 0, 0, 1, 0x67, 0x42, 0, 0x1f, 0xe5, 0x88, 0x68, 0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80, 0,
        0, 0, 1, 0x65,
    ];
    payload.extend((0..2_048).map(|index| (index as u8).wrapping_mul(17)));
    EncodedVideoFrame::new(
        VideoCodec::H264,
        sequence,
        timestamp,
        1_920,
        1_080,
        true,
        payload,
        std::time::Instant::now() + Duration::from_secs(5),
    )
}

#[test]
fn peer_events_map_to_runtime_events_and_ignore_unowned_variants() {
    let candidate = map_peer_event(RTCPeerConnectionEvent::OnIceCandidateEvent(
        RTCPeerConnectionIceEvent {
            candidate: host_rtc_candidate("192.0.2.10"),
            url: String::new(),
        },
    ))
    .expect("host candidate maps");
    assert!(matches!(
        candidate.as_slice(),
        [RealtimeIoEvent::LocalIceCandidate(IceCandidate { candidate, .. })]
            if candidate.starts_with("candidate:")
    ));

    let invalid = map_peer_event(RTCPeerConnectionEvent::OnIceCandidateEvent(
        RTCPeerConnectionIceEvent {
            candidate: RTCIceCandidate {
                typ: RTCIceCandidateType::Unspecified,
                ..Default::default()
            },
            url: String::new(),
        },
    ));
    assert!(matches!(invalid, Err(WebRtcError::Rtc(_))));

    let cases = [
        (
            RTCPeerConnectionEvent::OnIceConnectionStateChangeEvent(
                RTCIceConnectionState::Connected,
            ),
            RealtimeIoEvent::IceConnected,
        ),
        (
            RTCPeerConnectionEvent::OnIceConnectionStateChangeEvent(
                RTCIceConnectionState::Completed,
            ),
            RealtimeIoEvent::IceConnected,
        ),
        (
            RTCPeerConnectionEvent::OnIceConnectionStateChangeEvent(RTCIceConnectionState::Failed),
            RealtimeIoEvent::IceFailed,
        ),
        (
            RTCPeerConnectionEvent::OnConnectionStateChangeEvent(RTCPeerConnectionState::Connected),
            RealtimeIoEvent::PeerConnected,
        ),
        (
            RTCPeerConnectionEvent::OnConnectionStateChangeEvent(
                RTCPeerConnectionState::Disconnected,
            ),
            RealtimeIoEvent::PeerDisconnected,
        ),
        (
            RTCPeerConnectionEvent::OnConnectionStateChangeEvent(RTCPeerConnectionState::Closed),
            RealtimeIoEvent::PeerDisconnected,
        ),
        (
            RTCPeerConnectionEvent::OnConnectionStateChangeEvent(RTCPeerConnectionState::Failed),
            RealtimeIoEvent::PeerFailed,
        ),
        (
            RTCPeerConnectionEvent::OnDataChannel(RTCDataChannelEvent::OnOpen(7)),
            RealtimeIoEvent::DataChannelOpened(7),
        ),
        (
            RTCPeerConnectionEvent::OnDataChannel(RTCDataChannelEvent::OnClose(7)),
            RealtimeIoEvent::DataChannelClosed(7),
        ),
    ];
    for (event, expected) in cases {
        assert_eq!(map_peer_event(event).expect("event maps"), vec![expected]);
    }

    for event in [
        RTCPeerConnectionEvent::default(),
        RTCPeerConnectionEvent::OnIceConnectionStateChangeEvent(RTCIceConnectionState::New),
        RTCPeerConnectionEvent::OnConnectionStateChangeEvent(RTCPeerConnectionState::New),
        RTCPeerConnectionEvent::OnDataChannel(RTCDataChannelEvent::OnError(7)),
    ] {
        assert!(map_peer_event(event)
            .expect("unowned event is ignored")
            .is_empty());
    }
}

#[test]
fn terminal_driver_events_discard_pending_h264_and_request_a_new_keyframe() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("peer");
    peer.configure_h264_screen_video(MediaDirection::Sendonly, Some(0x1357_2468))
        .expect("screen sender");
    peer.enqueue_h264_screen_video(
        synthetic_h264_access_unit(1, 90_000),
        std::time::Instant::now(),
    )
    .expect("native video ingress");

    apply_terminal_media_policy(&mut peer, &RealtimeIoEvent::PeerDisconnected);

    assert_eq!(peer.pending_h264_screen_video_frames(), 0);
    assert_eq!(
        peer.take_h264_screen_video_keyframe_request(),
        Some(KeyframeRequestReason::Disconnected)
    );
}

#[tokio::test]
async fn two_local_drivers_exchange_data_channel_payloads() {
    let caller = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("caller peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("caller driver");
    let responder = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("responder peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("responder driver");

    let caller = Arc::new(Mutex::new(caller));
    let responder = Arc::new(Mutex::new(responder));
    let channel_id = caller
        .lock()
        .unwrap()
        .peer_mut()
        .create_data_channel("local-e2e", DataChannelReliability::default())
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

    let (caller_events_tx, mut caller_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
    let (responder_events_tx, mut responder_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
    let caller_task = tokio::spawn(run_realtime_io(Arc::clone(&caller), caller_events_tx));
    let responder_task = tokio::spawn(run_realtime_io(Arc::clone(&responder), responder_events_tx));

    let mut caller_open = false;
    let mut responder_open = false;
    let open_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !(caller_open && responder_open) {
        tokio::select! {
            Some(event) = caller_events_rx.recv() => {
                caller_open |= matches!(event, RealtimeIoEvent::DataChannelOpened(_));
                assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
            }
            Some(event) = responder_events_rx.recv() => {
                responder_open |= matches!(event, RealtimeIoEvent::DataChannelOpened(_));
                assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
            }
            _ = tokio::time::sleep_until(open_deadline) => panic!("data channel did not open"),
        }
    }

    caller
        .lock()
        .unwrap()
        .peer_mut()
        .send_data(channel_id, b"encoded-frame")
        .unwrap();
    let payload_deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let payload = loop {
        tokio::select! {
            Some(event) = responder_events_rx.recv() => {
                if let RealtimeIoEvent::DataChannelMessage { payload, .. } = event {
                    break payload;
                }
            }
            _ = tokio::time::sleep_until(payload_deadline) => panic!("data channel payload not received"),
        }
    };
    assert_eq!(payload, b"encoded-frame");

    caller_task.abort();
    responder_task.abort();
    let _ = caller_task.await;
    let _ = responder_task.await;
}

#[tokio::test]
async fn two_local_drivers_exchange_h264_frames_over_rtp() {
    let caller = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("caller peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("caller driver");
    let responder = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("responder peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("responder driver");

    let caller = Arc::new(Mutex::new(caller));
    let responder = Arc::new(Mutex::new(responder));
    caller
        .lock()
        .unwrap()
        .peer_mut()
        .configure_h264_screen_video(MediaDirection::Sendonly, Some(0x1357_2468))
        .expect("caller screen sender");
    responder
        .lock()
        .unwrap()
        .peer_mut()
        .configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("responder screen receiver");

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

    let (caller_events_tx, mut caller_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
    let (responder_events_tx, mut responder_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
    let caller_task = tokio::spawn(run_realtime_io(Arc::clone(&caller), caller_events_tx));
    let responder_task = tokio::spawn(run_realtime_io(Arc::clone(&responder), responder_events_tx));

    let mut caller_connected = false;
    let mut responder_connected = false;
    let connection_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !(caller_connected && responder_connected) {
        tokio::select! {
            Some(event) = caller_events_rx.recv() => {
                caller_connected |= matches!(event, RealtimeIoEvent::PeerConnected);
                assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
            }
            Some(event) = responder_events_rx.recv() => {
                responder_connected |= matches!(event, RealtimeIoEvent::PeerConnected);
                assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
            }
            _ = tokio::time::sleep_until(connection_deadline) => panic!("H.264 peers did not connect"),
        }
    }

    let input = synthetic_h264_access_unit(7, 90_000);
    caller
        .lock()
        .unwrap()
        .peer_mut()
        .enqueue_h264_screen_video(input.clone(), std::time::Instant::now())
        .expect("native H.264 ingress");

    let frame_deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let received = loop {
        if let Some(frame) = responder
            .lock()
            .unwrap()
            .peer_mut()
            .pop_remote_h264_screen_video(std::time::Instant::now())
        {
            break frame;
        }
        tokio::select! {
            Some(event) = caller_events_rx.recv() => {
                assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
            }
            Some(event) = responder_events_rx.recv() => {
                assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
            }
            _ = tokio::time::sleep(Duration::from_millis(10)) => {}
            _ = tokio::time::sleep_until(frame_deadline) => panic!("H.264 RTP frame was not received"),
        }
    };

    assert_eq!(received.codec, VideoCodec::H264);
    assert_eq!(received.timestamp, input.timestamp);
    assert_eq!(received.width, input.width);
    assert_eq!(received.height, input.height);
    assert_eq!(received.keyframe, input.keyframe);
    assert_eq!(received.payload, input.payload);

    caller_task.abort();
    responder_task.abort();
    let _ = caller_task.await;
    let _ = responder_task.await;
}

#[tokio::test]
async fn driver_bind_uses_explicit_advertised_ip_and_closes_cleanly() {
    let driver = RealtimeIoDriver::bind_with_advertised_ip(
        WebRtcPeer::new(WebRtcConfig::default()).expect("peer"),
        "127.0.0.1:0".parse().unwrap(),
        Some("192.0.2.44".parse().unwrap()),
    )
    .await
    .expect("driver");
    assert_eq!(
        driver.local_addr().ip(),
        "127.0.0.1".parse::<std::net::IpAddr>().unwrap()
    );
    let handle = driver.into_handle();
    let mut driver = handle.lock().unwrap();
    driver.peer_mut().create_offer().expect("offer");
    driver.close().expect("close");
}

#[tokio::test]
async fn unspecified_bind_advertises_loopback_as_safe_fallback() {
    let mut driver = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("peer"),
        "0.0.0.0:0".parse().unwrap(),
    )
    .await
    .expect("driver");
    driver.peer_mut().create_offer().expect("offer");
    driver.close().expect("close");
}

#[tokio::test]
#[ignore = "requires a local coturn server at 127.0.0.1:3478"]
async fn relay_only_drivers_exchange_data_channel_payloads() {
    let config = WebRtcConfig {
        ice_servers: vec![IceServerConfig::turn(
            "turn:127.0.0.1:3478?transport=udp",
            "test",
            "test",
        )],
        relay_only: true,
        ..Default::default()
    };
    let caller = RealtimeIoDriver::bind(
        WebRtcPeer::new(config.clone()).expect("caller peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("caller driver");
    let responder = RealtimeIoDriver::bind(
        WebRtcPeer::new(config).expect("responder peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("responder driver");

    let caller = Arc::new(Mutex::new(caller));
    let responder = Arc::new(Mutex::new(responder));
    let channel_id = caller
        .lock()
        .unwrap()
        .peer_mut()
        .create_data_channel("relay-e2e", DataChannelReliability::default())
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

    let (caller_events_tx, mut caller_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
    let (responder_events_tx, mut responder_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
    let caller_task = tokio::spawn(run_realtime_io(Arc::clone(&caller), caller_events_tx));
    let responder_task = tokio::spawn(run_realtime_io(Arc::clone(&responder), responder_events_tx));

    let mut caller_open = false;
    let mut responder_open = false;
    let open_deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !(caller_open && responder_open) {
        tokio::select! {
            Some(event) = caller_events_rx.recv() => {
                match event {
                    RealtimeIoEvent::LocalIceCandidate(candidate) => {
                        responder.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap();
                    }
                    RealtimeIoEvent::DataChannelOpened(_) => caller_open = true,
                    RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed => panic!("caller relay ICE failed"),
                    _ => {}
                }
            }
            Some(event) = responder_events_rx.recv() => {
                match event {
                    RealtimeIoEvent::LocalIceCandidate(candidate) => {
                        caller.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap();
                    }
                    RealtimeIoEvent::DataChannelOpened(_) => responder_open = true,
                    RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed => panic!("responder relay ICE failed"),
                    _ => {}
                }
            }
            _ = tokio::time::sleep_until(open_deadline) => panic!("TURN data channel did not open"),
        }
    }

    caller
        .lock()
        .unwrap()
        .peer_mut()
        .send_data(channel_id, b"turn-relay-frame")
        .unwrap();
    let payload_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let payload = loop {
        tokio::select! {
            Some(event) = caller_events_rx.recv() => {
                if let RealtimeIoEvent::LocalIceCandidate(candidate) = event {
                    responder.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap();
                }
            }
            Some(event) = responder_events_rx.recv() => {
                match event {
                    RealtimeIoEvent::LocalIceCandidate(candidate) => {
                        caller.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap();
                    }
                    RealtimeIoEvent::DataChannelMessage { payload, .. } => break payload,
                    _ => {}
                }
            }
            _ = tokio::time::sleep_until(payload_deadline) => panic!("TURN data channel payload not received"),
        }
    };
    assert_eq!(payload, b"turn-relay-frame");

    caller_task.abort();
    responder_task.abort();
    let _ = caller_task.await;
    let _ = responder_task.await;
}

#[tokio::test]
#[ignore = "requires a local coturn server at 127.0.0.1:3478"]
async fn relay_only_drivers_exchange_video_frames() {
    let config = WebRtcConfig {
        ice_servers: vec![IceServerConfig::turn(
            "turn:127.0.0.1:3478?transport=udp",
            "test",
            "test",
        )],
        relay_only: true,
        ..Default::default()
    };
    let caller = RealtimeIoDriver::bind(
        WebRtcPeer::new(config.clone()).expect("caller peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("caller driver");
    let responder = RealtimeIoDriver::bind(
        WebRtcPeer::new(config).expect("responder peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("responder driver");

    let caller = Arc::new(Mutex::new(caller));
    let responder = Arc::new(Mutex::new(responder));
    caller
        .lock()
        .unwrap()
        .peer_mut()
        .configure_h264_screen_video(MediaDirection::Sendonly, Some(0x1357_2468))
        .expect("caller screen sender");
    responder
        .lock()
        .unwrap()
        .peer_mut()
        .configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("responder screen receiver");
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

    let (caller_events_tx, mut caller_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
    let (responder_events_tx, mut responder_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
    let caller_task = tokio::spawn(run_realtime_io(Arc::clone(&caller), caller_events_tx));
    let responder_task = tokio::spawn(run_realtime_io(Arc::clone(&responder), responder_events_tx));

    let mut caller_connected = false;
    let mut responder_connected = false;
    let connection_deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !(caller_connected && responder_connected) {
        tokio::select! {
            Some(event) = caller_events_rx.recv() => match event {
                RealtimeIoEvent::LocalIceCandidate(candidate) => responder.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap(),
                RealtimeIoEvent::PeerConnected => caller_connected = true,
                RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed => panic!("caller relay ICE failed"),
                _ => {}
            },
            Some(event) = responder_events_rx.recv() => match event {
                RealtimeIoEvent::LocalIceCandidate(candidate) => caller.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap(),
                RealtimeIoEvent::PeerConnected => responder_connected = true,
                RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed => panic!("responder relay ICE failed"),
                _ => {}
            },
            _ = tokio::time::sleep_until(connection_deadline) => panic!("TURN H.264 peers did not connect"),
        }
    }

    let input = synthetic_h264_access_unit(9, 90_000);
    caller
        .lock()
        .unwrap()
        .peer_mut()
        .enqueue_h264_screen_video(input.clone(), std::time::Instant::now())
        .expect("native H.264 ingress");

    let frame_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let received = loop {
        if let Some(frame) = responder
            .lock()
            .unwrap()
            .peer_mut()
            .pop_remote_h264_screen_video(std::time::Instant::now())
        {
            break frame;
        }
        tokio::select! {
            Some(event) = caller_events_rx.recv() => match event {
                RealtimeIoEvent::LocalIceCandidate(candidate) => responder.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap(),
                RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed => panic!("caller relay ICE failed"),
                _ => {}
            },
            Some(event) = responder_events_rx.recv() => match event {
                RealtimeIoEvent::LocalIceCandidate(candidate) => caller.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap(),
                RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed => panic!("responder relay ICE failed"),
                _ => {}
            },
            _ = tokio::time::sleep(Duration::from_millis(10)) => {}
            _ = tokio::time::sleep_until(frame_deadline) => panic!("TURN H.264 RTP frame was not received"),
        }
    };

    assert_eq!(received.codec, VideoCodec::H264);
    assert_eq!(received.timestamp, input.timestamp);
    assert_eq!(received.payload, input.payload);

    caller_task.abort();
    responder_task.abort();
    let _ = caller_task.await;
    let _ = responder_task.await;
}
