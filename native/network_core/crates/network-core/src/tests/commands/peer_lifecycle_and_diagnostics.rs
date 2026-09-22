#[tokio::test]
async fn remove_peer_evicts_configuration_and_supervisor() {
    let (sender, _receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = RuntimeState::new(sender, Arc::new(std::sync::atomic::AtomicU16::new(0)));
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
        .trusted_peer_keys
        .write()
        .await
        .insert("peer-a".into(), [1; 32]);
    state
        .peer_supervisors
        .get_or_create_with_configured("peer-a", true)
        .expect("supervisor");

    assert!(
        state
            .transfer
            .manager
            .register_outgoing(
                manifest("outgoing-transfer"),
                PathBuf::from("/tmp/outgoing-transfer.bin"),
                "peer-a".into(),
            )
            .await
    );
    state.relay.pending_incoming.write().await.insert(
        "pending-transfer".into(),
        crate::relay::PendingRelayIncoming {
            transfer_id: "pending-transfer".into(),
            session_id: "pending-session".into(),
            sender_id: "peer-a".into(),
            manifest: manifest("pending-transfer"),
            manifest_hash: "a".repeat(64),
            crypto_session_id: "crypto-session".into(),
        },
    );
    state.relay.active_incoming.lock().await.insert(
        "active-transfer".into(),
        crate::relay::ActiveRelayIncoming {
            offer: crate::relay::PendingRelayIncoming {
                transfer_id: "active-transfer".into(),
                session_id: "active-session".into(),
                sender_id: "peer-a".into(),
                manifest: manifest("active-transfer"),
                manifest_hash: "a".repeat(64),
                crypto_session_id: "crypto-session".into(),
            },
            file: None,
            temporary_path: PathBuf::from("/tmp/active-transfer.part"),
            final_path: PathBuf::from("/tmp/active-transfer.bin"),
            next_sequence: 0,
            received_bytes: 0,
            hasher: sha2::Sha256::new(),
            already_completed: false,
        },
    );
    let stream_manager = ReliableStreamManager::new(state.event_tx.clone());
    stream_manager
        .open(StreamOpener::Local, 1, "ssh", StreamConsumer::Poll)
        .await
        .expect("stream owned by the peer");
    state
        .reliable_streams
        .write()
        .await
        .insert("peer-a".into(), stream_manager);
    let session_id = crate::session::SessionId::new();
    state
        .connection_sessions
        .register_pending_session("peer-a", session_id)
        .await
        .expect("pending peer session");
    let (acceptance_tx, _acceptance_rx) = oneshot::channel();
    state
        .relay
        .acceptances
        .write()
        .await
        .insert("outgoing-transfer".into(), acceptance_tx);
    let (completion_tx, _completion_rx) = oneshot::channel();
    state
        .relay
        .completions
        .write()
        .await
        .insert("outgoing-transfer".into(), completion_tx);

    remove_peer_v2(&state, "peer-a".into())
        .await
        .expect("remove peer");

    assert!(!state.peers.read().await.contains_key("peer-a"));
    assert!(!state.trusted_peer_keys.read().await.contains_key("peer-a"));
    assert!(!state
        .peer_supervisors
        .remove_if_evictable("peer-a")
        .expect("removed peer supervisor lookup"));
    assert!(state
        .transfer
        .manager
        .snapshot("outgoing-transfer")
        .await
        .is_none());
    assert!(state.relay.pending_incoming.read().await.is_empty());
    assert!(state.relay.active_incoming.lock().await.is_empty());
    assert!(state.relay.acceptances.read().await.is_empty());
    assert!(state.relay.completions.read().await.is_empty());
    assert!(state.reliable_streams.read().await.get("peer-a").is_none());
    assert!(state
        .connection_sessions
        .current_session_id("peer-a")
        .await
        .is_none());
}

#[tokio::test]
async fn diagnostics_reads_live_supervisor_and_path_manager() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = RuntimeState::new(sender, Arc::new(std::sync::atomic::AtomicU16::new(0)));
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
    supervisor.admit_inbound(true).expect("online supervisor");

    let peer = PeerId::new("peer-a").expect("valid peer");
    let mut path_manager =
        crate::connect::PeerPathManager::new(peer, Arc::clone(&state.ready_paths));
    path_manager
        .publish_ready(
            crate::connection::ConnectionProfile::for_route(
                network_protocol::RouteType::QuicDirect,
            )
            .expect("direct profile"),
        )
        .expect("ready path");
    state.peer_path_managers.write().await.insert(
        "peer-a".into(),
        Arc::new(std::sync::Mutex::new(path_manager)),
    );
    state.allow_routes_for_test("peer-a".into()).await;
    let stream_manager = ReliableStreamManager::new(state.event_tx.clone());
    stream_manager
        .open(StreamOpener::Local, 1, "ssh", StreamConsumer::Poll)
        .await
        .expect("stream owned by the peer");
    state
        .reliable_streams
        .write()
        .await
        .insert("peer-a".into(), stream_manager);
    assert!(
        state
            .transfer
            .manager
            .register_outgoing(
                manifest("diagnostic-transfer"),
                PathBuf::from("/tmp/diagnostic-transfer.bin"),
                "peer-a".into(),
            )
            .await
    );
    let (acceptance_tx, _acceptance_rx) = oneshot::channel();
    state
        .relay
        .acceptances
        .write()
        .await
        .insert("diagnostic-transfer".into(), acceptance_tx);
    let (completion_tx, _completion_rx) = oneshot::channel();
    state
        .relay
        .completions
        .write()
        .await
        .insert("diagnostic-transfer".into(), completion_tx);

    emit_peer_diagnostics(&state, "peer-a".into())
        .await
        .expect("diagnostics");
    let Some(network_protocol::network_event::Payload::PeerDiagnostics(diagnostics)) =
        receiver.try_recv().expect("diagnostics event").payload
    else {
        panic!("expected PeerDiagnostics");
    };
    assert_eq!(
        diagnostics.state,
        network_protocol::PeerState::Online as i32
    );
    assert_eq!(diagnostics.ready_path_count, 1);
    assert_eq!(diagnostics.active_stream_count, 1);
    assert_eq!(diagnostics.active_transfer_count, 1);
    assert_eq!(
        diagnostics.e2ee_policy,
        network_protocol::E2eePolicy::Required as i32
    );
}

#[tokio::test]
async fn diagnostics_for_unconfigured_peer_reports_offline_defaults() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = RuntimeState::new(sender, Arc::new(std::sync::atomic::AtomicU16::new(0)));

    emit_peer_diagnostics(&state, "unconfigured-peer".into())
        .await
        .expect("diagnostics for an unknown peer");
    let Some(network_protocol::network_event::Payload::PeerDiagnostics(diagnostics)) =
        receiver.try_recv().expect("diagnostics event").payload
    else {
        panic!("expected PeerDiagnostics");
    };
    assert_eq!(diagnostics.peer_id, "unconfigured-peer");
    assert_eq!(
        diagnostics.state,
        network_protocol::PeerState::Offline as i32
    );
    assert_eq!(
        diagnostics.e2ee_policy,
        network_protocol::E2eePolicy::Required as i32
    );
    assert_eq!(diagnostics.ready_path_count, 0);
    assert_eq!(diagnostics.queued_command_count, 0);
    assert_eq!(diagnostics.active_stream_count, 0);
    assert_eq!(diagnostics.active_transfer_count, 0);
}
