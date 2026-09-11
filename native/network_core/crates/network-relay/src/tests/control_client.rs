//! Relay control-client unit tests kept outside the implementation module.

use super::*;

#[test]
fn ready_frame_must_be_binary_and_match_device() {
    let ready = Ready {
        protocol_version: RELAY_V2_VERSION,
        device_id: "device-a".into(),
        server_time_ms: 1723840800123,
        heartbeat_interval_s: HEARTBEAT_INTERVAL_S,
        presence_ttl_s: PRESENCE_TTL_S,
    };
    let frame = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::Ready(ready.clone())),
    };
    let encoded = encode_control_frame(&frame).expect("encode");
    let message = Message::Binary(encoded.into());
    let validated = validate_ready(message, "device-a").expect("valid ready");
    assert_eq!(validated, ready);

    // 错误设备 ID 必须被拒绝。
    let message = Message::Binary(encode_control_frame(&frame).expect("encode").into());
    assert!(validate_ready(message, "other-device").is_err());
    // 文本帧必须被拒绝。
    assert!(validate_ready(Message::Text("{}".into()), "device-a").is_err());

    let mut invalid = ready;
    invalid.heartbeat_interval_s = 0;
    let frame = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::Ready(invalid)),
    };
    assert!(validate_ready(
        Message::Binary(encode_control_frame(&frame).expect("encode").into()),
        "device-a"
    )
    .is_err());
}

#[test]
fn ready_presence_ttl_is_optional_until_a_valid_value_is_received() {
    let ready = Ready {
        protocol_version: RELAY_V2_VERSION,
        device_id: "device-a".into(),
        server_time_ms: 0,
        heartbeat_interval_s: HEARTBEAT_INTERVAL_S,
        presence_ttl_s: 37,
    };
    assert_eq!(
        ready_presence_ttl_from_frame(&ready),
        Some(Duration::from_secs(37))
    );
    assert_eq!(
        ready_presence_ttl_from_frame(&Ready {
            presence_ttl_s: 0,
            ..ready
        }),
        None
    );
}

#[test]
fn server_to_client_offers_and_hints_decode_as_events() {
    let offer = ConnectivityOffer {
        request_id: 1001,
        attempt_id: "a1b2c3d4e5f60718293a4b5c6d7e8f90".into(),
        initiator_device_id: "device-a".into(),
        initiator_runtime_epoch: Some(RuntimeEpoch {
            high: 0x6A09E667,
            low: 0xBB67AE85,
        }),
        initiator_revision: 7,
        initiator_snapshot: None,
    };
    let frame = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::ConnectivityOffer(offer.clone())),
    };
    match control_event_from_frame(frame).expect("event") {
        ControlEvent::ConnectivityOffer(decoded) => assert_eq!(decoded, offer),
        other => panic!("expected ConnectivityOffer, got {other:?}"),
    }

    let hint = PeerUnavailableHint {
        device_id: "device-b".into(),
        reason: "device offline".into(),
    };
    let frame = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::PeerUnavailableHint(hint.clone())),
    };
    match control_event_from_frame(frame).expect("event") {
        ControlEvent::PeerUnavailableHint(decoded) => assert_eq!(decoded, hint),
        other => panic!("expected PeerUnavailableHint, got {other:?}"),
    }
}

#[test]
fn control_frame_version_must_be_two() {
    let frame = RelayFrame {
        version: 1,
        kind: Some(relay_frame::Kind::HeartbeatAck(HeartbeatAck {
            request_id: 1,
            server_time_ms: 0,
        })),
    };
    assert!(encode_control_frame(&frame).is_err());
}

#[test]
fn control_event_decoder_rejects_malformed_and_direction_invalid_frames() {
    assert!(matches!(
        decode_control_event(Message::Binary(vec![0xff].into())),
        Err(RelayError::Protocol(_))
    ));
    assert!(decode_control_event(Message::Ping(vec![].into()))
        .unwrap()
        .is_none());
    assert!(decode_control_event(Message::Pong(vec![].into()))
        .unwrap()
        .is_none());
    assert!(matches!(
        decode_control_event(Message::Close(None)),
        Err(RelayError::Socket(_))
    ));
    assert!(matches!(
        decode_control_event(Message::Text("text".into())),
        Err(RelayError::Protocol(_))
    ));

    let invalid_direction_frames = [
        relay_frame::Kind::Heartbeat(Heartbeat {
            request_id: 1,
            sent_at_ms: 1,
        }),
        relay_frame::Kind::DiscoveryPublish(DiscoveryPublish {
            request_id: 1,
            snapshot: None,
        }),
        relay_frame::Kind::ResolvePeerRequest(ResolvePeerRequest {
            request_id: 1,
            target_device_id: "device-b".into(),
        }),
        relay_frame::Kind::RelayReserveRequest(RelayReserveRequest {
            request_id: 1,
            attempt_id: "attempt".into(),
            target_device_id: "device-b".into(),
            desired_lifetime_s: 1,
        }),
        relay_frame::Kind::Ready(Ready {
            protocol_version: RELAY_V2_VERSION,
            device_id: "device-a".into(),
            server_time_ms: 0,
            heartbeat_interval_s: HEARTBEAT_INTERVAL_S,
            presence_ttl_s: PRESENCE_TTL_S,
        }),
    ];
    for kind in invalid_direction_frames {
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(kind),
        };
        let encoded = encode_control_frame(&frame).expect("frame encoding");
        assert!(matches!(
            decode_control_event(Message::Binary(encoded.into())),
            Err(RelayError::Protocol(_))
        ));
    }

    for kind in [
        relay_frame::Kind::ConnectivityOffer(ConnectivityOffer::default()),
        relay_frame::Kind::ConnectivityAnswer(ConnectivityAnswer::default()),
    ] {
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(kind),
        };
        let encoded = encode_control_frame(&frame).expect("frame encoding");
        assert!(matches!(
            decode_control_event(Message::Binary(encoded.into())),
            Err(RelayError::Protocol(_))
        ));
    }

    let missing_kind = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: None,
    };
    let encoded = encode_control_frame(&missing_kind).expect("frame encoding");
    assert!(matches!(
        decode_control_event(Message::Binary(encoded.into())),
        Err(RelayError::Protocol(_))
    ));
    let wrong_version = RelayFrame {
        version: RELAY_V2_VERSION + 1,
        kind: Some(relay_frame::Kind::HeartbeatAck(HeartbeatAck::default())),
    };
    assert!(matches!(
        control_event_from_frame(wrong_version),
        Err(RelayError::Protocol(_))
    ));
}

