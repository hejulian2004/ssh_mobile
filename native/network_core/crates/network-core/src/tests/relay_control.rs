use super::*;

use crate::connect::presence::PresenceHint;
use crate::discovery::LocalDiscoveryManager;
use network_protocol::NetworkEvent;
use network_relay::v2::{
    CandidateBundle, ConnectivityOffer, ControlEvent, PeerAvailableHint, PeerPresenceHint,
    PeerUnavailableHint, PresenceHintSnapshot, RealtimeSignal, RuntimeEpoch,
};
use std::sync::atomic::AtomicU16;
use tokio::sync::mpsc;

fn state() -> Arc<RuntimeState> {
    let (event_tx, _event_rx) = mpsc::unbounded_channel::<NetworkEvent>();
    Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))))
}

fn control_client() -> Arc<RelayControlClient> {
    Arc::new(
        RelayControlClient::new(
            "ws://127.0.0.1:9".into(),
            "device-a".into(),
            "credential".into(),
            [0u8; 32],
        )
        .expect("valid unconnected control client"),
    )
}

#[test]
fn connectivity_offer_candidates_accepts_only_valid_advertisements() {
    let candidate = network_nat::Candidate::new(
        "192.168.1.20:41000".parse().unwrap(),
        network_nat::CandidateKind::Lan,
        "wifi".into(),
    )
    .with_generation(2)
    .advertisement();
    let valid = serde_json::to_vec(&candidate).unwrap();
    let mut invalid = valid.clone();
    invalid[0] = b'!';
    let offer = ConnectivityOffer {
        initiator_snapshot: Some(network_relay::v2::DiscoverySnapshot {
            candidate_bundle: Some(CandidateBundle {
                candidates: vec![valid, invalid, vec![0xff]],
            }),
            ..Default::default()
        }),
        ..Default::default()
    };
    let candidates = connectivity_offer_candidates(&offer);
    assert_eq!(candidates.len(), 1);
    assert_eq!(
        candidates[0].endpoint,
        "192.168.1.20:41000"
            .parse::<std::net::SocketAddr>()
            .unwrap()
    );

    assert!(connectivity_offer_candidates(&ConnectivityOffer::default()).is_empty());
}

#[tokio::test]
async fn local_discovery_tuple_has_safe_defaults_and_reads_manager_snapshot() {
    let state = state();
    assert_eq!(
        local_discovery_tuple(&state).await,
        (RuntimeEpoch { high: 0, low: 0 }, 1, None)
    );

    let manager = LocalDiscoveryManager::with_epoch(9, 10, 4);
    *state.local_discovery.write().await = Some(Arc::new(manager));
    let (epoch, revision, snapshot) = local_discovery_tuple(&state).await;
    assert_eq!(epoch, RuntimeEpoch { high: 9, low: 10 });
    assert_eq!(revision, 4);
    assert_eq!(snapshot.expect("manager snapshot").revision, 4);
}

#[tokio::test]
async fn control_events_update_presence_cache_and_emit_typed_presence_events() {
    let (event_tx, mut event_rx) = mpsc::unbounded_channel::<NetworkEvent>();
    let state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));
    state.presence_hints.mark_online("stale-peer", 1);
    let control = control_client();
    let (events_tx, events_rx) = mpsc::channel(8);
    let consumer_state = Arc::clone(&state);
    let consumer = tokio::spawn(async move {
        consume_control_events(consumer_state, control, events_rx).await;
    });

    events_tx
        .send(ControlEvent::PresenceHintSnapshot(PresenceHintSnapshot {
            peers: vec![
                PeerPresenceHint {
                    device_id: "peer-a".into(),
                    online: true,
                    runtime_epoch: Some(RuntimeEpoch { high: 2, low: 3 }),
                    revision: 7,
                },
                PeerPresenceHint {
                    device_id: "offline-peer".into(),
                    online: false,
                    runtime_epoch: None,
                    revision: 0,
                },
            ],
            published_at_ms: 1,
        }))
        .await
        .unwrap();
    events_tx
        .send(ControlEvent::PeerAvailableHint(PeerAvailableHint {
            device_id: "peer-a".into(),
            runtime_epoch: None,
            revision: 0,
        }))
        .await
        .unwrap();
    events_tx
        .send(ControlEvent::PeerUnavailableHint(PeerUnavailableHint {
            device_id: "peer-a".into(),
            reason: "offline".into(),
        }))
        .await
        .unwrap();
    events_tx
        .send(ControlEvent::ProtocolError(
            network_relay::v2::ProtocolError {
                request_id: 1,
                attempt_id: "attempt".into(),
                code: 13,
                message: "ignored event".into(),
            },
        ))
        .await
        .unwrap();
    drop(events_tx);
    consumer.await.unwrap();

    assert_eq!(
        state.presence_hints.get("peer-a"),
        Some(PresenceHint::new(false, 0))
    );
    assert!(state.presence_hints.get("stale-peer").is_none());
    let mut events = Vec::new();
    while let Ok(event) = event_rx.try_recv() {
        events.push(event);
    }
    assert!(events.iter().any(|event| matches!(
        event.payload,
        Some(network_protocol::network_event::Payload::PeerPresenceSnapshot(_))
    )));
    assert!(
        events
            .iter()
            .filter(|event| matches!(
                event.payload,
                Some(network_protocol::network_event::Payload::PeerPresenceChanged(_))
            ))
            .count()
            >= 3
    );
}

