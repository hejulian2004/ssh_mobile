#[tokio::test]
async fn environment_change_refreshes_discovery_revision() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        sender,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    crate::discovery::begin_epoch(&state).await;

    dispatch_command(
        NetworkCommand {
            command_id: "environment-change".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::NetworkEnvironmentChanged(
                network_protocol::NetworkEnvironmentChangedCommand {
                    generation: 7,
                    has_connectivity: false,
                    is_foreground: true,
                    is_metered: false,
                },
            )),
        },
        Arc::clone(&state),
    )
    .await
    .expect("environment change");

    assert_eq!(
        state
            .local_discovery
            .read()
            .await
            .as_ref()
            .expect("discovery manager")
            .revision(),
        2
    );
    assert!(matches!(
        receiver.try_recv().expect("environment event").payload,
        Some(network_protocol::network_event::Payload::NetworkEnvironmentChanged(event))
            if event.generation == 7 && !event.has_connectivity
    ));
}

#[tokio::test]
async fn environment_change_retires_an_unmaintained_direct_owner() {
    let (sender, _receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        sender,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    state.peers.write().await.insert(
        "peer-a".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test("peer-a".into()).await;
    let supervisor = state
        .peer_supervisors
        .get_or_create_with_configured("peer-a", false)
        .expect("supervisor");
    supervisor.admit_inbound(true).expect("online supervisor");

    let peer = PeerId::new("peer-a").expect("valid peer");
    let mut manager = crate::connect::PeerPathManager::new(peer, Arc::clone(&state.ready_paths));
    manager
        .publish_ready(
            crate::connection::ConnectionProfile::for_route(
                network_protocol::RouteType::QuicDirect,
            )
            .expect("direct profile"),
        )
        .expect("direct path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".into(), Arc::new(std::sync::Mutex::new(manager)));
    state.allow_routes_for_test("peer-a".into()).await;

    handle_network_environment_changed(
        &state,
        &network_protocol::NetworkEnvironmentChangedCommand {
            generation: 7,
            has_connectivity: false,
            is_foreground: true,
            is_metered: false,
        },
    )
    .await
    .expect("environment transition");

    assert!(!state.has_ready_direct_path("peer-a").await);
    assert_eq!(supervisor.state(), PeerState::Offline);
}

#[tokio::test]
async fn environment_change_preserves_relay_and_retires_only_direct_path() {
    let (sender, _receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        sender,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    state.peers.write().await.insert(
        "peer-a".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test("peer-a".into()).await;
    state
        .peer_supervisors
        .get_or_create_with_configured("peer-a", false)
        .expect("supervisor");

    let peer = PeerId::new("peer-a").expect("valid peer");
    let mut manager = crate::connect::PeerPathManager::new(peer, Arc::clone(&state.ready_paths));
    manager
        .publish_ready(
            crate::connection::ConnectionProfile::for_route(
                network_protocol::RouteType::QuicDirect,
            )
            .expect("direct profile"),
        )
        .expect("direct path");
    manager
        .publish_ready_with_route(crate::connect::ActiveRoute::relay(None))
        .expect("relay path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".into(), Arc::new(std::sync::Mutex::new(manager)));
    state.allow_routes_for_test("peer-a".into()).await;

    handle_network_environment_changed(
        &state,
        &network_protocol::NetworkEnvironmentChangedCommand {
            generation: 8,
            has_connectivity: false,
            is_foreground: true,
            is_metered: false,
        },
    )
    .await
    .expect("environment transition");

    assert!(!state.has_ready_direct_path("peer-a").await);
    assert!(state.has_ready_relay_path("peer-a").await);
}

#[tokio::test]
async fn environment_change_restarts_a_maintained_direct_supervisor() {
    let (sender, _receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        sender,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    state.peers.write().await.insert(
        "peer-a".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test("peer-a".into()).await;
    let supervisor = state
        .peer_supervisors
        .get_or_create_with_configured("peer-a", true)
        .expect("supervisor");
    let intent = supervisor
        .begin_connect("maintenance-seed", CommunicationClass::ReliableMessage)
        .expect("maintenance intent");
    intent.detach_completion();
    supervisor.admit_inbound(true).expect("online supervisor");

    let peer = PeerId::new("peer-a").expect("valid peer");
    let mut manager = crate::connect::PeerPathManager::new(peer, Arc::clone(&state.ready_paths));
    manager
        .publish_ready(
            crate::connection::ConnectionProfile::for_route(
                network_protocol::RouteType::QuicDirect,
            )
            .expect("direct profile"),
        )
        .expect("direct path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".into(), Arc::new(std::sync::Mutex::new(manager)));
    state.allow_routes_for_test("peer-a".into()).await;

    handle_network_environment_changed(
        &state,
        &network_protocol::NetworkEnvironmentChangedCommand {
            generation: 9,
            has_connectivity: true,
            is_foreground: true,
            is_metered: false,
        },
    )
    .await
    .expect("maintained environment transition");

    assert!(!state.has_ready_direct_path("peer-a").await);
    assert!(supervisor.maintain_connection());
    assert!(matches!(
        supervisor.state(),
        PeerState::Offline | PeerState::Connecting
    ));
    state.task_supervisor.cancel_root();
    supervisor.stop();
    state.task_supervisor.shutdown().await;
}

#[tokio::test]
async fn environment_change_starts_relay_backed_direct_recovery() {
    let (sender, _receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        sender,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    state.peers.write().await.insert(
        "peer-a".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test("peer-a".into()).await;
    let supervisor = state
        .peer_supervisors
        .get_or_create_with_configured("peer-a", true)
        .expect("supervisor");
    let intent = supervisor
        .begin_connect("maintenance-seed", CommunicationClass::ReliableMessage)
        .expect("maintenance intent");
    intent.detach_completion();
    let session_id = crate::session::SessionId::new();
    state
        .connection_sessions
        .register_pending_session("peer-a", session_id)
        .await
        .expect("pending session");
    assert!(
        state
            .mark_relay_route_connected("peer-a", session_id, None)
            .await
    );

    handle_network_environment_changed(
        &state,
        &network_protocol::NetworkEnvironmentChangedCommand {
            generation: 10,
            has_connectivity: true,
            is_foreground: true,
            is_metered: false,
        },
    )
    .await
    .expect("relay-backed environment transition");

    let probe_started = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            let started = state
                .peer_path_managers
                .read()
                .await
                .get("peer-a")
                .is_some_and(|manager| {
                    manager
                        .lock()
                        .expect("peer path manager lock")
                        .direct_probe()
                        .is_some()
                });
            if started {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .is_ok();
    state.task_supervisor.cancel_root();
    supervisor.stop();
    state.task_supervisor.shutdown().await;
    assert!(probe_started, "environment change must arm a Direct probe");
}