#[test]
fn ready_and_discovery_validation_rejects_missing_zero_and_mismatched_fields() {
    let valid_ready = Ready {
        protocol_version: RELAY_V2_VERSION,
        device_id: "device-a".into(),
        server_time_ms: 0,
        heartbeat_interval_s: HEARTBEAT_INTERVAL_S,
        presence_ttl_s: PRESENCE_TTL_S,
    };
    for ready in [
        Ready {
            protocol_version: RELAY_V2_VERSION + 1,
            ..valid_ready.clone()
        },
        Ready {
            presence_ttl_s: 0,
            ..valid_ready.clone()
        },
        Ready {
            presence_ttl_s: HEARTBEAT_INTERVAL_S - 1,
            ..valid_ready.clone()
        },
    ] {
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::Ready(ready)),
        };
        assert!(validate_ready(
            Message::Binary(encode_control_frame(&frame).expect("encode").into()),
            "device-a"
        )
        .is_err());
    }
    let not_ready = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::HeartbeatAck(HeartbeatAck::default())),
    };
    assert!(validate_ready(
        Message::Binary(encode_control_frame(&not_ready).expect("encode").into()),
        "device-a"
    )
    .is_err());
    let missing = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: None,
    };
    assert!(validate_ready(
        Message::Binary(encode_control_frame(&missing).expect("encode").into()),
        "device-a"
    )
    .is_err());

    let valid_snapshot = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 1, low: 2 }),
        revision: 1,
        transport_capabilities: Vec::new(),
        candidate_bundle: None,
        published_at_ms: 0,
    };
    assert!(validate_discovery_snapshot(&valid_snapshot).is_ok());
    for snapshot in [
        DiscoverySnapshot {
            runtime_epoch: None,
            ..valid_snapshot.clone()
        },
        DiscoverySnapshot {
            runtime_epoch: Some(RuntimeEpoch { high: 0, low: 0 }),
            ..valid_snapshot.clone()
        },
        DiscoverySnapshot {
            revision: 0,
            ..valid_snapshot.clone()
        },
        DiscoverySnapshot {
            transport_capabilities: vec![0; MAX_DISCOVERY_CAPABILITIES + 1],
            ..valid_snapshot.clone()
        },
        DiscoverySnapshot {
            candidate_bundle: Some(CandidateBundle {
                candidates: vec![vec![0; MAX_DISCOVERY_CANDIDATE_BYTES + 1]],
            }),
            ..valid_snapshot.clone()
        },
    ] {
        assert!(matches!(
            validate_discovery_snapshot(&snapshot),
            Err(RelayError::InvalidConfiguration(_))
        ));
    }

    assert!(validate_discovery_tuple(
        &RuntimeEpoch { high: 1, low: 2 },
        1,
        Some(&valid_snapshot),
        "offer"
    )
    .is_ok());
    for (epoch, revision, snapshot) in [
        (RuntimeEpoch { high: 0, low: 0 }, 1, Some(&valid_snapshot)),
        (RuntimeEpoch { high: 1, low: 2 }, 0, Some(&valid_snapshot)),
        (RuntimeEpoch { high: 1, low: 2 }, 1, None),
    ] {
        assert!(matches!(
            validate_discovery_tuple(&epoch, revision, snapshot, "answer"),
            Err(RelayError::InvalidConfiguration(_))
        ));
    }
    let mismatched_revision = DiscoverySnapshot {
        revision: 2,
        ..valid_snapshot.clone()
    };
    assert!(matches!(
        validate_discovery_tuple(
            &RuntimeEpoch { high: 1, low: 2 },
            1,
            Some(&mismatched_revision),
            "answer"
        ),
        Err(RelayError::Protocol(_))
    ));
    let mismatched_epoch = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 3, low: 4 }),
        ..valid_snapshot
    };
    assert!(matches!(
        validate_discovery_tuple(
            &RuntimeEpoch { high: 1, low: 2 },
            1,
            Some(&mismatched_epoch),
            "answer"
        ),
        Err(RelayError::Protocol(_))
    ));
}