#[tokio::test]
async fn control_helpers_disconnect_without_leaving_config_or_reconnect_tasks() {
    let (event_tx, mut event_rx) = mpsc::unbounded_channel::<NetworkEvent>();
    let disconnect_state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));
    *disconnect_state.relay.config.write().await = Some(RelayReconnectConfig {
        relay_url: "ws://127.0.0.1:9".into(),
        credential: "credential".into(),
        signing_seed: [0u8; 32],
    });
    disconnect_relay(&disconnect_state)
        .await
        .expect("disconnect is idempotent");
    assert!(disconnect_state.relay.config.read().await.is_none());
    let event = event_rx.recv().await.expect("disconnect event");
    assert!(matches!(
        event.payload,
        Some(network_protocol::network_event::Payload::RelayStateChanged(change))
            if change.state == network_protocol::RelayConnectionState::Disconnected as i32
    ));

    let state2 = state();
    schedule_relay_reconnect(Arc::clone(&state2));
    assert!(state2
        .relay
        .reconnect_active
        .load(std::sync::atomic::Ordering::Acquire));
    stop_relay_reconnect_task(&state2).await;
    assert!(!state2
        .relay
        .reconnect_active
        .load(std::sync::atomic::Ordering::Acquire));
    assert!(state2.relay.reconnect_task.lock().unwrap().is_none());
}

#[tokio::test]
async fn reconnect_loop_stops_when_configuration_identity_or_control_is_unavailable() {
    let stopping = state();
    stopping.task_supervisor.cancel_root();
    schedule_relay_reconnect(Arc::clone(&stopping));
    assert!(!stopping
        .relay
        .reconnect_active
        .load(std::sync::atomic::Ordering::Acquire));

    let no_config = state();
    schedule_relay_reconnect(Arc::clone(&no_config));
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert!(!no_config
        .relay
        .reconnect_active
        .load(std::sync::atomic::Ordering::Acquire));

    let no_identity = state();
    *no_identity.relay.config.write().await = Some(RelayReconnectConfig {
        relay_url: "ws://127.0.0.1:9".into(),
        credential: "credential".into(),
        signing_seed: [0; 32],
    });
    schedule_relay_reconnect(Arc::clone(&no_identity));
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert!(!no_identity
        .relay
        .reconnect_active
        .load(std::sync::atomic::Ordering::Acquire));

    let control_present = state();
    *control_present.relay.config.write().await = Some(RelayReconnectConfig {
        relay_url: "ws://127.0.0.1:9".into(),
        credential: "credential".into(),
        signing_seed: [0; 32],
    });
    *control_present.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys("device-a".into(), [1; 32], [2; 32]),
    ));
    *control_present.relay.control.write().await = Some(control_client());
    schedule_relay_reconnect(Arc::clone(&control_present));
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert!(!control_present
        .relay
        .reconnect_active
        .load(std::sync::atomic::Ordering::Acquire));
}

