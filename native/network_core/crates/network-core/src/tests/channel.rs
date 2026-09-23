use super::{
    acknowledge_message, application_payload_mode, decode_policy, deliver_pending_message,
    delivery_error, ensure_reliable_message_path, handle_data_message, handle_delivery_ack,
    next_business_ensure_id, policy_code, select_business_path_lease, send_business_frame,
    send_data_message, start_send_message, validate_business_application_policy,
    validate_data_message, ApplicationPayloadMode, ApplicationPolicyError,
    MAX_DELIVERY_MESSAGE_PAYLOAD_BYTES,
};
use crate::connect::{PathRegistry, PeerId, PeerPathManager, CAPABILITY_RELIABLE_MESSAGE};
use crate::connection::{
    test_blocking_generic_route, ConnectionProfile, Route, RouteTopology, RouteTransport,
    TestBlockingGenericRoute,
};
use crate::crypto::CryptoContext;
use crate::delivery::DeliveryError;
use crate::delivery::{
    DedupDecision, DeliveryPolicy, MessageId, OrderedInsertResult, OrderedMessage,
};
use crate::runtime::RuntimeState;
use crate::session::SessionId;
use network_protocol::{
    network_event, AcknowledgeMessageCommand, DataMessage, DeliveryPolicyCode, NetworkErrorCode,
};
use network_protocol::{CommunicationClass, SendMessageCommand};
use network_quic::MAX_CHANNEL_FRAME_BYTES;
use prost::Message;
use std::sync::{atomic::AtomicU16, Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const TEST_TIMEOUT: Duration = Duration::from_secs(2);

#[tokio::test]
async fn message_auto_ensures_without_connect_peer() {
    let peer_id = "message-auto-peer";
    let peer = PeerId::new(peer_id).expect("peer id");
    let registry = Arc::new(PathRegistry::new());
    let manager = Arc::new(Mutex::new(PeerPathManager::new(
        peer,
        Arc::clone(&registry),
    )));
    manager
        .lock()
        .expect("path manager lock")
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("ready message path");
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));
    state
        .peer_path_managers
        .write()
        .await
        .insert(peer_id.to_string(), manager);
    state.allow_routes_for_test(peer_id).await;
    let session_id = SessionId::new();
    state
        .connection_sessions
        .register_pending_session(peer_id, session_id)
        .await
        .expect("pending session");

    let ensured = ensure_reliable_message_path(Arc::clone(&state), peer_id, "message-auto-ensure")
        .await
        .expect("business message path");
    assert_eq!(ensured, session_id);
    assert!(!state
        .peer_supervisors
        .get_or_create(peer_id)
        .expect("supervisor")
        .maintain_connection());
}

#[tokio::test]
async fn message_auto_ensure_keeps_maintain_false() {
    let peer_id = "message-maintain-peer";
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    let supervisor = state
        .peer_supervisors
        .get_or_create(peer_id)
        .expect("supervisor");
    supervisor.admit_inbound(true).expect("admit test peer");
    let intent = supervisor
        .ensure(
            "message-business-ensure",
            CommunicationClass::ReliableMessage,
        )
        .expect("business ensure");
    assert!(matches!(
        intent.completion().await,
        Ok(Ok(crate::connect::PeerState::Online))
    ));
    assert!(!supervisor.maintain_connection());
}

#[test]
fn required_direct_message_is_encrypted() {
    let mut sender = CryptoContext::from_session_root([0x37; 32], true);
    let mut receiver = CryptoContext::from_session_root([0x37; 32], false);
    let payload = b"required-message";
    let envelope = sender
        .encrypt(b"message-aad", payload)
        .expect("encrypt payload");
    assert_ne!(envelope, payload);
    assert!(crate::crypto::is_application_envelope(&envelope));
    assert_eq!(
        receiver.decrypt(b"message-aad", &envelope).unwrap(),
        payload
    );
}

#[test]
fn disabled_direct_message_succeeds_without_crypto_context() {
    let mode = application_payload_mode(
        crate::crypto_handshake::path_handshake::E2eePolicy::Disabled,
        RouteTopology::Direct,
        false,
    )
    .expect("Disabled Direct policy");
    assert_eq!(mode, ApplicationPayloadMode::Plaintext);
}

#[test]
fn required_disabled_mismatch_fails() {
    assert_eq!(
        application_payload_mode(
            crate::crypto_handshake::path_handshake::E2eePolicy::Required,
            RouteTopology::Direct,
            false,
        ),
        Err(ApplicationPolicyError::SecurityPolicyMismatch)
    );
    assert_eq!(
        application_payload_mode(
            crate::crypto_handshake::path_handshake::E2eePolicy::Disabled,
            RouteTopology::Direct,
            true,
        ),
        Err(ApplicationPolicyError::SecurityPolicyMismatch)
    );
}