#[tokio::test]
async fn request_id_response_is_routed_to_the_matching_oneshot() {
    let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
        Arc::new(RwLock::new(HashMap::new()));
    let attempts: AttemptStore = Arc::new(StdMutex::new(HashMap::new()));
    let (events_tx, mut events_rx) = mpsc::channel(4);

    let (tx, rx) = oneshot::channel();
    pending.write().await.insert(42, tx);

    let response = ResolvePeerResponse {
        request_id: 42,
        status: ResolveStatus::Ready as i32,
        discovery: None,
        retry_after_ms: 0,
    };
    route_control_event(
        ControlEvent::ResolvePeerResponse(response.clone()),
        &pending,
        &attempts,
        &events_tx,
    )
    .await;

    assert_eq!(
        rx.await.expect("oneshot resolved"),
        ControlEvent::ResolvePeerResponse(response)
    );
    assert!(pending.read().await.is_empty());
    assert!(events_rx.try_recv().is_err(), "no fallback event expected");
}

#[tokio::test]
async fn disconnect_drains_request_and_attempt_waiters_once() {
    let connected = Arc::new(RwLock::new(true));
    let notified = Arc::new(AtomicBool::new(false));
    let intentional = Arc::new(AtomicBool::new(false));
    let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
        Arc::new(RwLock::new(HashMap::new()));
    let attempts: AttemptStore = Arc::new(StdMutex::new(HashMap::new()));
    let (inbound, mut events) = mpsc::channel(4);
    let (pending_tx, pending_rx) = oneshot::channel();
    pending.write().await.insert(7, pending_tx);
    let (attempt_tx, attempt_rx) = oneshot::channel();
    attempts.lock().unwrap().insert(
        "attempt-drain".into(),
        AttemptTracker {
            created_at: Instant::now(),
            token: Arc::new(()),
            response_tx: attempt_tx,
        },
    );

    mark_control_disconnected(
        &connected,
        &inbound,
        &notified,
        &intentional,
        &pending,
        &attempts,
        "socket closed".into(),
    )
    .await;
    assert!(!*connected.read().await);
    assert!(pending.read().await.is_empty());
    assert!(attempts.lock().unwrap().is_empty());
    assert!(matches!(
        pending_rx.await.expect("pending waiter failed"),
        ControlEvent::Disconnected { .. }
    ));
    assert!(matches!(
        attempt_rx.await.expect("attempt waiter failed"),
        ControlEvent::Disconnected { .. }
    ));
    assert!(matches!(
        events.recv().await.expect("disconnect event"),
        ControlEvent::Disconnected { .. }
    ));

    mark_control_disconnected(
        &connected,
        &inbound,
        &notified,
        &intentional,
        &pending,
        &attempts,
        "socket closed again".into(),
    )
    .await;
    assert!(
        events.try_recv().is_err(),
        "disconnect notification is one-shot"
    );
}

#[tokio::test]
async fn intentional_disconnect_drains_waiters_without_emitting_event() {
    let connected = Arc::new(RwLock::new(true));
    let notified = Arc::new(AtomicBool::new(false));
    let intentional = Arc::new(AtomicBool::new(true));
    let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
        Arc::new(RwLock::new(HashMap::new()));
    let attempts: AttemptStore = Arc::new(StdMutex::new(HashMap::new()));
    let (inbound, mut events) = mpsc::channel(1);
    let (tx, rx) = oneshot::channel();
    pending.write().await.insert(1, tx);

    mark_control_disconnected(
        &connected,
        &inbound,
        &notified,
        &intentional,
        &pending,
        &attempts,
        "intentional".into(),
    )
    .await;
    assert!(matches!(
        rx.await.expect("pending waiter failed"),
        ControlEvent::Disconnected { .. }
    ));
    assert!(events.try_recv().is_err());
}

#[tokio::test]
async fn attempt_id_response_is_routed_by_attempt_tracker() {
    let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
        Arc::new(RwLock::new(HashMap::new()));
    let attempts: AttemptStore = Arc::new(StdMutex::new(HashMap::new()));
    let (events_tx, _events_rx) = mpsc::channel(4);

    let attempt_id = "a1b2c3d4e5f60718293a4b5c6d7e8f90";
    let (tx, rx) = oneshot::channel();
    attempts.lock().unwrap().insert(
        attempt_id.to_string(),
        AttemptTracker {
            created_at: Instant::now(),
            token: Arc::new(()),
            response_tx: tx,
        },
    );

    let answer = ConnectivityAnswer {
        request_id: 2002,
        attempt_id: attempt_id.to_string(),
        accepted: true,
        responder_device_id: "device-b".into(),
        responder_runtime_epoch: None,
        responder_revision: 3,
        responder_snapshot: None,
    };
    route_control_event(
        ControlEvent::ConnectivityAnswer(answer.clone()),
        &pending,
        &attempts,
        &events_tx,
    )
    .await;

    assert_eq!(
        rx.await.expect("attempt resolved"),
        ControlEvent::ConnectivityAnswer(answer)
    );
    assert!(attempts.lock().unwrap().is_empty());
}

