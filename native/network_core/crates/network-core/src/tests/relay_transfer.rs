use super::*;

use crate::connect::CAPABILITY_RELIABLE_STREAM;
use network_protocol::NetworkEvent;
use std::sync::atomic::AtomicU16;
use tokio::sync::mpsc;

#[derive(Debug)]
struct WrappedRelayError(RelayError);

impl std::fmt::Display for WrappedRelayError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(formatter)
    }
}

impl std::error::Error for WrappedRelayError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.0)
    }
}

fn state() -> Arc<RuntimeState> {
    let (event_tx, _event_rx) = mpsc::unbounded_channel::<NetworkEvent>();
    Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))))
}

fn data_client() -> RelayDataClient {
    RelayDataClient::new(
        "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        vec![0u8; 32],
        "credential".into(),
        [0u8; 32],
    )
    .expect("valid unconnected Relay data client")
}

async fn install_relay_path(state: &Arc<RuntimeState>, data: Arc<RelayDataClient>) {
    let registry = Arc::clone(&state.ready_paths);
    let mut manager = crate::connect::PeerPathManager::new(
        crate::connect::PeerId::new("peer-a").expect("valid peer"),
        registry,
    );
    manager
        .publish_ready_with_route(crate::connect::ActiveRoute::relay(Some(data)))
        .expect("relay path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".into(), Arc::new(std::sync::Mutex::new(manager)));
    state.allow_routes_for_test("peer-a").await;
}

async fn relay_lease(state: &Arc<RuntimeState>) -> crate::connect::PathLease {
    state
        .acquire_relay_path_lease("peer-a", CAPABILITY_RELIABLE_STREAM)
        .await
        .expect("relay lease")
}

fn manifest(transfer_id: &str) -> FileManifest {
    FileManifest {
        transfer_id: transfer_id.into(),
        file_name: "payload.bin".into(),
        file_size: 8,
        modified_at: 7,
        content_hash: "a".repeat(64),
        protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
    }
}

#[test]
fn relay_file_name_and_hash_validation_reject_path_tricks() {
    assert!(is_safe_file_name("payload.bin"));
    assert!(is_safe_file_name(&"x".repeat(255)));
    for invalid in [
        "",
        ".",
        "..",
        "../payload.bin",
        "nested/payload.bin",
        "nested\\payload.bin",
        "payload\0.bin",
    ] {
        assert!(!is_safe_file_name(invalid), "{invalid:?} must be rejected");
    }
    assert!(!is_safe_file_name(&"x".repeat(256)));

    assert!(is_sha256_hash(&"a".repeat(64)));
    assert!(is_sha256_hash(&"A".repeat(64)));
    assert!(!is_sha256_hash(&"a".repeat(63)));
    assert!(!is_sha256_hash(&format!("{}g", "a".repeat(63))));

    let mut hasher = Sha256::new();
    hasher.update(b"relay-body");
    let digest = hex::encode(Sha256::digest(b"relay-body"));
    assert!(relay_hash_matches(hasher, &digest.to_uppercase()));
    let mut other_hasher = Sha256::new();
    other_hasher.update(b"other");
    assert!(!relay_hash_matches(other_hasher, &digest));
}

#[test]
fn relay_manifest_and_partial_paths_are_stable_across_sessions() {
    let first = manifest("transfer-a");
    let mut second = first.clone();
    second.modified_at += 1;
    assert_ne!(relay_manifest_hash(&first), relay_manifest_hash(&second));
    assert_eq!(
        relay_partial_path(std::path::Path::new("/tmp/incoming"), "t-1"),
        std::path::PathBuf::from("/tmp/incoming/t-1.part")
    );
}

