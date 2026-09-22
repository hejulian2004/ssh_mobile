use super::*;
use crate::session::SessionId;
use network_protocol::{network_event, NetworkEvent, NETWORK_PROTOCOL_VERSION};
use std::sync::Mutex;
use tokio::sync::mpsc::unbounded_channel;
use tokio::sync::{mpsc, oneshot};

async fn state_with_ready_stream_path() -> (Arc<RuntimeState>, Arc<crate::connect::PathRegistry>) {
    let (event_tx, _event_rx) = unbounded_channel::<NetworkEvent>();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let registry = Arc::new(crate::connect::PathRegistry::new());
    let mut manager = crate::connect::PeerPathManager::new(
        crate::connect::PeerId::new("peer-a").expect("peer"),
        Arc::clone(&registry),
    );
    manager
        .publish_ready(crate::connection::ConnectionProfile::new(
            crate::connection::Route::direct(crate::connection::RouteTransport::Tcp),
        ))
        .expect("ready path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".to_string(), Arc::new(Mutex::new(manager)));
    state.allow_routes_for_test("peer-a").await;
    (state, registry)
}

#[tokio::test]
async fn transfer_auto_ensures_path() {
    let (state, _registry) = state_with_ready_stream_path().await;
    ensure_business_path(
        &state,
        "peer-a",
        "transfer-auto",
        CommunicationClass::BulkTransfer,
        CAPABILITY_RELIABLE_STREAM,
    )
    .await
    .expect("bulk transfer should use the compatible ready path");
}

async fn state_with_route_profile(route: crate::connection::Route) -> Arc<RuntimeState> {
    let (event_tx, _event_rx) = unbounded_channel::<NetworkEvent>();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let registry = Arc::new(crate::connect::PathRegistry::new());
    let mut manager = crate::connect::PeerPathManager::new(
        crate::connect::PeerId::new("peer-a").expect("peer"),
        Arc::clone(&registry),
    );
    manager
        .publish_ready(crate::connection::ConnectionProfile::new(route))
        .expect("ready test route");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".into(), Arc::new(Mutex::new(manager)));
    state.allow_routes_for_test("peer-a".into()).await;
    let session_id = SessionId::new();
    state
        .connection_sessions
        .register_pending_session("peer-a", session_id)
        .await
        .expect("pending transfer session");
    state
        .admit_authenticated_session("peer-a", Some(session_id), "remote-transfer")
        .await
        .expect("admit transfer session");
    state
}

#[tokio::test]
async fn transfer_dispatcher_rejects_routes_without_a_usable_file_carrier() {
    let identity = TransferIdentity::new("peer-a", "transfer-route-boundary").unwrap();
    for (route, expected) in [
        (
            crate::connection::Route::direct(crate::connection::RouteTransport::Tcp),
            "selected path cannot carry file transfer",
        ),
        (
            crate::connection::Route::direct(crate::connection::RouteTransport::Quic),
            "selected QUIC path has no active Connection",
        ),
        (
            crate::connection::Route::relay(crate::connection::RouteTransport::WebSocket),
            "selected Relay path has no active data reservation",
        ),
    ] {
        let state = state_with_route_profile(route).await;
        let error = match TransferDispatcher::new(Arc::clone(&state))
            .select_attempt(&identity)
            .await
        {
            Ok(_) => panic!("unusable file route unexpectedly selected"),
            Err(error) => error,
        };
        assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
        assert!(error.message.contains(expected), "{error:?}");
    }
}

#[tokio::test]
async fn transfer_dispatcher_rejects_relay_dispatch_for_an_unregistered_peer() {
    let state = state_with_route_profile(crate::connection::Route::direct(
        crate::connection::RouteTransport::Tcp,
    ))
    .await;
    let registry = Arc::new(crate::connect::PathRegistry::new());
    let mut manager = crate::connect::PeerPathManager::new(
        crate::connect::PeerId::new("peer-a").expect("peer"),
        Arc::clone(&registry),
    );
    let handle = manager
        .publish_ready(crate::connection::ConnectionProfile::new(
            crate::connection::Route::direct(crate::connection::RouteTransport::Tcp),
        ))
        .expect("dispatch test path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".into(), Arc::new(Mutex::new(manager)));
    state.allow_routes_for_test("peer-a".into()).await;
    let lease = registry.acquire(&handle).expect("dispatch test lease");
    let manifest = network_transfer::FileManifest {
        transfer_id: "relay-dispatch".into(),
        file_name: "payload.bin".into(),
        file_size: 0,
        modified_at: 0,
        content_hash: "00".repeat(32),
        protocol_version: NETWORK_TRANSFER_PROTOCOL_VERSION,
    };
    let transfer = ResumableTransfer {
        transfer_id: manifest.transfer_id.clone(),
        peer_id: "unregistered-peer".into(),
        session_id: "session".into(),
        source_path: PathBuf::from("payload.bin"),
        manifest,
        offset: 0,
    };
    let error = match TransferDispatcher::new(Arc::clone(&state))
        .dispatch_outgoing(TransferRoute::Relay, lease, transfer)
        .await
    {
        Ok(()) => panic!("Relay transfer dispatched for an unregistered peer"),
        Err(error) => error,
    };
    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    assert!(error.message.contains("not registered"));
}