#[test]
fn dropping_unpolled_connectivity_attempt_start_releases_tracker() {
    let attempts: AttemptStore = Arc::new(StdMutex::new(HashMap::new()));
    let attempt_id = "dropped-start".to_string();
    let (tx, _rx) = oneshot::channel();
    let lease = AttemptLease::new(Arc::clone(&attempts), attempt_id.clone());
    attempts.lock().unwrap().insert(
        attempt_id,
        AttemptTracker {
            created_at: Instant::now(),
            token: lease.token(),
            response_tx: tx,
        },
    );
    let start = ConnectivityAttemptStart {
        resolved: ResolvePeerResponse {
            request_id: 1,
            status: ResolveStatus::Ready as i32,
            discovery: None,
            retry_after_ms: 0,
        },
        answer: Box::pin(async { Err(RelayError::NotConnected) }),
        attempt_lease: Some(lease),
    };

    drop(start);
    assert!(attempts.lock().unwrap().is_empty());
}

#[tokio::test]
async fn old_waiter_cleanup_cannot_remove_new_same_id_tracker() {
    let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
        Arc::new(RwLock::new(HashMap::new()));
    let attempts: AttemptStore = Arc::new(StdMutex::new(HashMap::new()));
    let (events_tx, _events_rx) = mpsc::channel(4);
    let attempt_id = "reused-attempt".to_string();

    let (old_tx, old_rx) = oneshot::channel();
    let old_lease = AttemptLease::new(Arc::clone(&attempts), attempt_id.clone());
    attempts.lock().unwrap().insert(
        attempt_id.clone(),
        AttemptTracker {
            created_at: Instant::now(),
            token: old_lease.token(),
            response_tx: old_tx,
        },
    );
    let old_waiter = ConnectivityAnswerWaiter {
        response_rx: old_rx,
        owner: old_lease.owner(),
    };

    route_control_event(
        ControlEvent::ProtocolError(ProtocolError {
            request_id: 1,
            attempt_id: attempt_id.clone(),
            code: ErrorCode::PeerNotReady as i32,
            message: "old attempt failed".into(),
        }),
        &pending,
        &attempts,
        &events_tx,
    )
    .await;

    let (new_tx, new_rx) = oneshot::channel();
    let new_token = Arc::new(());
    attempts.lock().unwrap().insert(
        attempt_id.clone(),
        AttemptTracker {
            created_at: Instant::now(),
            token: Arc::clone(&new_token),
            response_tx: new_tx,
        },
    );

    assert!(matches!(
        old_waiter.wait().await,
        Err(RelayError::Protocol(_))
    ));
    assert_eq!(attempts.lock().unwrap().len(), 1);

    route_control_event(
        ControlEvent::ConnectivityAnswer(ConnectivityAnswer {
            request_id: 2,
            attempt_id,
            accepted: false,
            responder_device_id: "device-b".into(),
            responder_runtime_epoch: None,
            responder_revision: 0,
            responder_snapshot: None,
        }),
        &pending,
        &attempts,
        &events_tx,
    )
    .await;
    assert!(matches!(
        new_rx.await.expect("new tracker answer"),
        ControlEvent::ConnectivityAnswer(_)
    ));
    assert!(attempts.lock().unwrap().is_empty());
    drop(old_lease);
}

#[tokio::test]
async fn async_events_fall_through_to_the_event_stream() {
    let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
        Arc::new(RwLock::new(HashMap::new()));
    let attempts: AttemptStore = Arc::new(StdMutex::new(HashMap::new()));
    let (events_tx, mut events_rx) = mpsc::channel(4);

    let hint = PeerUnavailableHint {
        device_id: "device-b".into(),
        reason: "offline".into(),
    };
    route_control_event(
        ControlEvent::PeerUnavailableHint(hint.clone()),
        &pending,
        &attempts,
        &events_tx,
    )
    .await;

    assert_eq!(
        events_rx.recv().await.expect("async event"),
        ControlEvent::PeerUnavailableHint(hint)
    );
}

#[tokio::test]
async fn protocol_error_with_request_id_fails_that_request() {
    let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
        Arc::new(RwLock::new(HashMap::new()));
    let attempts: AttemptStore = Arc::new(StdMutex::new(HashMap::new()));
    let (events_tx, _events_rx) = mpsc::channel(4);

    let (tx, rx) = oneshot::channel();
    pending.write().await.insert(7, tx);

    let error = ProtocolError {
        request_id: 7,
        attempt_id: String::new(),
        code: ErrorCode::EpochConflict as i32,
        message: "revision already published".into(),
    };
    route_control_event(
        ControlEvent::ProtocolError(error.clone()),
        &pending,
        &attempts,
        &events_tx,
    )
    .await;

    match rx.await.expect("oneshot resolved") {
        ControlEvent::ProtocolError(decoded) => assert_eq!(decoded, error),
        other => panic!("expected ProtocolError, got {other:?}"),
    }
}