#[test]
fn relay_disabled_fails_with_relay_requires_e2ee() {
    assert_eq!(
        application_payload_mode(
            crate::crypto_handshake::path_handshake::E2eePolicy::Disabled,
            RouteTopology::Relay,
            false,
        ),
        Err(ApplicationPolicyError::RelayRequiresE2ee)
    );
}

#[tokio::test]
async fn business_selection_uses_peer_manager_and_fresh_lease_after_loss() {
    let peer_id = "lease-peer";
    let peer = PeerId::new(peer_id).expect("peer id");
    let registry = Arc::new(PathRegistry::new());
    let manager = Arc::new(Mutex::new(PeerPathManager::new(
        peer.clone(),
        Arc::clone(&registry),
    )));
    let old_handle = manager
        .lock()
        .expect("path manager lock")
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("old ready path");

    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    state
        .peer_path_managers
        .write()
        .await
        .insert(peer_id.to_string(), Arc::clone(&manager));
    state.allow_routes_for_test(peer_id).await;

    let old_lease = select_business_path_lease(&state, peer_id, CAPABILITY_RELIABLE_MESSAGE)
        .await
        .expect("old lease");
    assert_eq!(old_lease.handle().id(), old_handle.id());

    manager.lock().expect("path manager lock").hard_close();
    assert!(!old_lease.is_active());
    drop(old_lease);

    let fresh_manager = Arc::new(Mutex::new(PeerPathManager::new(
        peer,
        Arc::clone(&registry),
    )));
    let fresh_handle = fresh_manager
        .lock()
        .expect("fresh path manager lock")
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("fresh ready path");
    state
        .peer_path_managers
        .write()
        .await
        .insert(peer_id.to_string(), fresh_manager);
    state.allow_routes_for_test(peer_id).await;

    let fresh_lease = select_business_path_lease(&state, peer_id, CAPABILITY_RELIABLE_MESSAGE)
        .await
        .expect("fresh lease");
    assert_eq!(fresh_lease.handle().id(), fresh_handle.id());
    assert_ne!(fresh_lease.handle().id(), old_handle.id());
}

#[tokio::test]
async fn ordered_next_is_published_before_transport_ack_completes() {
    let peer_id = "ordered-peer";
    let channel_id = "control";
    let (event_tx, mut event_rx) = mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));
    state.allow_routes_for_test(peer_id).await;

    let session_id = match state
        .begin_connect(peer_id, crate::connect::DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        crate::runtime::ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected session decision: {decision:?}"),
    };
    let session_key = session_id.wire_key();

    let TestBlockingGenericRoute {
        handle,
        mut started,
        release,
        mut worker,
    } = test_blocking_generic_route();
    state
        .attach_test_generic_route(peer_id, session_id, handle)
        .await
        .expect("attach test route");

    let now = Instant::now();
    for (sequence, message_id, payload, expected_result) in [
        (
            0,
            MessageId::from_bytes([0; 16]),
            b"ordered-zero".to_vec(),
            OrderedInsertResult::Ready,
        ),
        (
            1,
            MessageId::from_bytes([1; 16]),
            b"ordered-one".to_vec(),
            OrderedInsertResult::Buffered,
        ),
    ] {
        // 投递去重/有序状态按 Peer 业务作用域 key，不使用 session_key。
        assert_eq!(
            state
                .delivery
                .begin_incoming(peer_id, channel_id, message_id, 1, now)
                .await,
            DedupDecision::New
        );
        assert_eq!(
            state
                .delivery
                .accept_ordered(OrderedMessage {
                    peer_id: peer_id.to_string(),
                    session_id: session_key.clone(),
                    channel_id: channel_id.to_string(),
                    message_id,
                    sequence,
                    policy: DeliveryPolicy::SessionBoundOrdered,
                    payload,
                })
                .await,
            expected_result
        );
    }

    let command = AcknowledgeMessageCommand {
        peer_id: peer_id.to_string(),
        session_id: session_key,
        channel_id: channel_id.to_string(),
        message_id: [0; 16].to_vec(),
    };
    let state_for_ack = Arc::clone(&state);
    let mut acknowledge_task =
        tokio::spawn(async move { acknowledge_message(&state_for_ack, command).await });

    let observation = async {
        let event = tokio::time::timeout(TEST_TIMEOUT, event_rx.recv())
            .await
            .map_err(|_| "#1 was not published while ACK transport was blocked")?
            .ok_or("event channel closed before #1 was published")?;
        let expected = matches!(
            event.payload,
            Some(network_event::Payload::ChannelMessage(message))
                if message.peer_id == peer_id
                    && message.channel_id == channel_id
                    && message.sequence == 1
                    && message.message_id == [1; 16].to_vec()
                    && message.payload == b"ordered-one".to_vec()
        );
        if !expected {
            return Err("unexpected event received before ordered #1".to_string());
        }

        tokio::time::timeout(TEST_TIMEOUT, &mut started)
            .await
            .map_err(|_| "ACK transport did not start")?
            .map_err(|_| "ACK transport start signal was dropped")?;
        if acknowledge_task.is_finished() {
            return Err("ACK completed before its release barrier".to_string());
        }
        Ok::<(), String>(())
    }
    .await;

    let _ = release.send(());
    let acknowledge_completed =
        match tokio::time::timeout(TEST_TIMEOUT, &mut acknowledge_task).await {
            Ok(Ok(Ok(()))) => true,
            Ok(Ok(Err(error))) => {
                eprintln!("acknowledge_message returned an error: {error:?}");
                false
            }
            Ok(Err(error)) => {
                eprintln!("acknowledge_message task failed: {error}");
                false
            }
            Err(_) => {
                acknowledge_task.abort();
                let _ = acknowledge_task.await;
                false
            }
        };

    let route_closed = tokio::time::timeout(TEST_TIMEOUT, state.close_transport_path(peer_id))
        .await
        .is_ok();
    let worker_completed = match tokio::time::timeout(TEST_TIMEOUT, &mut worker).await {
        Ok(Ok(())) => true,
        Ok(Err(error)) => {
            eprintln!("test transport worker failed: {error}");
            false
        }
        Err(_) => {
            worker.abort();
            let _ = worker.await;
            false
        }
    };

    assert!(observation.is_ok(), "{observation:?}");
    assert!(
        acknowledge_completed,
        "acknowledge_message did not complete successfully"
    );
    assert!(route_closed, "test route did not close during cleanup");
    assert!(worker_completed, "test transport worker did not terminate");
}