#[test]
fn transfer_identity_is_session_independent() {
    let identity = TransferIdentity::new("peer-a", "transfer-a").expect("identity");
    assert_eq!(identity.peer_id, "peer-a");
    assert_eq!(identity.transfer_id, "transfer-a");
    assert_ne!(
        identity,
        TransferIdentity::new("peer-b", "transfer-a").expect("peer-scoped identity")
    );
}

#[test]
fn path_loss_is_a_recoverable_public_error() {
    assert_eq!(
        transfer_failure_code(TransferFailureReason::SessionReplaced),
        NetworkErrorCode::PathLost
    );
}

#[tokio::test]
async fn transfer_resume_survives_new_connection_session_id() {
    let manager = network_transfer::TransferManager::new();
    let manifest = FileManifest {
        transfer_id: "transfer-session-independent".to_string(),
        file_name: "payload.bin".to_string(),
        file_size: 8,
        modified_at: 0,
        content_hash: "00".repeat(32),
        protocol_version: NETWORK_TRANSFER_PROTOCOL_VERSION,
    };
    assert!(
        manager
            .register_outgoing(manifest, PathBuf::from("payload.bin"), "peer-a".to_string(),)
            .await
    );
    assert!(
        manager
            .mark_transferring("transfer-session-independent")
            .await
    );
    assert!(
        manager
            .update_progress("transfer-session-independent", 4)
            .await
    );
    assert!(
        manager
            .pause_for_network("transfer-session-independent")
            .await
    );

    let old_session_id = "session-old";
    let new_session_id = "session-new";
    assert_ne!(old_session_id, new_session_id);
    let resumed = manager
        .take_resumable_for_peer("peer-a", new_session_id)
        .await;
    assert_eq!(resumed.len(), 1);
    assert_eq!(resumed[0].peer_id, "peer-a");
    assert_eq!(resumed[0].transfer_id, "transfer-session-independent");
    assert_eq!(resumed[0].session_id, new_session_id);
    assert_eq!(resumed[0].offset, 4);
}

#[test]
fn transfer_path_loss_acquires_fresh_lease() {
    let registry = Arc::new(crate::connect::PathRegistry::new());
    let mut manager = crate::connect::PeerPathManager::new(
        crate::connect::PeerId::new("peer-a").expect("peer"),
        Arc::clone(&registry),
    );
    let old_handle = manager
        .publish_ready(crate::connection::ConnectionProfile::new(
            crate::connection::Route::direct(crate::connection::RouteTransport::Tcp),
        ))
        .expect("old path");
    let old_lease = registry.acquire(&old_handle).expect("old lease");
    registry.drain(&old_handle);
    let new_handle = manager
        .publish_ready(crate::connection::ConnectionProfile::new(
            crate::connection::Route::direct(crate::connection::RouteTransport::Tcp),
        ))
        .expect("fresh path");
    let new_lease = registry.acquire(&new_handle).expect("fresh lease");
    assert_ne!(old_handle, new_handle);
    assert!(
        old_lease.is_active(),
        "normal retire drains the old attempt"
    );
    assert!(new_lease.is_active());
}