#[tokio::test]
async fn attempt_protocol_error_prefers_attempt_tracker_and_does_not_leak() {
    let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
        Arc::new(RwLock::new(HashMap::new()));
    let attempts: AttemptStore = Arc::new(StdMutex::new(HashMap::new()));
    let (events_tx, mut events_rx) = mpsc::channel(4);
    let attempt_id = "attempt-with-error";
    let (tx, rx) = oneshot::channel();
    attempts.lock().unwrap().insert(
        attempt_id.to_string(),
        AttemptTracker {
            created_at: Instant::now(),
            token: Arc::new(()),
            response_tx: tx,
        },
    );
    let error = ProtocolError {
        request_id: 81,
        attempt_id: attempt_id.into(),
        code: ErrorCode::PeerNotReady as i32,
        message: "target is not ready".into(),
    };

    route_control_event(
        ControlEvent::ProtocolError(error.clone()),
        &pending,
        &attempts,
        &events_tx,
    )
    .await;

    assert_eq!(
        rx.await.expect("attempt error"),
        ControlEvent::ProtocolError(error)
    );
    assert!(
        events_rx.try_recv().is_err(),
        "attempt errors are not generic events"
    );
    assert!(attempts.lock().unwrap().is_empty());
}

#[tokio::test]
async fn unknown_or_late_connectivity_answer_is_dropped() {
    let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
        Arc::new(RwLock::new(HashMap::new()));
    let attempts: AttemptStore = Arc::new(StdMutex::new(HashMap::new()));
    let (events_tx, mut events_rx) = mpsc::channel(4);
    route_control_event(
        ControlEvent::ConnectivityAnswer(ConnectivityAnswer {
            request_id: 9,
            attempt_id: "unknown-attempt".into(),
            accepted: false,
            responder_device_id: "device-b".into(),
            responder_runtime_epoch: None,
            responder_revision: 0,
            responder_snapshot: None,
        }),
        &pending,
        &attempts,
        &events_tx,
    )
    .await;
    assert!(
        events_rx.try_recv().is_err(),
        "late answers must not leak to event consumers"
    );
}

#[test]
fn resolve_response_requires_authoritative_four_state_shape() {
    assert!(validate_resolve_response(ResolvePeerResponse {
        request_id: 1,
        status: ResolveStatus::Ready as i32,
        discovery: None,
        retry_after_ms: 0,
    })
    .is_err());
    assert!(validate_resolve_response(ResolvePeerResponse {
        request_id: 2,
        status: ResolveStatus::Offline as i32,
        discovery: Some(DiscoverySnapshot {
            runtime_epoch: Some(RuntimeEpoch { high: 1, low: 2 }),
            revision: 1,
            transport_capabilities: Vec::new(),
            candidate_bundle: None,
            published_at_ms: 0,
        }),
        retry_after_ms: 0,
    })
    .is_err());
    assert!(validate_resolve_response(ResolvePeerResponse {
        request_id: 3,
        status: ResolveStatus::Unknown as i32,
        discovery: None,
        retry_after_ms: RESOLVE_RETRY_HINT_UNKNOWN_MS,
    })
    .is_ok());
}

#[tokio::test]
async fn duplicate_connectivity_attempt_id_is_rejected() {
    let client = RelayControlClient::new(
        "https://relay.example.test".into(),
        "device-a".into(),
        "credential".into(),
        [0u8; 32],
    )
    .expect("client");
    let (tx, _rx) = oneshot::channel();
    client.attempts.lock().unwrap().insert(
        "same-attempt".into(),
        AttemptTracker {
            created_at: Instant::now(),
            token: Arc::new(()),
            response_tx: tx,
        },
    );
    let error = client
        .start_connectivity_attempt(
            "same-attempt".into(),
            "device-b".into(),
            "spoofed-device".into(),
            RuntimeEpoch { high: 1, low: 2 },
            1,
            Some(DiscoverySnapshot {
                runtime_epoch: Some(RuntimeEpoch { high: 1, low: 2 }),
                revision: 1,
                transport_capabilities: Vec::new(),
                candidate_bundle: None,
                published_at_ms: 0,
            }),
        )
        .await
        .expect_err("duplicate attempt must fail");
    assert!(matches!(error, RelayError::Protocol(_)));
    assert_eq!(client.attempts.lock().unwrap().len(), 1);
}

fn begin_test_client(capacity: usize) -> (Arc<RelayControlClient>, mpsc::Receiver<Message>) {
    let mut client = RelayControlClient::new(
        "https://relay.example.test".into(),
        "device-a".into(),
        "credential".into(),
        [0u8; 32],
    )
    .expect("client");
    let (outbound, frames) = mpsc::channel(capacity);
    client.outbound = Some(outbound);
    (Arc::new(client), frames)
}

fn begin_test_initiator() -> (RuntimeEpoch, DiscoverySnapshot) {
    let epoch = RuntimeEpoch { high: 1, low: 2 };
    let snapshot = DiscoverySnapshot {
        runtime_epoch: Some(epoch.clone()),
        revision: 1,
        transport_capabilities: Vec::new(),
        candidate_bundle: None,
        published_at_ms: 0,
    };
    (epoch, snapshot)
}