#[tokio::test]
async fn best_effort_delivery_sends_once_over_a_live_generic_route() {
    let peer_id = "best-effort-route-peer";
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));
    state.peers.write().await.insert(
        peer_id.into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [61; 32],
            e2e_public_key: [62; 32],
            e2ee_policy: network_protocol::E2eePolicy::Disabled,
        },
    );
    state.allow_routes_for_test(peer_id).await;
    let session_id = match state
        .begin_connect(peer_id, crate::connect::DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        crate::runtime::ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected session decision: {decision:?}"),
    };
    let crate::connection::TestBlockingGenericRoute {
        handle,
        mut started,
        release,
        mut worker,
    } = test_blocking_generic_route();
    state
        .attach_test_generic_route(peer_id, session_id, handle)
        .await
        .expect("attach live generic route");
    let message = state
        .delivery
        .enqueue(
            peer_id,
            "channel",
            b"best-effort".to_vec(),
            DeliveryPolicy::BestEffort,
            Default::default(),
        )
        .await
        .expect("enqueue best-effort message");

    let send_task = tokio::spawn(deliver_pending_message(
        Arc::clone(&state),
        peer_id.to_string(),
        message,
    ));
    tokio::time::timeout(TEST_TIMEOUT, &mut started)
        .await
        .expect("best-effort send did not reach the route")
        .expect("best-effort route start signal was dropped");
    release.send(()).expect("release best-effort send");
    send_task
        .await
        .expect("best-effort send task should complete");
    state
        .close_transport_path(peer_id)
        .await
        .expect("close best-effort route");
    tokio::time::timeout(TEST_TIMEOUT, &mut worker)
        .await
        .expect("best-effort route worker did not stop")
        .expect("best-effort route worker failed");
}

