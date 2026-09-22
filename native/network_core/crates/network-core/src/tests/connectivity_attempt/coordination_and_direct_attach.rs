#[tokio::test(start_paused = true)]
async fn overall_timeout_allows_real_second_connect() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let first_control = StubControl::timeout();
    *state.relay.control.write().await = Some(first_control.clone());

    let first_coordinator = Arc::new(ConnectivityAttemptCoordinator::new(Arc::clone(&state)));
    let first_task = {
        let coordinator = Arc::clone(&first_coordinator);
        tokio::spawn(async move {
            coordinator
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        })
    };
    let old_session_id = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if first_control.resolve_calls() >= 1 {
                if let Some(session_id) =
                    state.connection_sessions.current_session_id("peer-b").await
                {
                    break session_id;
                }
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("timeout coordinator must reach authoritative Resolve");

    tokio::time::advance(super::super::OVERALL_CONNECT_BUDGET + Duration::from_millis(1)).await;
    let result = first_task.await.expect("overall timeout task");
    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::Timeout as i32),
        "first coordinator must return Timeout: {result:?}"
    );
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if state.connection_sessions.current_session_id("peer-b").await != Some(old_session_id)
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("overall timeout cleanup must retire the old Session");

    let second_control = StubControl::new(
        ResolveStatus::Ready,
        Some(stage_c_ready_relay_only_snapshot()),
    );
    second_control.hold_offer();
    *state.relay.control.write().await = Some(second_control.clone());

    let second_coordinator = Arc::new(ConnectivityAttemptCoordinator::new(Arc::clone(&state)));
    let second_task = {
        let coordinator = Arc::clone(&second_coordinator);
        tokio::spawn(async move {
            coordinator
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        })
    };
    second_control.wait_offer_started().await;
    let new_session_id = state
        .connection_sessions
        .current_session_id("peer-b")
        .await
        .expect("second coordinator must reach Offer with a new Session");

    assert!(second_control.resolve_calls() >= 1);
    assert!(second_control.connectivity_calls() >= 1);
    assert_ne!(new_session_id, old_session_id);

    state.fail_session("peer-b", old_session_id).await;
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        Some(new_session_id),
        "stale timeout cleanup must not retire the replacement Session"
    );

    second_control.release_offer();
    let result = tokio::time::timeout(Duration::from_secs(2), second_task)
        .await
        .expect("second coordinator must not remain permanently InProgress")
        .expect("second coordinator task");
    assert!(
        result.is_err(),
        "the closed test candidate must fail normally: {result:?}"
    );
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "failed replacement coordinator must retire its own Session"
    );
}