fn test_request_frame(request_id: u64) -> RelayFrame {
    RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::ResolvePeerRequest(ResolvePeerRequest {
            request_id,
            target_device_id: "device-b".into(),
        })),
    }
}

#[tokio::test]
async fn send_and_await_routes_success_and_disconnected_responses() {
    let (client, mut frames) = begin_test_client(4);
    let request = test_request_frame(41);
    let pending_client = Arc::clone(&client);
    let success = tokio::spawn(async move {
        pending_client
            .send_and_await(request, Duration::from_secs(1))
            .await
    });
    let outbound = frames.recv().await.expect("request frame");
    assert!(matches!(outbound, Message::Binary(_)));
    let (events_tx, _events_rx) = mpsc::channel(1);
    route_control_event(
        ControlEvent::ResolvePeerResponse(ResolvePeerResponse {
            request_id: 41,
            status: ResolveStatus::Offline as i32,
            discovery: None,
            retry_after_ms: 0,
        }),
        &client.pending,
        &client.attempts,
        &events_tx,
    )
    .await;
    assert!(matches!(
        success.await.expect("success task"),
        Ok(ControlEvent::ResolvePeerResponse(_))
    ));

    let (client, mut frames) = begin_test_client(4);
    let pending_client = Arc::clone(&client);
    let disconnected = tokio::spawn(async move {
        pending_client
            .send_and_await(test_request_frame(42), Duration::from_secs(1))
            .await
    });
    let _ = frames.recv().await.expect("request frame");
    let sender = client
        .pending
        .write()
        .await
        .remove(&42)
        .expect("pending sender");
    let _ = sender.send(ControlEvent::Disconnected {
        reason: "closed".into(),
    });
    assert!(matches!(
        disconnected.await.expect("disconnected task"),
        Err(RelayError::NotConnected)
    ));
    assert!(client.pending.read().await.is_empty());
}

#[tokio::test(start_paused = true)]
async fn send_and_await_cleans_pending_on_timeout_and_send_failure() {
    let (client, mut frames) = begin_test_client(4);
    let request = tokio::spawn({
        let client = Arc::clone(&client);
        async move {
            client
                .send_and_await(test_request_frame(43), Duration::from_millis(1))
                .await
        }
    });
    let _ = frames.recv().await.expect("request frame");
    tokio::time::advance(Duration::from_millis(2)).await;
    assert!(matches!(
        request.await.expect("timeout task"),
        Err(RelayError::Timeout(_))
    ));
    assert!(client.pending.read().await.is_empty());

    let (client, frames) = begin_test_client(1);
    drop(frames);
    assert!(matches!(
        client
            .send_and_await(test_request_frame(44), Duration::from_secs(1))
            .await,
        Err(RelayError::NotConnected)
    ));
    assert!(client.pending.read().await.is_empty());
}

#[tokio::test]
async fn begin_connectivity_attempt_performs_one_resolve_then_offer() {
    let (client, mut frames) = begin_test_client(8);
    let (initiator_epoch, initiator_snapshot) = begin_test_initiator();
    let attempt_id = "begin-one-resolve".to_string();
    let begin_task = {
        let client = Arc::clone(&client);
        let attempt_id = attempt_id.clone();
        let initiator_epoch = initiator_epoch.clone();
        let initiator_snapshot = initiator_snapshot.clone();
        tokio::spawn(async move {
            client
                .begin_connectivity_attempt(
                    attempt_id,
                    "device-b".into(),
                    "device-a".into(),
                    initiator_epoch,
                    1,
                    Some(initiator_snapshot),
                )
                .await
        })
    };

    let Message::Binary(frame) = frames.recv().await.expect("resolve frame") else {
        panic!("expected binary resolve frame");
    };
    let frame = decode_control_frame(&frame).expect("decode resolve frame");
    let relay_frame::Kind::ResolvePeerRequest(resolve) = frame.kind.expect("resolve kind") else {
        panic!("expected ResolvePeerRequest");
    };
    assert_eq!(resolve.target_device_id, "device-b");
    let resolved = ResolvePeerResponse {
        request_id: resolve.request_id,
        status: ResolveStatus::Ready as i32,
        discovery: Some(DiscoverySnapshot {
            runtime_epoch: Some(RuntimeEpoch { high: 3, low: 4 }),
            revision: 7,
            transport_capabilities: Vec::new(),
            candidate_bundle: None,
            published_at_ms: 0,
        }),
        retry_after_ms: 0,
    };
    let (events_tx, _events_rx) = mpsc::channel(4);
    route_control_event(
        ControlEvent::ResolvePeerResponse(resolved.clone()),
        &client.pending,
        &client.attempts,
        &events_tx,
    )
    .await;

    let Message::Binary(frame) = frames.recv().await.expect("offer frame") else {
        panic!("expected binary connectivity offer");
    };
    let frame = decode_control_frame(&frame).expect("decode offer frame");
    let relay_frame::Kind::ConnectivityOffer(offer) = frame.kind.expect("offer kind") else {
        panic!("expected ConnectivityOffer");
    };
    assert_eq!(offer.attempt_id, attempt_id);
    assert_eq!(offer.initiator_device_id, "device-a");
    assert!(
        frames.try_recv().is_err(),
        "one begin must enqueue one Offer"
    );

    let start = begin_task
        .await
        .expect("begin task")
        .expect("begin success");
    assert_eq!(start.resolved, resolved);

    let answer = ConnectivityAnswer {
        request_id: offer.request_id + 1,
        attempt_id: attempt_id.clone(),
        accepted: false,
        responder_device_id: "device-b".into(),
        responder_runtime_epoch: None,
        responder_revision: 0,
        responder_snapshot: None,
    };
    route_control_event(
        ControlEvent::ConnectivityAnswer(answer.clone()),
        &client.pending,
        &client.attempts,
        &events_tx,
    )
    .await;
    assert_eq!(start.wait_for_answer().await.expect("answer"), answer);
    assert!(client.attempts.lock().unwrap().is_empty());
}