#[tokio::test]
async fn ordered_inbound_conflicts_fail_the_channel_and_reject_followups() {
    let (event_tx, mut event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    state.peers.write().await.insert(
        "ordered-input-peer".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [63; 32],
            e2e_public_key: [64; 32],
            e2ee_policy: network_protocol::E2eePolicy::Disabled,
        },
    );
    state.allow_routes_for_test("ordered-input-peer").await;

    let message = |message_id: u8, sequence: u64| DataMessage {
        session_id: "ordered-session".into(),
        channel_id: "ordered-channel".into(),
        message_id: vec![message_id; 16],
        sequence,
        recovery_epoch: 1,
        policy: DeliveryPolicyCode::SessionBoundOrdered as i32,
        payload: vec![message_id],
    };
    let first = message(1, 0);
    handle_data_message(&state, "ordered-input-peer", &first.encode_to_vec())
        .await
        .expect("first ordered message should be ready");
    let _ = event_rx.recv().await.expect("first ordered event");

    let buffered = message(2, 1);
    handle_data_message(&state, "ordered-input-peer", &buffered.encode_to_vec())
        .await
        .expect("next ordered message should be buffered");
    assert!(event_rx.try_recv().is_err());

    let conflicting = message(3, 0);
    let error = handle_data_message(&state, "ordered-input-peer", &conflicting.encode_to_vec())
        .await
        .expect_err("conflicting in-flight sequence must be rejected");
    assert!(error.to_string().contains("reorder limits"));

    let expired = state
        .delivery
        .expire_incoming(
            "ordered-input-peer",
            Instant::now() + Duration::from_secs(5 * 60 + 1),
        )
        .await;
    assert_eq!(expired.len(), 2, "ordered timeout should fail the channel");
    let follow_up = message(4, 1);
    let error = handle_data_message(&state, "ordered-input-peer", &follow_up.encode_to_vec())
        .await
        .expect_err("failed ordered channel must reject follow-up frames");
    assert!(error
        .to_string()
        .contains("ordered delivery channel failed"));
}

#[tokio::test]
async fn inbound_delivery_capacity_is_rejected_without_evicting_active_handlers() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    state.peers.write().await.insert(
        "capacity-peer".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [67; 32],
            e2e_public_key: [68; 32],
            e2ee_policy: network_protocol::E2eePolicy::Disabled,
        },
    );
    state.allow_routes_for_test("capacity-peer").await;
    for index in 0..4096u16 {
        assert_eq!(
            state
                .delivery
                .begin_incoming(
                    "capacity-peer",
                    "channel",
                    MessageId::from_bytes(index.to_be_bytes().repeat(8).try_into().unwrap()),
                    1,
                    Instant::now(),
                )
                .await,
            DedupDecision::New
        );
    }
    let message = DataMessage {
        session_id: "session".into(),
        channel_id: "channel".into(),
        message_id: vec![255; 16],
        sequence: 0,
        recovery_epoch: 1,
        policy: DeliveryPolicyCode::Acked as i32,
        payload: b"capacity".to_vec(),
    };
    let error = handle_data_message(&state, "capacity-peer", &message.encode_to_vec())
        .await
        .expect_err("active incoming capacity must fail closed");
    assert!(error.to_string().contains("capacity exceeded"), "{error}");
}

#[tokio::test]
async fn valid_send_message_maps_no_route_and_supervisor_stop_errors() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));
    let command = || SendMessageCommand {
        peer_id: "unreachable-message-peer".into(),
        channel_id: "channel".into(),
        payload: b"payload".to_vec(),
        policy: DeliveryPolicyCode::Acked as i32,
    };
    let no_route = tokio::time::timeout(
        TEST_TIMEOUT,
        start_send_message(Arc::clone(&state), command()),
    )
    .await
    .expect("no-route send should be bounded")
    .expect_err("valid send without a route must fail");
    assert_eq!(no_route.code, NetworkErrorCode::Cancelled as i32);

    let invalid_peer = start_send_message(
        Arc::clone(&state),
        SendMessageCommand {
            peer_id: "x".repeat(129),
            ..command()
        },
    )
    .await
    .expect_err("an invalid peer scope must fail before network work");
    assert_eq!(invalid_peer.code, NetworkErrorCode::Lifecycle as i32);
}

#[tokio::test]
async fn acknowledge_message_maps_missing_transport_to_no_route() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    let message_id = MessageId::from_bytes([77; 16]);
    assert_eq!(
        state
            .delivery
            .begin_incoming(
                "ack-no-route-peer",
                "channel",
                message_id,
                1,
                Instant::now()
            )
            .await,
        DedupDecision::New
    );
    let error = acknowledge_message(
        &state,
        AcknowledgeMessageCommand {
            peer_id: "ack-no-route-peer".into(),
            session_id: "session".into(),
            channel_id: "channel".into(),
            message_id: message_id.to_bytes().to_vec(),
        },
    )
    .await
    .expect_err("ACK without a ready route must fail");
    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
}