#[tokio::test]
async fn control_consumer_ignores_unconfigured_offer_reservation_and_signal() {
    let state = state();
    let control = control_client();
    let (events_tx, events_rx) = mpsc::channel(8);
    let consumer_state = Arc::clone(&state);
    let consumer = tokio::spawn(async move {
        consume_control_events(consumer_state, control, events_rx).await;
    });
    events_tx
        .send(ControlEvent::ConnectivityOffer(ConnectivityOffer {
            attempt_id: "attempt".into(),
            initiator_device_id: "peer-a".into(),
            ..Default::default()
        }))
        .await
        .unwrap();
    events_tx
        .send(ControlEvent::IncomingRelayReservation(
            network_relay::v2::IncomingRelayReservation {
                attempt_id: "attempt".into(),
                reservation_id: "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
                initiator_device_id: "peer-a".into(),
                relay_data_endpoint: "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d"
                    .into(),
                expires_at_ms: 0,
                local_token: vec![0; 32],
            },
        ))
        .await
        .unwrap();
    events_tx
        .send(ControlEvent::RealtimeSignal(RealtimeSignal {
            realtime_id: "missing".into(),
            target_device_id: "peer-a".into(),
            payload: vec![0xff],
            ..Default::default()
        }))
        .await
        .unwrap();
    drop(events_tx);
    consumer.await.unwrap();
}

#[tokio::test]
async fn relay_configuration_and_setup_fail_closed_before_claiming_a_control_route() {
    let (event_tx, mut event_rx) = mpsc::unbounded_channel::<NetworkEvent>();
    let state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));
    let missing_identity = configure_relay_for_state(
        Arc::clone(&state),
        network_protocol::ConfigureRelayCommand {
            relay_url: "ws://127.0.0.1:9".into(),
            relay_credential: "credential".into(),
            relay_signing_seed: vec![0; 32],
        },
    )
    .await
    .expect_err("Relay requires an initialized runtime identity");
    assert_eq!(
        missing_identity.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    *state.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys("device-a".into(), [1; 32], [2; 32]),
    ));
    let invalid_seed = configure_relay_for_state(
        Arc::clone(&state),
        network_protocol::ConfigureRelayCommand {
            relay_url: "ws://127.0.0.1:9".into(),
            relay_credential: "credential".into(),
            relay_signing_seed: vec![0; 31],
        },
    )
    .await
    .expect_err("Relay signing seed length must be checked");
    assert_eq!(invalid_seed.code, NetworkErrorCode::InvalidArgument as i32);

    let unreachable = configure_relay_for_state(
        Arc::clone(&state),
        network_protocol::ConfigureRelayCommand {
            relay_url: "ws://127.0.0.1:9".into(),
            relay_credential: "credential".into(),
            relay_signing_seed: vec![0; 32],
        },
    )
    .await
    .expect_err("unreachable Relay control must fail closed");
    assert_eq!(unreachable.code, NetworkErrorCode::RelayError as i32);
    assert!(event_rx.try_recv().is_ok());
    stop_relay_reconnect_task(&state).await;
}

#[tokio::test]
async fn relay_control_setup_rejects_invalid_url_before_opening_socket() {
    let state = state();
    let config = RelayReconnectConfig {
        relay_url: "not-a-relay-url".into(),
        credential: "credential".into(),
        signing_seed: [0; 32],
    };
    let error = setup_v2_control_plane(&state, "device-a", &config)
        .await
        .expect_err("invalid Relay URL must fail before connect");
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);
    assert!(state.relay.control.read().await.is_none());
}

#[tokio::test]
async fn relay_cache_invalidation_is_noop_for_equal_or_unknown_epochs() {
    let state = state();
    clear_remote_candidate_cache_if_ready_ttl_changed(
        &state,
        Some(Duration::from_secs(60)),
        Some(Duration::from_secs(60)),
    )
    .await;
    invalidate_remote_candidate_cache_for_epoch(
        &state,
        "missing-peer",
        &RuntimeEpoch { high: 0, low: 0 },
    )
    .await;
    invalidate_remote_candidate_cache_for_epoch(
        &state,
        "missing-peer",
        &RuntimeEpoch { high: 1, low: 1 },
    )
    .await;
    assert!(state.remote_candidate_cache.read().await.is_empty());
}

