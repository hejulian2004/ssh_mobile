// Shared fixtures and tests for the connectivity attempt.

use super::*;
use crate::connect::{PeerId, PeerPathManager, DEFAULT_CONNECTION_CAPABILITY};
use crate::connection::{ConnectionProfile, Route, RouteTransport};
use network_nat::PathManager;
use network_relay::v2::ResolveStatus;
use std::time::{Duration, Instant};
use tracing::Instrument;

/// Captures the existing Direct-failure diagnostic from the test thread
/// without adding an observer or callback to the production coordinator.
struct StageCLogState {
    direct_failed_at: std::sync::Mutex<Option<Instant>>,
    expected_attempt_id: Arc<std::sync::Mutex<Option<String>>>,
}

impl StageCLogState {
    fn new() -> Self {
        Self {
            direct_failed_at: std::sync::Mutex::new(None),
            expected_attempt_id: Arc::new(std::sync::Mutex::new(None)),
        }
    }
}

struct StageCLogCapture {
    state: Arc<StageCLogState>,
}

impl StageCLogCapture {
    fn new(state: Arc<StageCLogState>) -> Self {
        Self { state }
    }
}

struct StageCEventVisitor {
    message: Option<String>,
    attempt_id: Option<String>,
}

impl tracing::field::Visit for StageCEventVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.message = Some(format!("{value:?}"));
        } else if field.name() == "attempt_id" {
            self.attempt_id = Some(format!("{value:?}").trim_matches('"').to_string());
        }
    }
}

impl tracing::Subscriber for StageCLogCapture {
    fn enabled(&self, _metadata: &tracing::Metadata<'_>) -> bool {
        true
    }

    fn new_span(&self, _span: &tracing::span::Attributes<'_>) -> tracing::span::Id {
        tracing::span::Id::from_u64(1)
    }

    fn record(&self, _span: &tracing::span::Id, _values: &tracing::span::Record<'_>) {}

    fn record_follows_from(&self, _span: &tracing::span::Id, _follows: &tracing::span::Id) {}

    fn event(&self, event: &tracing::Event<'_>) {
        let mut visitor = StageCEventVisitor {
            message: None,
            attempt_id: None,
        };
        event.record(&mut visitor);
        let expected_attempt_id = self
            .state
            .expected_attempt_id
            .lock()
            .expect("Stage C attempt id lock")
            .clone();
        if expected_attempt_id
            .as_deref()
            .zip(visitor.attempt_id.as_deref())
            .is_some_and(|(expected, actual)| expected == actual)
            && visitor.message.as_deref().is_some_and(|message| {
                message.contains("direct first failed; falling back to relay")
            })
        {
            let mut timestamp = self
                .state
                .direct_failed_at
                .lock()
                .expect("Direct failure timestamp lock");
            if timestamp.is_none() {
                *timestamp = Some(Instant::now());
            }
        }
    }

    fn enter(&self, _span: &tracing::span::Id) {}

    fn exit(&self, _span: &tracing::span::Id) {}
}

/// 构造一个可跑通 `connect_with_class` 前段（配置校验 + Resolve + try_reuse）
/// 的 RuntimeState：配置了 endpoint/identity/peer，并注入权威 READY mock。
async fn configured_reuse_state() -> (
    Arc<RuntimeState>,
    tokio::sync::mpsc::UnboundedReceiver<network_protocol::NetworkEvent>,
    Arc<StubControl>,
) {
    let (event_tx, event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let path_manager = Arc::new(PathManager::new());
    let manager = network_quic::QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("test bind address"),
        path_manager,
    )
    .expect("create test QUIC endpoint");
    *state.lifecycle.endpoint.write().await = Some(manager.endpoint);
    *state.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [21u8; 32],
            [31u8; 32],
        ),
    ));
    state.peers.write().await.insert(
        "peer-b".to_string(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [7u8; 32],
            e2e_public_key: [8u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test("peer-b").await;
    state
        .peer_route_authorizations
        .write()
        .await
        .insert(
            "peer-b".to_string(),
            crate::runtime::PeerRouteAuthorization {
                direct: true,
                relay: true,
            },
        );
    let control = StubControl::new(
        ResolveStatus::Ready,
        Some(DiscoverySnapshot {
            runtime_epoch: None,
            revision: 1,
            transport_capabilities: Vec::new(),
            candidate_bundle: None,
            published_at_ms: 0,
        }),
    );
    *state.relay.control.write().await = Some(control.clone());
    (state, event_rx, control)
}

/// A valid READY snapshot whose only advertised Direct candidate points
/// at a closed loopback port.  The bounded Direct race therefore fails
/// without depending on a live peer, while the snapshot still retains the
/// authoritative epoch/revision and RelayData capability needed to
/// exercise the Stage C eligibility boundary.
fn stage_c_ready_unreachable_direct_snapshot() -> DiscoverySnapshot {
    let candidate = Candidate::new(
        "127.0.0.1:9".parse().expect("direct candidate endpoint"),
        CandidateKind::Lan,
        "stage-c-direct".into(),
    )
    .with_generation(1);
    DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch {
            high: 101,
            low: 202,
        }),
        revision: 1,
        transport_capabilities: vec![
            network_relay::v2::TransportCapability::Quic as i32,
            network_relay::v2::TransportCapability::RelayData as i32,
        ],
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![serde_json::to_vec(&candidate.advertisement())
                .expect("direct candidate advertisement")],
        }),
        published_at_ms: 0,
    }
}