#[tokio::test(flavor = "current_thread")]
async fn stage_b_resolves_and_offers_before_relay_reservation() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let stage_b_candidate = Candidate::new(
        "127.0.0.1:9".parse().expect("candidate endpoint"),
        CandidateKind::Lan,
        "stage-b-candidate".into(),
    )
    .with_generation(1);
    let stale_cache = ResolvedCandidateCache::from_snapshot(
        ResolvedCandidateSnapshot {
            runtime_epoch: NatRuntimeEpoch { high: 1, low: 1 },
            revision: 1,
            candidates: vec![CandidatePayloadV2::from_candidate(
                &stage_b_candidate,
                vec![CandidateTransport::Quic],
            )],
            server_presence_ttl: Some(Duration::from_secs(1)),
        },
        Instant::now() - Duration::from_secs(10),
    )
    .expect("valid stale Stage A cache");
    state
        .remote_candidate_cache
        .write()
        .await
        .insert("peer-b".into(), stale_cache);
    let control = StubControl::new(
        ResolveStatus::Ready,
        Some(DiscoverySnapshot {
            runtime_epoch: Some(RuntimeEpoch { high: 3, low: 4 }),
            revision: 1,
            transport_capabilities: vec![
                network_relay::v2::TransportCapability::Quic as i32,
                network_relay::v2::TransportCapability::RelayData as i32,
            ],
            candidate_bundle: Some(network_relay::v2::CandidateBundle {
                candidates: vec![serde_json::to_vec(&stage_b_candidate.advertisement())
                    .expect("candidate advertisement")],
            }),
            published_at_ms: 0,
        }),
    );
    *state.relay.control.write().await = Some(control.clone());
    control.observe_session_ownership(Arc::clone(&state));

    let stage_c_state = Arc::new(StageCLogState::new());
    let _subscriber_guard =
        tracing::subscriber::set_default(StageCLogCapture::new(Arc::clone(&stage_c_state)));
    *stage_c_state
        .direct_failed_at
        .lock()
        .expect("Direct failure timestamp lock") = None;
    *stage_c_state
        .expected_attempt_id
        .lock()
        .expect("Stage C attempt id lock") = None;
    control.observe_attempt_id(Arc::clone(&stage_c_state.expected_attempt_id));
    // The scoped guard covers this current-thread test.  Instrumenting the
    // awaited coordinator future carries the same test dispatch if Tokio polls
    // a nested task on another worker while the selector runs in parallel.
    let dispatch = tracing::Dispatch::new(StageCLogCapture::new(Arc::clone(&stage_c_state)));
    let result = tracing::dispatcher::with_default(&dispatch, || {
        async {
            ConnectivityAttemptCoordinator::new(Arc::clone(&state))
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        }
        .instrument(tracing::span!(tracing::Level::TRACE, "stage_c_ordering"))
    })
    .await;
    assert!(result.is_err(), "test control has no usable transport");
    assert_eq!(
        control.call_order(),
        vec!["resolve", "offer", "reserve"],
        "Stage B must complete Resolve → Offer/Answer coordination before Stage C reserve"
    );
    assert_eq!(
        control.resolve_calls(),
        1,
        "Stage B must issue exactly one authoritative Resolve"
    );
    assert!(
        control.first_resolve_saw_owned_session(),
        "Stage B must reserve a local Session before authoritative Resolve"
    );
    assert_eq!(
        control.connectivity_calls(),
        1,
        "Stage B must enqueue exactly one ConnectivityOffer"
    );
    assert_eq!(
        control.reserve_calls(),
        1,
        "Stage C must issue exactly one Relay reservation"
    );
    let direct_failed_at = stage_c_state
        .direct_failed_at
        .lock()
        .expect("Direct failure timestamp lock")
        .expect("Stage C observer must capture Direct failure");
    let call_times = control.call_times();
    let resolve_at = call_times
        .iter()
        .find_map(|(name, timestamp)| (*name == "resolve").then_some(*timestamp))
        .expect("Resolve timestamp");
    let offer_at = call_times
        .iter()
        .find_map(|(name, timestamp)| (*name == "offer").then_some(*timestamp))
        .expect("Offer timestamp");
    let reserve_at = control.reserve_at().expect("Reserve timestamp");
    assert!(
        resolve_at < offer_at && offer_at < direct_failed_at && direct_failed_at < reserve_at,
        "Stage C must preserve Resolve → Offer → Direct failure → Reserve ordering: resolve={resolve_at:?}, offer={offer_at:?}, direct_failed={direct_failed_at:?}, reserve={reserve_at:?}"
    );
    let cache = state
        .remote_candidate_cache
        .read()
        .await
        .get("peer-b")
        .cloned()
        .expect("Stage B must refresh the remote candidate cache");
    assert_eq!(cache.runtime_epoch, NatRuntimeEpoch { high: 3, low: 4 });
    assert_eq!(cache.revision, 1);
    assert!(
        cache.stage_a_candidates_at(Instant::now()).is_some(),
        "refreshed cache is not fresh: candidates={}, ttl={:?}, age={:?}",
        cache.candidates.len(),
        cache.ttl(),
        cache.age_at(Instant::now())
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stage_c_direct_success_attaches_a_fresh_quic_session() {
    let (client_state, _event_rx, _configured_control) = configured_reuse_state().await;
    let client_identity = client_state
        .lifecycle
        .identity
        .read()
        .await
        .clone()
        .expect("client identity");

    let server_identity = Arc::new(network_identity::DeviceIdentity::from_private_keys(
        "peer-b".into(),
        [41u8; 32],
        [51u8; 32],
    ));
    let (server_event_tx, _server_event_rx) = tokio::sync::mpsc::unbounded_channel();
    let server_state = Arc::new(RuntimeState::new(
        server_event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    *server_state.lifecycle.identity.write().await = Some(Arc::clone(&server_identity));
    server_state.peers.write().await.insert(
        client_identity.device_id.clone(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: client_identity.public_identity_key().to_bytes(),
            e2e_public_key: client_identity.public_e2e_key().to_bytes(),
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    server_state.allow_routes_for_test(&client_identity.device_id).await;
    server_state.trusted_peer_keys.write().await.insert(
        client_identity.device_id.clone(),
        client_identity.public_identity_key().to_bytes(),
    );
    server_state.peer_route_authorizations.write().await.insert(
        client_identity.device_id.clone(),
        crate::runtime::PeerRouteAuthorization {
            direct: true,
            relay: true,
        },
    );
    let server_endpoint = network_quic::QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("server address"),
        Arc::new(PathManager::new()),
    )
    .expect("server endpoint")
    .endpoint;
    let server_address = server_endpoint.local_addr().expect("server local address");
    server_state
        .task_supervisor
        .spawn_runtime(
            "stage-c-direct-accept",
            crate::peer::InboundConnectionAcceptor::accept_connections(
                server_endpoint.clone(),
                Arc::clone(&server_state),
            ),
        )
        .expect("server accept task");

    {
        let mut peers = client_state.peers.write().await;
        let peer = peers.get_mut("peer-b").expect("configured peer");
        peer.identity_public_key = server_identity.public_identity_key().to_bytes();
        peer.e2e_public_key = server_identity.public_e2e_key().to_bytes();
    }
    let candidate = Candidate::new(server_address, CandidateKind::Lan, "stage-c-quic".into())
        .with_generation(1);
    let snapshot = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 11, low: 12 }),
        revision: 1,
        transport_capabilities: vec![network_relay::v2::TransportCapability::Quic as i32],
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![
                serde_json::to_vec(&candidate.advertisement()).expect("candidate advertisement")
            ],
        }),
        published_at_ms: 0,
    };
    let control = StubControl::new(ResolveStatus::Ready, Some(snapshot.clone()));
    *client_state.relay.control.write().await = Some(control.clone());
    let answer = network_relay::v2::ConnectivityAnswer {
        request_id: 1,
        attempt_id: String::new(),
        accepted: true,
        responder_device_id: "peer-b".into(),
        responder_runtime_epoch: snapshot.runtime_epoch.clone(),
        responder_revision: snapshot.revision,
        responder_snapshot: Some(snapshot.clone()),
    };
    control.set_connectivity_answer(answer);
    control.observe_session_ownership(Arc::clone(&client_state));

    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&client_state));
    let result = coordinator
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;
    assert!(result.is_ok(), "Direct Stage C should attach: {result:?}");
    assert_eq!(
        coordinator.stage(),
        ConnectivityAttemptState::ConnectedDirect
    );
    assert!(
        client_state
            .connection_sessions
            .current_session_id("peer-b")
            .await
            .is_some(),
        "Direct attach must retain the session admission"
    );
    let manager_state = client_state
        .peer_path_managers
        .read()
        .await
        .get("peer-b")
        .cloned()
        .map(|manager| {
            let manager = manager.lock().expect("peer path manager lock");
            (
                usize::from(manager.direct_ready().is_some()),
                manager.relay_ready().is_some(),
            )
        });
    assert_eq!(
        manager_state,
        Some((1, false)),
        "Direct attach must retain its ready Direct carrier"
    );
    assert!(
        client_state.path_profile("peer-b").await.is_some(),
        "Direct attach must publish a physical path"
    );
    assert!(client_state.path_is_connected("peer-b").await);
    assert_eq!(control.resolve_calls(), 1);
    assert_eq!(control.connectivity_calls(), 1);
    assert_eq!(control.reserve_calls(), 0);

    let session_id = client_state
        .connection_sessions
        .current_session_id("peer-b")
        .await
        .expect("client session");
    client_state.close_transport_path("peer-b").await;
    client_state
        .connection_sessions
        .retire_session("peer-b", session_id)
        .await;
    client_state
        .cancel_session_tasks("peer-b", session_id)
        .await;
    server_endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
    client_state.task_supervisor.cancel_root();
    server_state.task_supervisor.cancel_root();
    client_state.task_supervisor.shutdown().await;
    server_state.task_supervisor.shutdown().await;
}