#[tokio::test]
async fn hash_partial_file_handles_missing_empty_complete_and_truncated_files() {
    let root = std::env::temp_dir().join(format!(
        "ssh-mobile-relay-transfer-test-{}",
        std::process::id()
    ));
    tokio::fs::create_dir_all(&root).await.unwrap();
    let missing = root.join("missing.part");
    let empty_hash = hash_partial_file(&missing, 0).await.unwrap();
    assert_eq!(
        hex::encode(empty_hash.finalize()),
        hex::encode(Sha256::digest([]))
    );

    let complete = root.join("complete.part");
    tokio::fs::write(&complete, b"abcdef").await.unwrap();
    let prefix = hash_partial_file(&complete, 3).await.unwrap();
    assert_eq!(
        hex::encode(prefix.finalize()),
        hex::encode(Sha256::digest(b"abc"))
    );
    let all = hash_partial_file(&complete, 6).await.unwrap();
    assert_eq!(
        hex::encode(all.finalize()),
        hex::encode(Sha256::digest(b"abcdef"))
    );
    let error = hash_partial_file(&complete, 7)
        .await
        .expect_err("declared offset beyond file must fail");
    assert_eq!(
        error.downcast_ref::<std::io::Error>().unwrap().kind(),
        std::io::ErrorKind::UnexpectedEof
    );

    tokio::fs::remove_dir_all(&root).await.unwrap();
}

#[test]
fn transient_relay_error_detection_walks_wrapped_sources() {
    for error in [
        RelayError::NotConnected,
        RelayError::Socket("socket closed".into()),
    ] {
        assert!(is_transient_relay_error(&error));
    }
    assert!(!is_transient_relay_error(&RelayError::Protocol(
        "bad frame".into()
    )));
    assert!(is_transient_relay_error(&std::io::Error::new(
        std::io::ErrorKind::ConnectionReset,
        "reset",
    )));
    assert!(!is_transient_relay_error(&std::io::Error::new(
        std::io::ErrorKind::InvalidData,
        "changed source",
    )));
    let wrapped = WrappedRelayError(RelayError::Socket("nested socket".into()));
    assert!(is_transient_relay_error(&wrapped));
}

#[tokio::test]
async fn relay_file_cancel_uses_data_envelope_and_reports_socket_state() {
    let data = data_client();
    assert!(matches!(
        send_file_cancel(&data, "transfer-a").await,
        Err(RelayError::NotConnected)
    ));
}

#[tokio::test]
async fn cancel_relay_incoming_removes_pending_session_and_checkpoint() {
    let state = state();
    let root = std::env::temp_dir().join(format!(
        "ssh-mobile-relay-cancel-test-{}",
        std::process::id()
    ));
    tokio::fs::create_dir_all(&root).await.unwrap();
    *state.lifecycle.receive_directory.write().await = Some(root.clone());

    let transfer_id = "cancel-transfer";
    assert!(
        state
            .transfer
            .manager
            .register_incoming(manifest(transfer_id), "peer-a".into())
            .await
    );
    state.relay.pending_incoming.write().await.insert(
        transfer_id.into(),
        PendingRelayIncoming {
            transfer_id: transfer_id.into(),
            session_id: "session-cancel".into(),
            sender_id: "peer-a".into(),
            manifest: manifest(transfer_id),
            manifest_hash: "a".repeat(64),
            crypto_session_id: "crypto-session".into(),
        },
    );
    let partial = relay_partial_path(&root, transfer_id);
    tokio::fs::write(&partial, b"partial").await.unwrap();

    cancel_relay_incoming(&state, transfer_id).await;
    assert!(state.relay.pending_incoming.read().await.is_empty());
    assert!(state.transfer.manager.snapshot(transfer_id).await.is_none());
    assert!(!partial.exists());
    tokio::fs::remove_dir_all(&root).await.unwrap();
}