#[tokio::test]
async fn relay_policy_validation_maps_disabled_policy_to_typed_error() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    state.peers.write().await.insert(
        "relay-policy-peer".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [65; 32],
            e2e_public_key: [66; 32],
            e2ee_policy: network_protocol::E2eePolicy::Disabled,
        },
    );
    state.allow_routes_for_test("relay-policy-peer").await;
    let session_id = SessionId::new();
    state
        .connection_sessions
        .register_pending_session("relay-policy-peer", session_id)
        .await
        .expect("register relay policy session");
    let mut manager = crate::connect::PeerPathManager::new(
        PeerId::new("relay-policy-peer").expect("peer id"),
        Arc::clone(&state.ready_paths),
    );
    manager
        .publish_ready_with_route(crate::connect::ActiveRoute::relay(None))
        .expect("publish relay path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("relay-policy-peer".into(), Arc::new(Mutex::new(manager)));
    state.allow_routes_for_test("relay-policy-peer").await;

    let error = validate_business_application_policy(&state, "relay-policy-peer", session_id)
        .await
        .expect_err("Disabled policy must be rejected on Relay");
    assert_eq!(error.code, NetworkErrorCode::RelayRequiresE2ee as i32);
}

#[test]
fn channel_wire_validation_and_policy_mapping_cover_all_boundaries() {
    let mut message = DataMessage {
        session_id: "session-a".into(),
        channel_id: "channel-a".into(),
        message_id: vec![0; 16],
        sequence: 1,
        recovery_epoch: 2,
        policy: DeliveryPolicyCode::Acked as i32,
        payload: b"payload".to_vec(),
    };
    assert!(validate_data_message(&message).is_ok());
    message.message_id = vec![0; 15];
    assert!(validate_data_message(&message).is_err());
    message.message_id = vec![0; 16];
    message.session_id.clear();
    assert!(validate_data_message(&message).is_err());
    message.session_id = "session-a".into();
    message.policy = 99;
    assert!(validate_data_message(&message).is_err());
    message.policy = DeliveryPolicyCode::Acked as i32;
    message.payload = vec![0; MAX_CHANNEL_FRAME_BYTES];
    assert!(validate_data_message(&message).is_err());

    for policy in [
        DeliveryPolicy::BestEffort,
        DeliveryPolicy::LatestState,
        DeliveryPolicy::Acked,
        DeliveryPolicy::AckedDeduplicated,
        DeliveryPolicy::SessionBoundOrdered,
        DeliveryPolicy::ResumableTransfer,
    ] {
        assert_eq!(decode_policy(policy_code(policy)), Some(policy));
    }
    assert_eq!(decode_policy(-1), None);
    assert!(next_business_ensure_id("peer-a").starts_with("delivery/peer-a/"));
}

#[test]
fn channel_delivery_errors_map_to_stable_protocol_codes() {
    for error in [
        DeliveryError::QueueFull,
        DeliveryError::PayloadTooLarge,
        DeliveryError::InvalidScope,
        DeliveryError::InvalidRetryPolicy,
    ] {
        assert_eq!(
            delivery_error("peer-a", error).code,
            NetworkErrorCode::InvalidArgument as i32
        );
    }
    for error in [
        DeliveryError::NotFound,
        DeliveryError::Expired,
        DeliveryError::RetryExhausted,
    ] {
        assert_eq!(
            delivery_error("peer-a", error).code,
            NetworkErrorCode::IoError as i32
        );
    }
}