fn stage_c_ready_relay_only_snapshot() -> DiscoverySnapshot {
    let candidate = Candidate::new(
        "127.0.0.1:9".parse().expect("relay candidate endpoint"),
        CandidateKind::Relay,
        "stage-c-relay".into(),
    )
    .with_generation(1);
    DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch {
            high: 101,
            low: 202,
        }),
        revision: 1,
        transport_capabilities: vec![network_relay::v2::TransportCapability::RelayData as i32],
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![serde_json::to_vec(&candidate.advertisement())
                .expect("relay candidate advertisement")],
        }),
        published_at_ms: 0,
    }
}

async fn install_ready_direct_path(state: &RuntimeState, peer_id: &str, transport: RouteTransport) {
    let mut manager = PeerPathManager::new(
        PeerId::new(peer_id).expect("peer id"),
        Arc::clone(&state.ready_paths),
    );
    manager
        .publish_ready(ConnectionProfile::new(Route::direct(transport)))
        .expect("publish ready direct path");
    state.peer_path_managers.write().await.insert(
        peer_id.to_string(),
        Arc::new(std::sync::Mutex::new(manager)),
    );
    state.allow_routes_for_test(peer_id).await;
}

#[test]
fn stage_machine_follows_the_design_skeleton() {
    // 状态机只允许设计定义的阶段；不允许 RECONNECTING / DIRECT_UPGRADING /
    // PATH_REPAIRING（§11）。
    let stages = [
        ConnectivityAttemptState::Idle,
        ConnectivityAttemptState::Resolving,
        ConnectivityAttemptState::Resolved,
        ConnectivityAttemptState::Coordinating,
        ConnectivityAttemptState::DirectConnecting,
        ConnectivityAttemptState::ConnectedDirect,
        ConnectivityAttemptState::DirectFailed,
        ConnectivityAttemptState::RelayReserving,
        ConnectivityAttemptState::RelayConnecting,
        ConnectivityAttemptState::ConnectedRelay,
        ConnectivityAttemptState::Failed,
    ];
    for stage in stages {
        // 编译期保证不存在缺失的变体。
        match stage {
            ConnectivityAttemptState::Idle
            | ConnectivityAttemptState::Resolving
            | ConnectivityAttemptState::Resolved
            | ConnectivityAttemptState::Coordinating
            | ConnectivityAttemptState::DirectConnecting
            | ConnectivityAttemptState::ConnectedDirect
            | ConnectivityAttemptState::DirectFailed
            | ConnectivityAttemptState::RelayReserving
            | ConnectivityAttemptState::RelayConnecting
            | ConnectivityAttemptState::ConnectedRelay
            | ConnectivityAttemptState::Failed => {}
        }
    }
}

#[test]
fn direct_window_constant_is_four_seconds() {
    assert_eq!(DIRECT_CONNECT_WINDOW, Duration::from_millis(4000));
}