#[tokio::test]
async fn configured_control_consumer_handles_offer_reservation_and_signal_failures() {
    let state = state();
    *state.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys("device-a".into(), [3; 32], [4; 32]),
    ));
    *state.relay.config.write().await = Some(RelayReconnectConfig {
        relay_url: "ws://127.0.0.1:9".into(),
        credential: "credential".into(),
        signing_seed: [0; 32],
    });
    let control = control_client();
    let (events_tx, events_rx) = mpsc::channel(8);
    let consumer = tokio::spawn(consume_control_events(
        Arc::clone(&state),
        control,
        events_rx,
    ));
    events_tx
        .send(ControlEvent::ConnectivityOffer(ConnectivityOffer {
            attempt_id: "attempt".into(),
            initiator_device_id: "unconfigured-peer".into(),
            initiator_runtime_epoch: Some(RuntimeEpoch { high: 1, low: 1 }),
            initiator_revision: 1,
            ..Default::default()
        }))
        .await
        .unwrap();
    events_tx
        .send(ControlEvent::IncomingRelayReservation(
            network_relay::v2::IncomingRelayReservation {
                attempt_id: "attempt".into(),
                reservation_id: "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
                initiator_device_id: "peer-a".into(),
                relay_data_endpoint: "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d"
                    .into(),
                expires_at_ms: 0,
                local_token: vec![0; 32],
            },
        ))
        .await
        .unwrap();
    events_tx
        .send(ControlEvent::RealtimeSignal(RealtimeSignal {
            realtime_id: "missing".into(),
            target_device_id: "peer-a".into(),
            kind: network_relay::v2::RealtimeSignalKind::Offer as i32,
            revision: 1,
            payload: b"offer".to_vec(),
            ..Default::default()
        }))
        .await
        .unwrap();
    drop(events_tx);
    consumer.await.unwrap();
    state.task_supervisor.shutdown().await;
}

#[tokio::test]
async fn control_consumer_reconnects_after_hint_without_epoch_and_disconnect() {
    let state = state();
    let control = control_client();
    let (events_tx, events_rx) = mpsc::channel(4);
    let consumer = tokio::spawn(consume_control_events(
        Arc::clone(&state),
        control,
        events_rx,
    ));
    events_tx
        .send(ControlEvent::PeerAvailableHint(PeerAvailableHint {
            device_id: "peer-a".into(),
            runtime_epoch: None,
            revision: 2,
        }))
        .await
        .unwrap();
    events_tx
        .send(ControlEvent::Disconnected {
            reason: "test disconnect".into(),
        })
        .await
        .unwrap();
    consumer.await.unwrap();
    assert!(state.relay.control.read().await.is_none());
    assert!(state
        .relay
        .reconnect_active
        .load(std::sync::atomic::Ordering::Acquire));
    stop_relay_reconnect_task(&state).await;
}

#[tokio::test]
async fn responder_connectivity_checks_stop_before_endpoint_is_available() {
    let state = state();
    state.peers.write().await.insert(
        "peer-a".into(),
        PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test("peer-a".into()).await;
    spawn_responder_connectivity_checks(
        Arc::clone(&state),
        ConnectivityOffer {
            attempt_id: "attempt-no-endpoint".into(),
            initiator_device_id: "peer-a".into(),
            ..Default::default()
        },
    );
    tokio::time::sleep(Duration::from_millis(10)).await;
    state.task_supervisor.shutdown().await;
}

#[tokio::test]
async fn responder_connectivity_checks_fail_closed_for_empty_offer() {
    let state = state();
    let endpoint = network_quic::QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("responder endpoint address"),
        Arc::new(network_nat::PathManager::new()),
    )
    .expect("responder endpoint")
    .endpoint;
    let endpoint_for_cleanup = endpoint.clone();
    *state.lifecycle.endpoint.write().await = Some(endpoint);
    *state.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [5u8; 32],
            [6u8; 32],
        ),
    ));
    state.peers.write().await.insert(
        "peer-a".into(),
        PeerConfig {
            endpoint: None,
            identity_public_key: [7u8; 32],
            e2e_public_key: [8u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test("peer-a".into()).await;

    spawn_responder_connectivity_checks(
        Arc::clone(&state),
        ConnectivityOffer {
            attempt_id: "empty-offer".into(),
            initiator_device_id: "peer-a".into(),
            ..Default::default()
        },
    );
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if state.task_supervisor.active_count() == 0 {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("empty responder offer should finish without a live task");
    assert_eq!(state.task_supervisor.active_count(), 0);
    endpoint_for_cleanup.close(quinn::VarInt::from_u32(0), b"test complete");
}