#[tokio::test]
async fn channel_command_boundaries_fail_before_starting_network_work() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));

    for command in [
        SendMessageCommand {
            peer_id: String::new(),
            channel_id: "channel".into(),
            payload: b"payload".to_vec(),
            policy: DeliveryPolicyCode::Acked as i32,
        },
        SendMessageCommand {
            peer_id: "peer-a".into(),
            channel_id: String::new(),
            payload: b"payload".to_vec(),
            policy: DeliveryPolicyCode::Acked as i32,
        },
        SendMessageCommand {
            peer_id: "peer-a".into(),
            channel_id: "channel".into(),
            payload: vec![0; MAX_CHANNEL_FRAME_BYTES],
            policy: DeliveryPolicyCode::Acked as i32,
        },
        SendMessageCommand {
            peer_id: "peer-a".into(),
            channel_id: "channel".into(),
            payload: b"payload".to_vec(),
            policy: 99,
        },
    ] {
        assert!(start_send_message(Arc::clone(&state), command)
            .await
            .is_err());
    }

    for command in [
        AcknowledgeMessageCommand {
            peer_id: "peer-a".into(),
            session_id: "session".into(),
            channel_id: "channel".into(),
            message_id: vec![0; 15],
        },
        AcknowledgeMessageCommand {
            peer_id: String::new(),
            session_id: "session".into(),
            channel_id: "channel".into(),
            message_id: vec![0; 16],
        },
        AcknowledgeMessageCommand {
            peer_id: "peer-a".into(),
            session_id: String::new(),
            channel_id: "channel".into(),
            message_id: vec![0; 16],
        },
        AcknowledgeMessageCommand {
            peer_id: "peer-a".into(),
            session_id: "session".into(),
            channel_id: String::new(),
            message_id: vec![0; 16],
        },
    ] {
        assert!(acknowledge_message(&state, command).await.is_err());
    }

    let missing_ack = acknowledge_message(
        &state,
        AcknowledgeMessageCommand {
            peer_id: "peer-a".into(),
            session_id: "session".into(),
            channel_id: "channel".into(),
            message_id: vec![0; 16],
        },
    )
    .await
    .expect_err("an ACK for an unknown message must fail closed");
    assert_eq!(missing_ack.code, NetworkErrorCode::InvalidArgument as i32);

    let mut ack = network_protocol::DeliveryAck {
        session_id: String::new(),
        message_id: vec![0; 16],
        recovery_epoch: 0,
    };
    assert!(handle_delivery_ack(&state, "peer-a", &ack.encode_to_vec())
        .await
        .is_err());
    ack.session_id = "session".into();
    ack.message_id = vec![0; 15];
    assert!(handle_delivery_ack(&state, "peer-a", &ack.encode_to_vec())
        .await
        .is_err());
    assert!(handle_delivery_ack(&state, "peer-a", b"not-protobuf")
        .await
        .is_err());
    let message = DataMessage {
        session_id: "session".into(),
        channel_id: "channel".into(),
        message_id: vec![0; 16],
        sequence: 0,
        recovery_epoch: 0,
        policy: DeliveryPolicyCode::Acked as i32,
        payload: b"plaintext".to_vec(),
    };
    assert!(
        handle_data_message(&state, "peer-a", &message.encode_to_vec())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn sending_message_reports_cancellation_when_delivery_task_cannot_start() {
    let peer_id = "cancelled-delivery-peer";
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));
    state.peers.write().await.insert(
        peer_id.into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Disabled,
        },
    );
    state.allow_routes_for_test(peer_id).await;
    let manager = Arc::new(Mutex::new(PeerPathManager::new(
        PeerId::new(peer_id).expect("peer id"),
        Arc::clone(&state.ready_paths),
    )));
    manager
        .lock()
        .expect("path manager lock")
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("ready path");
    state
        .peer_path_managers
        .write()
        .await
        .insert(peer_id.into(), manager);
    state.allow_routes_for_test(peer_id).await;
    state
        .connection_sessions
        .register_pending_session(peer_id, SessionId::new())
        .await
        .expect("pending session");
    state.task_supervisor.cancel_root();

    let error = start_send_message(
        Arc::clone(&state),
        SendMessageCommand {
            peer_id: peer_id.into(),
            channel_id: "channel".into(),
            payload: b"payload".to_vec(),
            policy: DeliveryPolicyCode::Acked as i32,
        },
    )
    .await
    .expect_err("a stopping runtime must reject delivery task admission");
    assert_eq!(error.code, NetworkErrorCode::Cancelled as i32);
}

#[tokio::test]
async fn application_policy_validation_requires_a_ready_path_and_matching_crypto() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    let session_id = SessionId::new();
    let no_path = validate_business_application_policy(&state, "peer-a", session_id)
        .await
        .expect_err("business policy cannot be checked without a path");
    assert_eq!(no_path.code, NetworkErrorCode::NoRoute as i32);

    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(
        PeerId::new("peer-a").expect("peer id"),
        Arc::clone(&registry),
    );
    manager
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("ready path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".into(), Arc::new(Mutex::new(manager)));
    state.allow_routes_for_test("peer-a").await;
    let mismatch = validate_business_application_policy(&state, "peer-a", session_id)
        .await
        .expect_err("Required policy needs an application crypto context");
    assert_eq!(
        mismatch.code,
        NetworkErrorCode::SecurityPolicyMismatch as i32
    );
}