#[tokio::test]
async fn stage_b_not_ready_retries_once_with_a_fresh_attempt_id() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    control.return_not_ready_once();
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    let result = coordinator
        .begin_stage_b_transaction(
            control.clone(),
            StageBTransactionRequest {
                peer_id: "peer-b".into(),
                initiator_device_id: "device-a".into(),
                initiator_runtime_epoch: RuntimeEpoch { high: 1, low: 2 },
                initiator_revision: 1,
                initiator_snapshot: None,
                connect_deadline: Instant::now() + Duration::from_secs(2),
            },
        )
        .await
        .expect("NOT_READY should retry within the connect budget");

    assert_eq!(
        control.resolve_calls(),
        2,
        "retry must issue a fresh Resolve"
    );
    assert_eq!(
        control.connectivity_calls(),
        1,
        "only the READY retry may Offer"
    );
    assert_eq!(control.call_order(), vec!["resolve", "resolve", "offer"]);
    assert_eq!(result.1.resolved.status, ResolveStatus::Ready as i32);
    assert!(matches!(
        result.1.wait_for_answer().await,
        Err(RelayError::NotConnected)
    ));
}

#[tokio::test]
async fn stage_b_not_ready_preserves_authority_when_budget_is_exhausted() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    control.return_not_ready_once();
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    let (_, start) = coordinator
        .begin_stage_b_transaction(
            control.clone(),
            StageBTransactionRequest {
                peer_id: "peer-b".into(),
                initiator_device_id: "device-a".into(),
                initiator_runtime_epoch: RuntimeEpoch { high: 1, low: 2 },
                initiator_revision: 1,
                initiator_snapshot: None,
                connect_deadline: Instant::now(),
            },
        )
        .await
        .expect("the first authoritative NOT_READY response should return");

    assert_eq!(control.resolve_calls(), 1);
    assert_eq!(control.connectivity_calls(), 0);
    assert_eq!(start.resolved.status, ResolveStatus::NotReady as i32);
}
