#[test]
fn connect_cancellation_requires_generation_invalidation() {
    let supervisor = PeerSupervisor::new(PeerId::new("peer-a").expect("valid peer"));
    let intent = supervisor
        .begin_connect("connect-a", CommunicationClass::ReliableMessage)
        .expect("connect intent");
    let generation = intent.generation;
    intent.detach_completion();

    // PeerSupervisor uses Cancelled for an unsuccessful attempt as well
    // as an explicit disconnect. The unchanged generation distinguishes
    // the former so commands can report Failed rather than Cancelled.
    assert!(!connect_completion_was_cancelled(
        &supervisor,
        generation,
        &CoreNetworkError::Cancelled
    ));

    supervisor.disconnect();
    assert!(connect_completion_was_cancelled(
        &supervisor,
        generation,
        &CoreNetworkError::Cancelled
    ));
    assert!(connect_completion_was_cancelled(
        &supervisor,
        generation,
        &CoreNetworkError::SupervisorStopping
    ));
}

#[tokio::test]
async fn connect_command_rejects_missing_runtime_and_unknown_peer_before_attempt() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let not_configured = start_connect_peer(
        Arc::clone(&state),
        "connect-unconfigured".into(),
        "peer-a".into(),
        CommunicationClass::ReliableMessage,
    )
    .await
    .expect_err("connect must require runtime identity and endpoint");
    assert_eq!(
        not_configured.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let endpoint = network_quic::QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("endpoint address"),
        Arc::new(network_nat::PathManager::new()),
    )
    .expect("endpoint");
    *state.lifecycle.endpoint.write().await = Some(endpoint.endpoint);
    *state.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        ),
    ));
    let unknown_peer = start_connect_peer(
        state,
        "connect-unknown-peer".into(),
        "peer-a".into(),
        CommunicationClass::ReliableMessage,
    )
    .await
    .expect_err("connect must require a configured peer");
    assert_eq!(unknown_peer.code, NetworkErrorCode::NoRoute as i32);
}

#[tokio::test]
async fn connect_command_maps_unsuccessful_attempt_cancellation_to_io_error() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let endpoint = network_quic::QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("endpoint address"),
        Arc::new(network_nat::PathManager::new()),
    )
    .expect("endpoint");
    *state.lifecycle.endpoint.write().await = Some(endpoint.endpoint);
    *state.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        ),
    ));
    state.peers.write().await.insert(
        "peer-a".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [3; 32],
            e2e_public_key: [4; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test("peer-a".into()).await;
    let supervisor = state
        .peer_supervisors
        .get_or_create_with_configured("peer-a", true)
        .expect("supervisor");

    let connect = tokio::spawn(start_connect_peer(
        Arc::clone(&state),
        "connect-cancelled".into(),
        "peer-a".into(),
        CommunicationClass::ReliableMessage,
    ));
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if state.task_supervisor.active_count() > 0 {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("connect command should start a supervised task");
    state.task_supervisor.cancel_root();
    supervisor.stop();

    let error = tokio::time::timeout(Duration::from_secs(1), connect)
        .await
        .expect("cancelled connect should complete")
        .expect("connect task should join")
        .expect_err("cancelled connect must return an error");
    state.task_supervisor.shutdown().await;
    assert_eq!(error.code, NetworkErrorCode::IoError as i32);
}