#[tokio::test]
async fn business_frame_rejects_wrong_peer_and_inactive_lease() {
    let peer_id = "frame-peer";
    let registry = Arc::new(PathRegistry::new());
    let manager = Arc::new(Mutex::new(PeerPathManager::new(
        PeerId::new(peer_id).expect("peer id"),
        Arc::clone(&registry),
    )));
    manager
        .lock()
        .expect("path manager lock")
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("ready path");
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    state
        .peer_path_managers
        .write()
        .await
        .insert(peer_id.into(), manager.clone());
    state.allow_routes_for_test(peer_id).await;
    let lease = select_business_path_lease(&state, peer_id, CAPABILITY_RELIABLE_MESSAGE)
        .await
        .expect("active lease");
    assert!(send_business_frame(
        &state,
        "other-peer",
        &lease,
        "token",
        crate::connection::GenericFrameKind::DataMessage,
        b"payload",
    )
    .await
    .is_err());
    manager.lock().expect("path manager lock").hard_close();
    assert!(send_business_frame(
        &state,
        peer_id,
        &lease,
        "token",
        crate::connection::GenericFrameKind::DataMessage,
        b"payload",
    )
    .await
    .is_err());
}

#[tokio::test]
async fn inbound_plaintext_delivery_emits_once_and_deduplicates_replays() {
    let (event_tx, mut event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    state.peers.write().await.insert(
        "peer-a".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Disabled,
        },
    );
    state.allow_routes_for_test("peer-a").await;

    let best_effort = DataMessage {
        session_id: "session-a".into(),
        channel_id: "channel-a".into(),
        message_id: vec![1; 16],
        sequence: 0,
        recovery_epoch: 0,
        policy: DeliveryPolicyCode::BestEffort as i32,
        payload: b"plaintext".to_vec(),
    };
    handle_data_message(&state, "peer-a", &best_effort.encode_to_vec())
        .await
        .expect("Disabled Direct plaintext should be delivered");
    let event = event_rx.recv().await.expect("plaintext delivery event");
    assert!(matches!(
        event.payload,
        Some(network_event::Payload::ChannelMessage(message))
            if message.message_id == vec![1; 16] && message.payload == b"plaintext"
    ));

    let mut ciphertext = best_effort.clone();
    ciphertext.message_id = vec![2; 16];
    ciphertext.payload = b"SME1ciphertext".to_vec();
    assert!(
        handle_data_message(&state, "peer-a", &ciphertext.encode_to_vec())
            .await
            .is_err()
    );

    let mut acked = best_effort;
    acked.message_id = vec![3; 16];
    acked.policy = DeliveryPolicyCode::Acked as i32;
    handle_data_message(&state, "peer-a", &acked.encode_to_vec())
        .await
        .expect("first Acked message should be accepted");
    handle_data_message(&state, "peer-a", &acked.encode_to_vec())
        .await
        .expect("in-flight Acked replay should be ignored");
    let event = event_rx.recv().await.expect("acked delivery event");
    assert!(matches!(
        event.payload,
        Some(network_event::Payload::ChannelMessage(message))
            if message.message_id == vec![3; 16]
    ));
    assert!(event_rx.try_recv().is_err());
    assert!(matches!(
        state
            .delivery
            .complete_incoming_checked("peer-a", "channel-a", MessageId::from_bytes([3; 16]),)
            .await,
        Ok(Some(_))
    ));
    assert!(
        handle_data_message(&state, "peer-a", &acked.encode_to_vec())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn required_inbound_messages_decrypt_and_reject_missing_application_e2ee() {
    let (event_tx, mut event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    state.peers.write().await.insert(
        "peer-a".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test("peer-a").await;
    let root = [0x41; 32];
    state
        .install_crypto_material(
            "peer-a",
            "session-a",
            &crate::crypto_handshake::SessionCryptoMaterial {
                root_key: root,
                local_session_binding: "session-a".into(),
                remote_session_binding: "session-a".into(),
                initiator: false,
                e2ee_policy: crate::crypto_handshake::path_handshake::E2eePolicy::Required,
                path_security: crate::crypto_handshake::path_handshake::PathSecurity::E2ee,
            },
        )
        .expect("install receiving crypto context");

    let mut missing = DataMessage {
        session_id: "session-a".into(),
        channel_id: "channel-a".into(),
        message_id: vec![9; 16],
        sequence: 0,
        recovery_epoch: 0,
        policy: DeliveryPolicyCode::BestEffort as i32,
        payload: b"plaintext is not allowed".to_vec(),
    };
    let error = handle_data_message(&state, "peer-a", &missing.encode_to_vec())
        .await
        .expect_err("Required policy must reject an unencrypted application payload");
    assert!(error.to_string().contains("E2EE payload"));

    let mut sender = CryptoContext::from_session_root(root, true);
    let base_aad = crate::crypto::data_message_aad(
        &missing.session_id,
        &missing.channel_id,
        &missing.message_id,
        missing.sequence,
        missing.recovery_epoch,
        missing.policy,
    );
    missing.payload = sender
        .encrypt(&base_aad, b"encrypted best effort")
        .expect("encrypt best-effort payload");
    handle_data_message(&state, "peer-a", &missing.encode_to_vec())
        .await
        .expect("Required best-effort payload should decrypt");
    let event = event_rx.recv().await.expect("best-effort event");
    assert!(matches!(
        event.payload,
        Some(network_event::Payload::ChannelMessage(message))
            if message.payload == b"encrypted best effort"
    ));

    let mut acked = DataMessage {
        session_id: "session-a".into(),
        channel_id: "channel-a".into(),
        message_id: vec![10; 16],
        sequence: 1,
        recovery_epoch: 0,
        policy: DeliveryPolicyCode::Acked as i32,
        payload: Vec::new(),
    };
    let acked_aad = crate::crypto::data_message_aad(
        &acked.session_id,
        &acked.channel_id,
        &acked.message_id,
        acked.sequence,
        acked.recovery_epoch,
        acked.policy,
    );
    acked.payload = sender
        .encrypt(&acked_aad, b"encrypted acked")
        .expect("encrypt acked payload");
    handle_data_message(&state, "peer-a", &acked.encode_to_vec())
        .await
        .expect("Required Acked payload should decrypt");
    let event = event_rx.recv().await.expect("acked event");
    assert!(matches!(
        event.payload,
        Some(network_event::Payload::ChannelMessage(message))
            if message.payload == b"encrypted acked"
    ));
}

#[tokio::test]
async fn delivery_send_rejects_a_replaced_connection_session_before_encoding() {
    let peer_id = "session-replaced-peer";
    let registry = Arc::new(PathRegistry::new());
    let manager = Arc::new(Mutex::new(PeerPathManager::new(
        PeerId::new(peer_id).expect("peer id"),
        Arc::clone(&registry),
    )));
    manager
        .lock()
        .expect("path manager lock")
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("ready path");
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    state
        .peer_path_managers
        .write()
        .await
        .insert(peer_id.into(), manager);
    state.allow_routes_for_test(peer_id).await;
    let lease = select_business_path_lease(&state, peer_id, CAPABILITY_RELIABLE_MESSAGE)
        .await
        .expect("path lease");
    let message = state
        .delivery
        .enqueue(
            peer_id,
            "channel",
            b"payload".to_vec(),
            DeliveryPolicy::Acked,
            Default::default(),
        )
        .await
        .expect("queue message");
    let attempt = state
        .delivery
        .begin_send_for_peer(peer_id, message.message_id, Instant::now())
        .await
        .expect("begin send")
        .expect("queued message");
    let error = send_data_message(&state, peer_id, SessionId::new(), &lease, &attempt.message)
        .await
        .expect_err("a replaced connection session must fail before encoding");
    assert!(error.to_string().contains("session changed"));
}

#[tokio::test]
async fn delivery_send_rejects_an_encoded_message_over_the_frame_limit() {
    let peer_id = "oversized-delivery-peer";
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    state.peers.write().await.insert(
        peer_id.into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Disabled,
        },
    );
    state.allow_routes_for_test(peer_id).await;
    let manager = Arc::new(Mutex::new(PeerPathManager::new(
        PeerId::new(peer_id).expect("peer id"),
        Arc::clone(&state.ready_paths),
    )));
    manager
        .lock()
        .expect("path manager lock")
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("ready path");
    state
        .peer_path_managers
        .write()
        .await
        .insert(peer_id.into(), manager);
    state.allow_routes_for_test(peer_id).await;
    let session_id = SessionId::new();
    state
        .connection_sessions
        .register_pending_session(peer_id, session_id)
        .await
        .expect("pending session");
    let lease = select_business_path_lease(&state, peer_id, CAPABILITY_RELIABLE_MESSAGE)
        .await
        .expect("path lease");
    let message = state
        .delivery
        .enqueue(
            peer_id,
            "channel",
            vec![0; MAX_DELIVERY_MESSAGE_PAYLOAD_BYTES],
            DeliveryPolicy::Acked,
            Default::default(),
        )
        .await
        .expect("queue oversized wire message");
    let mut attempt = state
        .delivery
        .begin_send_for_peer(peer_id, message.message_id, Instant::now())
        .await
        .expect("begin send")
        .expect("queued message");
    attempt.message.payload = vec![0; MAX_CHANNEL_FRAME_BYTES];

    let error = send_data_message(&state, peer_id, session_id, &lease, &attempt.message)
        .await
        .expect_err("encoded message must be rejected before transport");
    assert!(error.to_string().contains("frame limit"), "{error}");
}