#[tokio::test]
async fn cancel_relay_incoming_removes_active_by_transfer_or_session_key() {
    let state = state();
    let root = std::env::temp_dir().join(format!(
        "ssh-mobile-relay-active-cancel-test-{}",
        std::process::id()
    ));
    tokio::fs::create_dir_all(&root).await.unwrap();
    *state.lifecycle.receive_directory.write().await = Some(root.clone());
    let transfer_id = "active-transfer";
    assert!(
        state
            .transfer
            .manager
            .register_incoming(manifest(transfer_id), "peer-a".into())
            .await
    );
    let temporary_path = relay_partial_path(&root, transfer_id);
    tokio::fs::write(&temporary_path, b"active").await.unwrap();
    state.relay.active_incoming.lock().await.insert(
        transfer_id.into(),
        ActiveRelayIncoming {
            offer: PendingRelayIncoming {
                transfer_id: transfer_id.into(),
                session_id: "session-active".into(),
                sender_id: "peer-a".into(),
                manifest: manifest(transfer_id),
                manifest_hash: "a".repeat(64),
                crypto_session_id: "crypto-active".into(),
            },
            file: None,
            temporary_path: temporary_path.clone(),
            final_path: root.join("payload.bin"),
            next_sequence: 0,
            received_bytes: 0,
            hasher: Sha256::new(),
            already_completed: false,
        },
    );

    cancel_relay_incoming(&state, "session-active").await;
    assert!(state.relay.active_incoming.lock().await.is_empty());
    assert!(state.transfer.manager.snapshot(transfer_id).await.is_none());
    assert!(!temporary_path.exists());
    tokio::fs::remove_dir_all(&root).await.unwrap();
}

#[tokio::test]
async fn send_file_over_relay_without_a_current_path_fails_closed() {
    let state = state();
    assert!(state
        .acquire_relay_path_lease("peer-a", CAPABILITY_RELIABLE_STREAM)
        .await
        .is_err());
}