#[tokio::test]
async fn begin_connectivity_attempt_non_ready_resolve_does_not_enqueue_offer() {
    let (client, mut frames) = begin_test_client(8);
    let (initiator_epoch, initiator_snapshot) = begin_test_initiator();
    let begin_task = {
        let client = Arc::clone(&client);
        tokio::spawn(async move {
            client
                .begin_connectivity_attempt(
                    "begin-not-ready".into(),
                    "device-b".into(),
                    "device-a".into(),
                    initiator_epoch,
                    1,
                    Some(initiator_snapshot),
                )
                .await
        })
    };

    let Message::Binary(frame) = frames.recv().await.expect("resolve frame") else {
        panic!("expected binary resolve frame");
    };
    let frame = decode_control_frame(&frame).expect("decode resolve frame");
    let relay_frame::Kind::ResolvePeerRequest(resolve) = frame.kind.expect("resolve kind") else {
        panic!("expected ResolvePeerRequest");
    };
    let (events_tx, _events_rx) = mpsc::channel(4);
    route_control_event(
        ControlEvent::ResolvePeerResponse(ResolvePeerResponse {
            request_id: resolve.request_id,
            status: ResolveStatus::Offline as i32,
            discovery: None,
            retry_after_ms: 0,
        }),
        &client.pending,
        &client.attempts,
        &events_tx,
    )
    .await;

    let start = begin_task
        .await
        .expect("begin task")
        .expect("non-ready Resolve response is authoritative");
    assert_eq!(start.resolved.status, ResolveStatus::Offline as i32);
    assert!(matches!(
        start.wait_for_answer().await,
        Err(RelayError::Protocol(_))
    ));
    assert!(
        frames.try_recv().is_err(),
        "non-READY resolve must not enqueue Offer"
    );
    assert!(client.attempts.lock().unwrap().is_empty());
}

#[tokio::test(start_paused = true)]
async fn connectivity_answer_waiter_cleans_tracker_after_timeout() {
    let (client, mut frames) = begin_test_client(8);
    let (initiator_epoch, initiator_snapshot) = begin_test_initiator();
    let begin_task = {
        let client = Arc::clone(&client);
        tokio::spawn(async move {
            client
                .begin_connectivity_attempt(
                    "begin-timeout".into(),
                    "device-b".into(),
                    "device-a".into(),
                    initiator_epoch,
                    1,
                    Some(initiator_snapshot),
                )
                .await
        })
    };

    let Message::Binary(frame) = frames.recv().await.expect("resolve frame") else {
        panic!("expected binary resolve frame");
    };
    let frame = decode_control_frame(&frame).expect("decode resolve frame");
    let relay_frame::Kind::ResolvePeerRequest(resolve) = frame.kind.expect("resolve kind") else {
        panic!("expected ResolvePeerRequest");
    };
    let (events_tx, _events_rx) = mpsc::channel(4);
    route_control_event(
        ControlEvent::ResolvePeerResponse(ResolvePeerResponse {
            request_id: resolve.request_id,
            status: ResolveStatus::Ready as i32,
            discovery: Some(DiscoverySnapshot {
                runtime_epoch: Some(RuntimeEpoch { high: 3, low: 4 }),
                revision: 7,
                transport_capabilities: Vec::new(),
                candidate_bundle: None,
                published_at_ms: 0,
            }),
            retry_after_ms: 0,
        }),
        &client.pending,
        &client.attempts,
        &events_tx,
    )
    .await;
    let Message::Binary(_frame) = frames.recv().await.expect("offer frame") else {
        panic!("expected binary connectivity offer");
    };

    let start = begin_task
        .await
        .expect("begin task")
        .expect("begin success");
    assert_eq!(client.attempts.lock().unwrap().len(), 1);
    let wait_task = tokio::spawn(async move { start.wait_for_answer().await });
    tokio::task::yield_now().await;
    tokio::time::advance(CONNECTIVITY_ATTEMPT_TIMEOUT + Duration::from_millis(1)).await;
    let error = wait_task
        .await
        .expect("wait task")
        .expect_err("answer wait must time out");
    assert!(matches!(error, RelayError::Timeout(_)));
    assert!(client.attempts.lock().unwrap().is_empty());
}