#[test]
fn coordinator_stage_setter_round_trips_every_terminal_and_live_state() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let coordinator = ConnectivityAttemptCoordinator::new(state);
    for expected in [
        ConnectivityAttemptState::Idle,
        ConnectivityAttemptState::Resolving,
        ConnectivityAttemptState::Resolved,
        ConnectivityAttemptState::Coordinating,
        ConnectivityAttemptState::DirectConnecting,
        ConnectivityAttemptState::ConnectedDirect,
        ConnectivityAttemptState::DirectFailed,
        ConnectivityAttemptState::RelayReserving,
        ConnectivityAttemptState::RelayConnecting,
        ConnectivityAttemptState::ConnectedRelay,
        ConnectivityAttemptState::Failed,
    ] {
        coordinator.set_stage(expected);
        assert_eq!(coordinator.stage(), expected);
    }
}

#[tokio::test]
async fn session_cleanup_guard_only_retires_an_armed_exact_session() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let session_id = match state
        .begin_connect("peer-a", DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected session decision: {decision:?}"),
    };
    {
        let mut guard = SessionCleanupGuard::new(Arc::clone(&state), "peer-a", session_id);
        guard.disarm();
    }
    assert_eq!(
        state.connection_sessions.current_session_id("peer-a").await,
        Some(session_id)
    );
    {
        let _guard = SessionCleanupGuard::new(Arc::clone(&state), "peer-a", session_id);
    }
    tokio::task::yield_now().await;
    assert!(state
        .connection_sessions
        .current_session_id("peer-a")
        .await
        .is_none());
}

#[tokio::test]
async fn connect_and_probe_reject_missing_runtime_inputs_fail_closed() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    let endpoint = state
        .lifecycle
        .endpoint
        .read()
        .await
        .clone()
        .expect("configured endpoint");
    let identity = state
        .lifecycle
        .identity
        .read()
        .await
        .clone()
        .expect("configured identity");

    *state.lifecycle.endpoint.write().await = None;
    let error = coordinator
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("connect without endpoint must fail");
    assert_eq!(error.code, NetworkErrorCode::InvalidArgument as i32);
    let error = coordinator
        .probe_direct("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("direct probe without endpoint must fail");
    assert_eq!(error.code, NetworkErrorCode::InvalidArgument as i32);

    *state.lifecycle.endpoint.write().await = Some(endpoint);
    *state.lifecycle.identity.write().await = None;
    let error = coordinator
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("connect without identity must fail");
    assert_eq!(error.code, NetworkErrorCode::InvalidArgument as i32);
    let error = coordinator
        .probe_direct("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("direct probe without identity must fail");
    assert_eq!(error.code, NetworkErrorCode::InvalidArgument as i32);

    *state.lifecycle.identity.write().await = Some(identity);
    state.peers.write().await.remove("peer-b");
    let error = coordinator
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("connect without peer route must fail");
    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    let error = coordinator
        .probe_direct("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("direct probe without peer route must fail");
    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
}

#[tokio::test]
async fn direct_probe_reports_no_route_when_no_candidate_is_available() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));

    let error = coordinator
        .probe_direct("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("a configured runtime without candidates must fail closed");

    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "a probe with no candidate must not reserve a Session"
    );
}

#[tokio::test]
async fn direct_probe_retires_its_temporary_session_after_a_failed_race() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let candidate = Candidate::new(
        "127.0.0.1:9".parse().expect("closed direct endpoint"),
        CandidateKind::Lan,
        "probe-unreachable".into(),
    )
    .with_generation(1);
    let cache = ResolvedCandidateCache::from_snapshot(
        ResolvedCandidateSnapshot {
            runtime_epoch: NatRuntimeEpoch { high: 41, low: 42 },
            revision: 1,
            candidates: vec![CandidatePayloadV2::from_candidate(
                &candidate,
                vec![CandidateTransport::Quic],
            )],
            server_presence_ttl: Some(Duration::from_secs(30)),
        },
        Instant::now(),
    )
    .expect("valid probe cache");
    state
        .remote_candidate_cache
        .write()
        .await
        .insert("peer-b".into(), cache);

    let error = coordinator_for(&state)
        .probe_direct("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("closed direct candidate must fail");

    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "failed pure Direct probing must retire its temporary Session"
    );
}