#[tokio::test]
async fn relay_send_checks_source_manifest_and_offset_before_socket_work() {
    let root = std::env::temp_dir().join(format!(
        "ssh-mobile-relay-send-boundary-{}",
        std::process::id()
    ));
    tokio::fs::create_dir_all(&root).await.unwrap();
    let source = root.join("payload.bin");
    tokio::fs::write(&source, b"payload!").await.unwrap();
    let offset_source = root.join("offset.bin");
    tokio::fs::write(&offset_source, b"payload!").await.unwrap();

    let make_state = || async {
        let state = state();
        *state.lifecycle.identity.write().await = Some(Arc::new(
            network_identity::DeviceIdentity::from_private_keys("sender".into(), [9; 32], [10; 32]),
        ));
        install_relay_path(&state, Arc::new(data_client())).await;
        state
    };
    let peer = PeerConfig {
        endpoint: None,
        identity_public_key: [1; 32],
        e2e_public_key: [2; 32],
        e2ee_policy: network_protocol::E2eePolicy::Required,
    };
    let actual_manifest = network_transfer::build_file_manifest("relay-send".into(), &source)
        .await
        .expect("source manifest");

    let paused_state = make_state().await;
    assert!(
        paused_state
            .transfer
            .manager
            .register_outgoing(actual_manifest.clone(), source.clone(), "peer-a".into())
            .await
    );
    send_file_over_relay(
        peer.clone(),
        ResumableTransfer {
            transfer_id: "relay-send".into(),
            peer_id: "peer-a".into(),
            session_id: "session-a".into(),
            source_path: source.clone(),
            manifest: actual_manifest.clone(),
            offset: 0,
        },
        Arc::clone(&paused_state),
        relay_lease(&paused_state).await,
    )
    .await;
    assert_eq!(
        paused_state
            .transfer
            .manager
            .snapshot("relay-send")
            .await
            .expect("socket loss should retain resumable transfer")
            .state,
        network_transfer::TransferState::Paused
    );

    let changed_state = make_state().await;
    assert!(
        changed_state
            .transfer
            .manager
            .register_outgoing(actual_manifest.clone(), source.clone(), "peer-a".into())
            .await
    );
    tokio::fs::write(&source, b"changed!").await.unwrap();
    send_file_over_relay(
        peer.clone(),
        ResumableTransfer {
            transfer_id: "relay-send".into(),
            peer_id: "peer-a".into(),
            session_id: "session-b".into(),
            source_path: source.clone(),
            manifest: actual_manifest.clone(),
            offset: 0,
        },
        Arc::clone(&changed_state),
        relay_lease(&changed_state).await,
    )
    .await;
    assert!(changed_state
        .transfer
        .manager
        .snapshot("relay-send")
        .await
        .is_none());

    let offset_state = make_state().await;
    let offset_manifest =
        network_transfer::build_file_manifest("relay-send".into(), &offset_source)
            .await
            .expect("offset source manifest");
    assert!(
        offset_state
            .transfer
            .manager
            .register_outgoing(
                offset_manifest.clone(),
                offset_source.clone(),
                "peer-a".into()
            )
            .await
    );
    send_file_over_relay(
        peer,
        ResumableTransfer {
            transfer_id: "relay-send".into(),
            peer_id: "peer-a".into(),
            session_id: "session-c".into(),
            source_path: offset_source,
            manifest: offset_manifest,
            offset: 1,
        },
        Arc::clone(&offset_state),
        relay_lease(&offset_state).await,
    )
    .await;
    assert!(offset_state
        .transfer
        .manager
        .snapshot("relay-send")
        .await
        .is_none());
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn responding_to_unknown_relay_offer_returns_typed_invalid_argument() {
    let state = state();
    let error = respond_to_relay_incoming(&state, "missing-transfer", false)
        .await
        .expect_err("unknown offer cannot be approved");
    assert_eq!(error.code, NetworkErrorCode::InvalidArgument as i32);
}

#[tokio::test]
async fn relay_offer_admission_rejects_unregistered_and_malformed_envelopes() {
    let state = state();
    let data = Arc::new(data_client());
    let error = receive_relay_offer(&state, &data, "peer-a", b"")
        .await
        .expect_err("unknown Relay sender must be rejected");
    assert!(error.to_string().contains("registered peer"));

    state.peers.write().await.insert(
        "peer-a".into(),
        PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test("peer-a").await;
    let error = receive_relay_offer(&state, &data, "peer-a", &[0; 31])
        .await
        .expect_err("short Relay offers must be rejected");
    assert!(error.to_string().contains("truncated"));

    let mut invalid_session = b"A0000000000000000000000000000000".to_vec();
    invalid_session.extend_from_slice(b"payload");
    let error = receive_relay_offer(&state, &data, "peer-a", &invalid_session)
        .await
        .expect_err("uppercase Relay session IDs must be rejected");
    assert!(error.to_string().contains("session ID"));

    let mut invalid_base64 = b"00000000000000000000000000000000".to_vec();
    invalid_base64.extend_from_slice(b"!");
    let error = receive_relay_offer(&state, &data, "peer-a", &invalid_base64)
        .await
        .expect_err("malformed Relay offer payloads must be rejected");
    assert!(!error.to_string().is_empty());

    let state_without_identity = self::state();
    state_without_identity.peers.write().await.insert(
        "peer-a".into(),
        PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state_without_identity.allow_routes_for_test("peer-a").await;
    let error = receive_relay_offer(
        &state_without_identity,
        &data,
        "peer-a",
        b"00000000000000000000000000000000",
    )
    .await
    .expect_err("Relay offers require the local runtime identity");
    assert!(error.to_string().contains("identity"));

    let pending = manifest("pending-without-path");
    state.relay.pending_incoming.write().await.insert(
        pending.transfer_id.clone(),
        PendingRelayIncoming {
            transfer_id: pending.transfer_id.clone(),
            session_id: "00000000000000000000000000000000".into(),
            sender_id: "peer-a".into(),
            manifest: pending,
            manifest_hash: "a".repeat(64),
            crypto_session_id: "crypto-session".into(),
        },
    );
    let error = respond_to_relay_incoming(&state, "pending-without-path", true)
        .await
        .expect_err("Relay approval must require the current data path");
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);
}