#[tokio::test]
async fn connectivity_answer_uses_authenticated_responder_identity() {
    let mut client = RelayControlClient::new(
        "https://relay.example.test".into(),
        "device-b".into(),
        "credential".into(),
        [0u8; 32],
    )
    .expect("client");
    let (outbound, mut frames) = mpsc::channel(1);
    client.outbound = Some(outbound);
    client
        .send_connectivity_answer(
            &ConnectivityOffer {
                request_id: 1,
                attempt_id: "answer-attempt".into(),
                initiator_device_id: "device-a".into(),
                initiator_runtime_epoch: None,
                initiator_revision: 0,
                initiator_snapshot: None,
            },
            false,
            "spoofed-device",
            RuntimeEpoch { high: 0, low: 0 },
            0,
            None,
        )
        .await
        .expect("answer frame");
    let Message::Binary(frame) = frames.recv().await.expect("answer frame") else {
        panic!("expected binary answer frame");
    };
    let frame = decode_control_frame(&frame).expect("decode answer frame");
    let relay_frame::Kind::ConnectivityAnswer(answer) = frame.kind.expect("answer kind") else {
        panic!("expected connectivity answer");
    };
    assert_eq!(answer.responder_device_id, "device-b");
}

#[test]
fn request_and_attempt_ids_are_extracted_from_frames() {
    let frame = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::ResolvePeerRequest(ResolvePeerRequest {
            request_id: 1001,
            target_device_id: "device-b".into(),
        })),
    };
    assert_eq!(frame_request_id(&frame), Some(1001));

    let frame = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::ConnectivityAnswer(ConnectivityAnswer {
            request_id: 2002,
            attempt_id: "attempt-1".into(),
            accepted: true,
            responder_device_id: "device-b".into(),
            responder_runtime_epoch: None,
            responder_revision: 3,
            responder_snapshot: None,
        })),
    };
    assert_eq!(frame_request_id(&frame), Some(2002));
    match frame.kind.as_ref().expect("kind") {
        relay_frame::Kind::ConnectivityAnswer(answer) => {
            assert_eq!(answer.attempt_id, "attempt-1");
        }
        other => panic!("expected ConnectivityAnswer, got {other:?}"),
    }
}

#[tokio::test]
async fn validation_rejects_out_of_bounds_identifiers() {
    let client = RelayControlClient::new(
        "https://relay.example.test".into(),
        "device-a".into(),
        "credential".into(),
        [0u8; 32],
    )
    .expect("client");
    assert!(matches!(
        client.resolve_peer("").await,
        Err(RelayError::InvalidConfiguration(_))
    ));
    assert!(matches!(
        client
            .resolve_peer("x".repeat(MAX_DEVICE_ID_BYTES + 1).as_str())
            .await,
        Err(RelayError::InvalidConfiguration(_))
    ));
    // 未连接时，合法请求在出站队列阶段返回 NotConnected。
    assert!(matches!(
        client.resolve_peer("device-b").await,
        Err(RelayError::NotConnected)
    ));
}

#[tokio::test]
async fn signal_webrtc_uses_authenticated_control_context() {
    let mut client = RelayControlClient::new(
        "https://relay.example.test".into(),
        "device-a".into(),
        "credential".into(),
        [0u8; 32],
    )
    .expect("client");
    let (outbound, mut frames) = mpsc::channel(1);
    client.outbound = Some(outbound);

    client
        .signal_webrtc(
            "rt-1234",
            "device-b",
            RealtimeSignalKind::Offer,
            1,
            b"sdp-offer",
        )
        .await
        .expect("signal frame");

    let Message::Binary(frame) = frames.recv().await.expect("outbound frame") else {
        panic!("expected binary realtime signal frame");
    };
    let frame = decode_control_frame(&frame).expect("decode signal frame");
    let relay_frame::Kind::RealtimeSignal(signal) = frame.kind.expect("signal kind") else {
        panic!("expected realtime signal kind");
    };
    assert_eq!(signal.target_device_id, "device-b");
}

#[tokio::test]
async fn signal_webrtc_wire_kind_forwards_future_network_signal() {
    let mut client = RelayControlClient::new(
        "https://relay.example.test".into(),
        "device-a".into(),
        "credential".into(),
        [0u8; 32],
    )
    .expect("client");
    let (outbound, mut frames) = mpsc::channel(1);
    client.outbound = Some(outbound);

    client
        .signal_webrtc_wire_kind("rt-1234", "device-b", 6, 2, b"consent")
        .await
        .expect("future signal frame");

    let Message::Binary(frame) = frames.recv().await.expect("outbound frame") else {
        panic!("expected binary realtime signal frame");
    };
    let frame = decode_control_frame(&frame).expect("decode signal frame");
    let relay_frame::Kind::RealtimeSignal(signal) = frame.kind.expect("signal kind") else {
        panic!("expected realtime signal kind");
    };
    assert_eq!(signal.kind, 6);
    assert_eq!(signal.payload, b"consent");
}