#[test]
fn transfer_identity_validation_and_failure_mapping_are_fail_closed() {
    assert!(valid_transfer_identity("transfer-1", "peer-a"));
    assert!(!valid_transfer_identity("", "peer-a"));
    assert!(!valid_transfer_identity("transfer with spaces", "peer-a"));
    assert!(!valid_transfer_identity("transfer", ""));
    assert!(!valid_transfer_identity(&"x".repeat(129), "peer-a"));
    assert!(!valid_transfer_identity("transfer", &"x".repeat(129)));

    for (reason, expected) in [
        (
            TransferFailureReason::UserRejected,
            NetworkErrorCode::Cancelled,
        ),
        (
            TransferFailureReason::Permission,
            NetworkErrorCode::InvalidArgument,
        ),
        (
            TransferFailureReason::Protocol,
            NetworkErrorCode::InvalidArgument,
        ),
        (
            TransferFailureReason::HashMismatch,
            NetworkErrorCode::IoError,
        ),
        (
            TransferFailureReason::SourceChanged,
            NetworkErrorCode::IoError,
        ),
        (TransferFailureReason::Io, NetworkErrorCode::IoError),
        (
            TransferFailureReason::RetryBudgetExhausted,
            NetworkErrorCode::Timeout,
        ),
        (
            TransferFailureReason::SessionReplaced,
            NetworkErrorCode::PathLost,
        ),
    ] {
        assert_eq!(transfer_failure_code(reason), expected);
    }

    let stale = TransferAttemptError::stale_attempt(TransferFailureReason::Protocol);
    assert!(!stale.terminal);
    assert_eq!(
        stale.recovery_error(),
        BusinessRecoveryError::RecoverableTransportLoss
    );
    assert!(stale.to_string().contains("no longer owns"));
    assert!(TransferIdentity::new("", "id").is_err());
    assert!(TransferIdentity::new("peer", "").is_err());
}

#[test]
fn transient_transport_errors_include_wrapped_io_but_not_validation_errors() {
    for kind in [
        std::io::ErrorKind::BrokenPipe,
        std::io::ErrorKind::ConnectionAborted,
        std::io::ErrorKind::ConnectionReset,
        std::io::ErrorKind::NotConnected,
        std::io::ErrorKind::UnexpectedEof,
        std::io::ErrorKind::TimedOut,
    ] {
        let error = std::io::Error::new(kind, "transport lost");
        assert!(is_transient_transport_error(&error));
    }
    let error = std::io::Error::new(std::io::ErrorKind::InvalidData, "bad manifest");
    assert!(!is_transient_transport_error(&error));
}

#[tokio::test]
async fn forward_progress_updates_the_business_checkpoint_and_emits_events() {
    let (event_tx, mut event_rx) = unbounded_channel::<NetworkEvent>();
    let state = RuntimeState::new(event_tx, Arc::new(std::sync::atomic::AtomicU16::new(0)));
    let manager = state.transfer.manager.clone();
    let manifest = network_transfer::FileManifest {
        transfer_id: "progress-transfer".into(),
        file_name: "file.bin".into(),
        file_size: 10,
        modified_at: 0,
        content_hash: "00".repeat(32),
        protocol_version: NETWORK_TRANSFER_PROTOCOL_VERSION,
    };
    assert!(
        manager
            .register_outgoing(manifest, PathBuf::from("file.bin"), "peer-a".into())
            .await
    );
    let (progress_tx, progress_rx) = mpsc::channel(2);
    progress_tx.send((4, 10)).await.unwrap();
    drop(progress_tx);
    forward_progress(
        "progress-transfer".into(),
        "peer-a".into(),
        progress_rx,
        state.event_tx.clone(),
        manager.clone(),
        true,
    )
    .await;
    assert_eq!(
        manager
            .snapshot("progress-transfer")
            .await
            .unwrap()
            .confirmed_offset,
        4
    );
    let event = event_rx.recv().await.expect("progress event");
    assert!(matches!(
        event.payload,
        Some(network_event::Payload::PeerTransferProgress(_))
    ));

    let (stale_tx, stale_rx) = mpsc::channel(1);
    stale_tx.send((8, 10)).await.unwrap();
    drop(stale_tx);
    manager.remove_transfer("progress-transfer").await;
    forward_progress(
        "progress-transfer".into(),
        "peer-a".into(),
        stale_rx,
        state.event_tx.clone(),
        manager,
        true,
    )
    .await;
    assert!(event_rx.try_recv().is_err());
}

#[tokio::test]
async fn incoming_response_routes_local_approval_and_rejects_unknown_transfer_commands() {
    let (event_tx, _event_rx) = unbounded_channel::<NetworkEvent>();
    let state = RuntimeState::new(event_tx, Arc::new(std::sync::atomic::AtomicU16::new(0)));
    let (decision_tx, decision_rx) = oneshot::channel();
    state
        .transfer
        .incoming_decisions
        .write()
        .await
        .insert("incoming".into(), decision_tx);
    respond_to_incoming(
        &state,
        network_protocol::RespondIncomingTransferCommand {
            transfer_id: "incoming".into(),
            accept: true,
        },
    )
    .await
    .expect("local approval");
    assert!(decision_rx.await.expect("decision"));

    let unsupported = dispatch_transfer_command(
        Arc::new(state),
        network_protocol::NetworkCommand {
            command_id: "unsupported".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: None,
        },
    )
    .await
    .expect_err("unsupported transfer command");
    assert_eq!(unsupported.code, NetworkErrorCode::InvalidArgument as i32);
}
