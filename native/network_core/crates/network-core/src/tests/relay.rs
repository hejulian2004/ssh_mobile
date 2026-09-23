use super::*;

/// 验证 Relay offer 只接受完整的 SHA-256 十六进制摘要。
#[test]
fn relay_offer_requires_sha256_hash() {
    let digest = hex::encode(Sha256::digest(b"relay-V2"));
    assert!(is_sha256_hash(&digest));
    assert!(!is_sha256_hash(&digest[..63]));
    let mut invalid = digest.clone();
    invalid.replace_range(0..1, "z");
    assert!(!is_sha256_hash(&invalid));
}

/// 验证接收哈希不匹配时不会被视为完成。
#[test]
fn relay_hash_mismatch_is_rejected() {
    let mut hasher = Sha256::new();
    hasher.update(b"received");
    assert!(!relay_hash_matches(
        hasher,
        &hex::encode(Sha256::digest(b"offered"))
    ));
}

#[test]
fn relay_resume_offset_requires_fixed_chunk_boundary() {
    assert!(valid_relay_offset(0, RELAY_FILE_CHUNK_BYTES * 4 + 7));
    assert!(valid_relay_offset(
        RELAY_FILE_CHUNK_BYTES * 3,
        RELAY_FILE_CHUNK_BYTES * 4 + 7
    ));
    assert!(valid_relay_offset(
        RELAY_FILE_CHUNK_BYTES * 4 + 7,
        RELAY_FILE_CHUNK_BYTES * 4 + 7
    ));
    assert!(!valid_relay_offset(
        RELAY_FILE_CHUNK_BYTES * 3 + 1,
        RELAY_FILE_CHUNK_BYTES * 4 + 7
    ));
    assert!(!valid_relay_offset(
        RELAY_FILE_CHUNK_BYTES * 5,
        RELAY_FILE_CHUNK_BYTES * 4 + 7
    ));
}

#[test]
fn relay_acceptance_binds_transfer_manifest_hash_file_hash_and_offset() {
    let payload = RelayAcceptancePayload {
        v: 1,
        transfer_id: "transfer-1".into(),
        manifest_hash: "a".repeat(64),
        file_hash: "b".repeat(64),
        offset: RELAY_FILE_CHUNK_BYTES,
    };
    let encoded = serde_json::to_string(&payload).expect("encode acceptance");
    let decoded: RelayAcceptance = serde_json::from_str(&encoded).expect("decode acceptance");
    assert_eq!(decoded.v, 1);
    assert_eq!(decoded.transfer_id, "transfer-1");
    assert_eq!(decoded.manifest_hash, "a".repeat(64));
    assert_eq!(decoded.file_hash, "b".repeat(64));
    assert_eq!(decoded.offset, RELAY_FILE_CHUNK_BYTES);
}

#[test]
fn relay_manifest_hash_changes_when_source_manifest_changes() {
    let manifest = FileManifest {
        transfer_id: "transfer-1".into(),
        file_name: "payload.bin".into(),
        file_size: 4,
        modified_at: 1,
        content_hash: "a".repeat(64),
        protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
    };
    let mut changed = manifest.clone();
    changed.modified_at = 2;
    assert_ne!(
        relay_manifest_hash(&manifest),
        relay_manifest_hash(&changed)
    );
}

#[test]
fn relay_connect_error_maps_credential_expired_and_identity_conflict_as_terminal() {
    let expired = relay_connect_protocol_error(
        &RelayError::CredentialExpired("expired".into()),
        "configure_relay",
    );
    assert_eq!(expired.code, NetworkErrorCode::CredentialExpired as i32);
    assert_eq!(
        expired.retry_disposition,
        RetryDisposition::RefreshCredentialThenRetry as i32
    );

    let conflict = relay_connect_protocol_error(
        &RelayError::IdentityConflict("conflict".into()),
        "configure_relay",
    );
    assert_eq!(conflict.code, NetworkErrorCode::IdentityConflict as i32);
    assert_eq!(conflict.retry_disposition, RetryDisposition::NoRetry as i32);

    let transient =
        relay_connect_protocol_error(&RelayError::Socket("boom".into()), "configure_relay");
    assert_eq!(transient.code, NetworkErrorCode::RelayError as i32);
    assert_eq!(
        transient.retry_disposition,
        RetryDisposition::Unspecified as i32
    );
}

#[test]
fn relay_reconnect_is_suppressed_when_credential_is_stale() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    state
        .relay
        .credential_stale
        .store(true, std::sync::atomic::Ordering::Release);
    schedule_relay_reconnect(Arc::clone(&state));
    assert!(!state
        .relay
        .reconnect_active
        .load(std::sync::atomic::Ordering::Acquire));
    assert!(state.relay.reconnect_task.lock().unwrap().is_none());
}

/// 回归 #1：意外控制面断开必须清空 relay_control sink 并调度重连，否则重连
/// 循环第一处守卫（relay_control.is_some()）会立即 break——死 client 仍占位，
/// setup_v2_control_plane 永远不会被再次调用，Discovery/Resolve/Reservation/
/// Realtime 信令持续失效，直到 Dart 重新下发 ConfigureRelayCommand。
#[tokio::test]
async fn control_disconnect_clears_slot_and_reconnect_loop_reruns_setup() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    state.lifecycle.identity.write().await.replace(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        ),
    ));
    // 快速失败的 loopback 端点：重连循环会立刻尝试 setup_v2_control_plane，
    // 而不是卡在 relay_control 守卫上。URL 必须是无路径的 origin。
    *state.relay.config.write().await = Some(RelayReconnectConfig {
        relay_url: "ws://127.0.0.1:9".into(),
        credential: "credential".into(),
        signing_seed: [0u8; 32],
    });
    let dead_control = Arc::new(
        RelayControlClient::new(
            "ws://127.0.0.1:9".into(),
            "device-a".into(),
            "credential".into(),
            [0u8; 32],
        )
        .expect("control client"),
    );
    *state.relay.control.write().await = Some(dead_control.clone());

    let (events_tx, events_rx) = mpsc::channel(16);
    let consume_state = Arc::clone(&state);
    let handler = tokio::spawn(async move {
        consume_control_events(consume_state, dead_control, events_rx).await;
    });
    events_tx
        .send(ControlEvent::Disconnected {
            reason: "test disconnect".into(),
        })
        .await
        .expect("send disconnected");
    drop(events_tx);
    handler.await.expect("control consumer should exit");

    // 意外断开必须清空控制面 sink，否则重连循环会在死 client 处立即 break。
    assert!(
        state.relay.control.read().await.is_none(),
        "unexpected disconnect must clear the control-plane slot"
    );
    assert!(
        state
            .relay
            .reconnect_active
            .load(std::sync::atomic::Ordering::Acquire),
        "reconnect must be scheduled after an unexpected disconnect"
    );
    // 等待超过首个退避周期：重连循环必须仍在重试（setup 反复执行），而不是在
    // relay_control 守卫处立即退出。
    tokio::time::sleep(std::time::Duration::from_millis(600)).await;
    assert!(
        state
            .relay
            .reconnect_active
            .load(std::sync::atomic::Ordering::Acquire),
        "reconnect loop must keep retrying instead of breaking on the stale control slot"
    );
}

#[tokio::test]
async fn remote_candidate_cache_invalidates_on_epoch_and_ready_ttl_change() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let cache = network_nat::ResolvedCandidateCache::from_snapshot(
        network_nat::ResolvedCandidateSnapshot {
            runtime_epoch: NatRuntimeEpoch { high: 1, low: 1 },
            revision: 1,
            candidates: vec![network_nat::CandidatePayloadV2 {
                version: network_nat::CANDIDATE_PAYLOAD_VERSION,
                candidate_id: "lan-1".into(),
                endpoint: std::net::SocketAddr::from(([192, 168, 1, 10], 41001)),
                kind: network_nat::CandidateKind::Lan,
                transport_capabilities: vec![network_nat::CandidateTransport::Quic],
                priority: 100,
                interface: "wifi".into(),
                generation: 1,
            }],
            server_presence_ttl: Some(Duration::from_secs(60)),
        },
        Instant::now(),
    )
    .expect("valid candidate cache");
    state
        .remote_candidate_cache
        .write()
        .await
        .insert("peer-a".into(), cache.clone());

    let control = Arc::new(
        RelayControlClient::new(
            "ws://127.0.0.1:9".into(),
            "device-a".into(),
            "credential".into(),
            [0u8; 32],
        )
        .expect("control client"),
    );
    let (events_tx, events_rx) = mpsc::channel(1);
    let consumer_state = Arc::clone(&state);
    let consumer = tokio::spawn(async move {
        consume_control_events(consumer_state, control, events_rx).await;
    });
    events_tx
        .send(ControlEvent::PeerAvailableHint(
            network_relay::v2::PeerAvailableHint {
                device_id: "peer-a".into(),
                runtime_epoch: Some(RuntimeEpoch { high: 2, low: 1 }),
                revision: 2,
            },
        ))
        .await
        .expect("send available hint");
    drop(events_tx);
    consumer.await.expect("control event consumer");
    assert!(state
        .remote_candidate_cache
        .read()
        .await
        .get("peer-a")
        .expect("cache entry")
        .stage_a_candidates_at(Instant::now())
        .is_none());

    state
        .remote_candidate_cache
        .write()
        .await
        .insert("peer-b".into(), cache);
    clear_remote_candidate_cache_if_ready_ttl_changed(
        &state,
        Some(Duration::from_secs(60)),
        Some(Duration::from_secs(30)),
    )
    .await;
    assert!(state.remote_candidate_cache.read().await.is_empty());
}

/// 回归 #2：关闭一条 reservation 数据连接只移除该对端的物理 Relay path，
/// 另一对端的活跃数据连接必须原样保留。
#[tokio::test]
async fn relay_data_disconnect_removes_only_the_matching_peer_entry() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let data_b = Arc::new(
        RelayDataClient::new(
            "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            vec![0u8; 32],
            "credential".into(),
            [0u8; 32],
        )
        .expect("peer-b data client"),
    );
    let data_c = Arc::new(
        RelayDataClient::new(
            "ws://127.0.0.1:9/v2/relay/7a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            "7a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            vec![0u8; 32],
            "credential".into(),
            [0u8; 32],
        )
        .expect("peer-c data client"),
    );
    let session_b = match state
        .begin_connect("peer-b", crate::connect::DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        crate::runtime::ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected peer-b session decision: {decision:?}"),
    };
    let session_c = match state
        .begin_connect("peer-c", crate::connect::DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        crate::runtime::ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected peer-c session decision: {decision:?}"),
    };
    state.allow_routes_for_test("peer-b").await;
    state.allow_routes_for_test("peer-c").await;
    assert!(
        state
            .mark_relay_route_connected("peer-b", session_b, Some(data_b.clone()))
            .await
    );
    assert!(
        state
            .mark_relay_route_connected("peer-c", session_c, Some(data_c.clone()))
            .await
    );

    relay_data_disconnected(Arc::clone(&state), data_b, "peer-b".into()).await;

    assert!(
        state
            .path_relay_data("peer-c")
            .await
            .is_some_and(|current| Arc::ptr_eq(&current, &data_c)),
        "peer-c data connection must survive peer-b disconnecting"
    );
    assert!(
        state.path_relay_data("peer-b").await.is_none(),
        "only the disconnected peer's path must be removed"
    );
}

/// 回归 #5a：控制面 socket 未能建立时，configure_relay_for_state 必须发布类型化
/// Failed（而不是伪造 Connected），并返回错误。
#[tokio::test]
async fn configure_relay_emits_failed_when_control_connect_fails() {
    let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    state.lifecycle.identity.write().await.replace(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        ),
    ));
    let command = ConfigureRelayCommand {
        // 无路径 origin：控制面 socket 建立失败（连接被拒绝）。
        relay_url: "ws://127.0.0.1:9".into(),
        relay_credential: "credential".into(),
        relay_signing_seed: vec![0u8; 32],
    };
    let result = configure_relay_for_state(Arc::clone(&state), command).await;
    assert!(
        result.is_err(),
        "failed control connect must fail configure"
    );
    assert!(
        !state
            .relay
            .credential_stale
            .load(std::sync::atomic::Ordering::Acquire),
        "transient socket failure is not a credential error"
    );

    let mut saw_failed = false;
    while let Ok(event) = event_rx.try_recv() {
        if let Some(network_protocol::network_event::Payload::RelayStateChanged(change)) =
            event.payload
        {
            assert_ne!(
                change.state,
                network_protocol::RelayConnectionState::Connected as i32,
                "control connect failure must not emit Connected"
            );
            if change.state == network_protocol::RelayConnectionState::Failed as i32 {
                saw_failed = true;
            }
        }
    }
    assert!(saw_failed, "control connect failure must emit Failed");
}

/// 回归 #5b：凭据过期（服务端以 HTTP 401 + code 12 拒绝）时，configure 必须
/// 标记 relay_credential_stale 并停止重连（现有 stale 守卫随后生效），且发布携带
/// CredentialExpired 的 Failed，Dart 据此下发新的 ConfigureRelayCommand。
#[tokio::test]
async fn configure_relay_with_expired_credential_marks_stale_and_emits_failed() {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind fake control listener");
    let address = listener.local_addr().expect("fake control address");
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.expect("accept control connect");
        // 读完请求头，随后以设备面 code 12（凭据过期）拒绝。
        let mut request = vec![0u8; 4096];
        let mut used = 0usize;
        loop {
            let read = stream
                .read(&mut request[used..])
                .await
                .expect("read control request");
            if read == 0 {
                break;
            }
            used += read;
            if request[..used]
                .windows(4)
                .any(|window| window == b"\r\n\r\n")
            {
                break;
            }
        }
        // 响应头与 body 必须一次性写入：tungstenite 客户端只在同一次 read 中
        // 捕获 header 之后的 tail 作为错误响应 body，分两次写会丢失 {"code":12}。
        let body = "{\"code\":12}";
        let response = format!(
                "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
        stream
            .write_all(response.as_bytes())
            .await
            .expect("write rejection response");
        stream.flush().await.expect("flush");
    });

    let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    state.lifecycle.identity.write().await.replace(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        ),
    ));
    let command = ConfigureRelayCommand {
        relay_url: format!("ws://{address}"),
        relay_credential: "expired-credential".into(),
        relay_signing_seed: vec![0u8; 32],
    };
    let result = configure_relay_for_state(Arc::clone(&state), command).await;
    let error = result.expect_err("expired credential must fail configure");
    assert_eq!(error.code, NetworkErrorCode::CredentialExpired as i32);
    assert!(
        state
            .relay
            .credential_stale
            .load(std::sync::atomic::Ordering::Acquire),
        "expired credential must mark the credential stale"
    );
    assert!(
        !state
            .relay
            .reconnect_active
            .load(std::sync::atomic::Ordering::Acquire),
        "expired credential must stop scheduling reconnects"
    );
    assert!(
        state.relay.reconnect_task.lock().unwrap().is_none(),
        "expired credential must not leave a reconnect task behind"
    );

    let mut saw_failed = false;
    while let Ok(event) = event_rx.try_recv() {
        if let Some(network_protocol::network_event::Payload::RelayStateChanged(change)) =
            event.payload
        {
            if change.state == network_protocol::RelayConnectionState::Failed as i32 {
                saw_failed = true;
                assert_eq!(
                        change.error.as_ref().map(|error| error.code),
                        Some(NetworkErrorCode::CredentialExpired as i32),
                        "Failed must carry the CredentialExpired error so Dart can re-issue credentials"
                    );
            }
        }
    }
    assert!(saw_failed, "expired credential must emit Failed");
    server.await.expect("fake control server should finish");
}

#[test]
fn relay_file_chunk_uses_session_application_context() {
    let sender = network_identity::DeviceIdentity::from_private_keys(
        "sender".into(),
        [11u8; 32],
        [21u8; 32],
    );
    let receiver = network_identity::DeviceIdentity::from_private_keys(
        "receiver".into(),
        [12u8; 32],
        [22u8; 32],
    );
    let session_id = "0000000000000001";
    let transfer_id = "relay-transfer";
    let manifest_hash = "a".repeat(64);
    let aad = crypto::file_chunk_aad(session_id, transfer_id, &manifest_hash, 3);
    let mut sender_context = crate::crypto::CryptoContext::from_identity(
        &sender,
        *receiver.public_e2e_key().as_bytes(),
        session_id,
    )
    .expect("sender Session crypto");
    let mut receiver_context = crate::crypto::CryptoContext::from_identity(
        &receiver,
        *sender.public_e2e_key().as_bytes(),
        session_id,
    )
    .expect("receiver Session crypto");
    let ciphertext = sender_context
        .encrypt(&aad, b"opaque relay chunk")
        .expect("encrypt Relay chunk");
    assert_ne!(ciphertext, b"opaque relay chunk");
    assert_eq!(
        receiver_context.decrypt(&aad, &ciphertext).unwrap(),
        b"opaque relay chunk"
    );
    assert!(receiver_context
        .decrypt(
            &crypto::file_chunk_aad(session_id, transfer_id, &manifest_hash, 4),
            &ciphertext,
        )
        .is_err());
}

/// 构造一个合法的 Relay 文件 Manifest（满足 validate / is_safe_file_name）。
fn relay_test_manifest(transfer_id: &str) -> FileManifest {
    FileManifest {
        transfer_id: transfer_id.into(),
        file_name: "payload.bin".into(),
        file_size: RELAY_FILE_CHUNK_BYTES * 2,
        modified_at: 1,
        content_hash: "a".repeat(64),
        protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
    }
}

fn relay_test_active(pending: PendingRelayIncoming) -> ActiveRelayIncoming {
    ActiveRelayIncoming {
        offer: pending,
        file: None,
        temporary_path: PathBuf::from("/tmp/relay-test.part"),
        final_path: PathBuf::from("/tmp/relay-test.bin"),
        next_sequence: 0,
        received_bytes: 0,
        hasher: Sha256::new(),
        already_completed: false,
    }
}

fn relay_pending_for(
    manifest: FileManifest,
    session_id: &str,
    sender_id: &str,
) -> PendingRelayIncoming {
    PendingRelayIncoming {
        transfer_id: manifest.transfer_id.clone(),
        session_id: session_id.into(),
        sender_id: sender_id.into(),
        manifest_hash: relay_manifest_hash(&manifest),
        manifest,
        crypto_session_id: "00000000000000aa".into(),
    }
}

/// 构造一条可被 receive_relay_offer 接受的 Relay 文件 Offer 信封：
/// body = [session_id 32][URL_SAFE_NO_PAD base64(encrypted offer)]。
fn build_relay_offer_envelope(
    sender: &network_identity::DeviceIdentity,
    receiver: &network_identity::DeviceIdentity,
    session_id: &str,
    manifest: &FileManifest,
    crypto_session_id: &str,
) -> Vec<u8> {
    let offer = relay_offer_value(sender, receiver, session_id, manifest, crypto_session_id);
    encode_relay_offer_value(receiver, session_id, &offer)
}

fn relay_offer_value(
    sender: &network_identity::DeviceIdentity,
    receiver: &network_identity::DeviceIdentity,
    session_id: &str,
    manifest: &FileManifest,
    crypto_session_id: &str,
) -> serde_json::Value {
    serde_json::json!({
        "v": 1,
        "crypto_suite": APPLICATION_CRYPTO_SUITE,
        "session_id": session_id,
        "crypto_session_id": crypto_session_id,
        "transfer_id": manifest.transfer_id,
        "manifest_hash": relay_manifest_hash(manifest),
        "sender_id": sender.device_id,
        "receiver_id": receiver.device_id,
        "file_name": manifest.file_name,
        "file_size": manifest.file_size,
        "modified_at": manifest.modified_at,
        "content_hash": manifest.content_hash,
    })
}

fn encode_relay_offer_value(
    receiver: &network_identity::DeviceIdentity,
    session_id: &str,
    value: &serde_json::Value,
) -> Vec<u8> {
    use base64::Engine as _;
    let offer = serde_json::to_vec(value).expect("serialize Relay offer");
    let session_bytes: [u8; 16] = hex::decode(session_id)
        .expect("hex session")
        .try_into()
        .expect("session must decode to 16 bytes");
    let encrypted = crypto::encrypt_application_offer(
        &offer,
        *receiver.public_e2e_key().as_bytes(),
        &session_bytes,
    )
    .expect("encrypt Relay offer");
    let encoded = URL_SAFE_NO_PAD.encode(encrypted);
    let mut envelope = Vec::with_capacity(32 + encoded.len());
    envelope.extend_from_slice(session_id.as_bytes());
    envelope.extend_from_slice(encoded.as_bytes());
    envelope
}

fn disconnected_relay_data() -> Arc<RelayDataClient> {
    Arc::new(
        RelayDataClient::new(
            "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            vec![0u8; 32],
            "credential".into(),
            [0u8; 32],
        )
        .expect("valid Relay data client"),
    )
}

async fn relay_state_with_peer(
    sender: &network_identity::DeviceIdentity,
    receiver: &network_identity::DeviceIdentity,
) -> Arc<RuntimeState> {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let receiver_copy = network_identity::DeviceIdentity::from_private_keys(
        receiver.device_id.clone(),
        receiver.identity_key.to_bytes(),
        receiver.e2e_key.to_bytes(),
    );
    state
        .lifecycle
        .identity
        .write()
        .await
        .replace(Arc::new(receiver_copy));
    state.peers.write().await.insert(
        sender.device_id.clone(),
        PeerConfig {
            endpoint: None,
            identity_public_key: sender.public_identity_key().to_bytes(),
            e2e_public_key: sender.public_e2e_key().to_bytes(),
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test(&sender.device_id).await;
    state
}

async fn install_disconnected_relay_test_path(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
) {
    let session_id = crate::session::SessionId::new();
    state
        .connection_sessions
        .register_pending_session("sender", session_id)
        .await
        .expect("reserve Relay test session");
    state
        .admit_authenticated_session("sender", Some(session_id), "relay-test-binding")
        .await
        .expect("admit Relay test session");
    assert!(
        state
            .mark_relay_route_connected("sender", session_id, Some(Arc::clone(data)))
            .await
    );
}

fn relay_temp_dir(label: &str) -> std::path::PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    std::env::temp_dir().join(format!(
        "ssh-mobile-relay-{label}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ))
}

fn relay_chunk_manifest(transfer_id: &str, payload: &[u8]) -> FileManifest {
    FileManifest {
        transfer_id: transfer_id.into(),
        file_name: "chunk.bin".into(),
        file_size: payload.len() as u64,
        modified_at: 1,
        content_hash: hex::encode(Sha256::digest(payload)),
        protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
    }
}

fn install_relay_test_crypto(
    state: &RuntimeState,
    peer_id: &str,
    session_id: &str,
    root_key: [u8; 32],
    initiator: bool,
) {
    state
        .install_crypto_material(
            peer_id,
            session_id,
            &SessionCryptoMaterial {
                root_key,
                local_session_binding: session_id.into(),
                remote_session_binding: session_id.into(),
                initiator,
                e2ee_policy: crate::crypto_handshake::path_handshake::E2eePolicy::Required,
                path_security: crate::crypto_handshake::path_handshake::PathSecurity::E2ee,
            },
        )
        .expect("install test Relay application crypto");
}

struct RelayCompletionSetup<'a> {
    session_id: &'a str,
    sender_id: &'a str,
    root: &'a std::path::Path,
    payload: Option<&'a [u8]>,
    already_completed: bool,
    final_path: std::path::PathBuf,
}

async fn setup_relay_completion_active(
    state: &Arc<RuntimeState>,
    manifest: &FileManifest,
    setup: RelayCompletionSetup<'_>,
) -> std::path::PathBuf {
    tokio::fs::create_dir_all(setup.root).await.unwrap();
    assert!(
        state
            .transfer
            .manager
            .register_incoming(manifest.clone(), setup.sender_id.into())
            .await
    );
    assert!(
        state
            .transfer
            .manager
            .mark_transferring(&manifest.transfer_id)
            .await
    );
    let temporary_path = setup.root.join(format!("{}.part", manifest.transfer_id));
    let (file, hasher, received_bytes) = if let Some(payload) = setup.payload {
        tokio::fs::write(&temporary_path, payload).await.unwrap();
        let file = tokio::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&temporary_path)
            .await
            .unwrap();
        let mut hasher = Sha256::new();
        hasher.update(payload);
        (Some(file), hasher, payload.len() as u64)
    } else {
        (None, Sha256::new(), manifest.file_size)
    };
    state.relay.active_incoming.lock().await.insert(
        manifest.transfer_id.clone(),
        ActiveRelayIncoming {
            offer: relay_pending_for(manifest.clone(), setup.session_id, setup.sender_id),
            file,
            temporary_path: temporary_path.clone(),
            final_path: setup.final_path,
            next_sequence: 0,
            received_bytes,
            hasher,
            already_completed: setup.already_completed,
        },
    );
    temporary_path
}

/// 回归 #2：满块 Relay 分块（RELAY_FILE_CHUNK_BYTES 明文）加密并包上
/// DATA_ENV_FILE_CHUNK 信封后必须仍落在数据面载荷上限（512 KiB）之内；否则
/// RelayDataClient::send 会以 InvalidConfiguration 拒绝，导致整份文件发送失败。
#[tokio::test]
async fn relay_file_chunk_full_size_fits_data_plane_bound() {
    let sender = network_identity::DeviceIdentity::from_private_keys(
        "sender".into(),
        [11u8; 32],
        [21u8; 32],
    );
    let receiver = network_identity::DeviceIdentity::from_private_keys(
        "receiver".into(),
        [12u8; 32],
        [22u8; 32],
    );
    let session_id = "0000000000000001";
    let transfer_id = "relay-transfer";
    let manifest_hash = "a".repeat(64);
    let aad = crypto::file_chunk_aad(session_id, transfer_id, &manifest_hash, 3);
    let mut sender_context = crate::crypto::CryptoContext::from_identity(
        &sender,
        *receiver.public_e2e_key().as_bytes(),
        session_id,
    )
    .expect("sender Session crypto");
    let plaintext = vec![0xABu8; RELAY_FILE_CHUNK_BYTES as usize];
    let ciphertext = sender_context
        .encrypt(&aad, &plaintext)
        .expect("encrypt full Relay chunk");
    // 数据面单帧载荷上限（network-relay v2 data_client MAX_DATA_PAYLOAD_BYTES）。
    const DATA_PLANE_MAX_PAYLOAD_BYTES: usize = 512 * 1024;
    // 明文分块 + 信封固定开销必须不超上限（旧的 512 KiB 明文会超限被 send 拒绝）。
    assert!(
        RELAY_FILE_CHUNK_BYTES as usize + RELAY_FILE_CHUNK_ENVELOPE_OVERHEAD_BYTES
            <= DATA_PLANE_MAX_PAYLOAD_BYTES,
        "full-size Relay chunk exceeds the data-plane payload bound"
    );
    // body = [session_id 32][sequence u64 BE][ciphertext]，信封再加 kind 标签(1)。
    let mut body = Vec::with_capacity(40 + ciphertext.len());
    body.extend_from_slice(session_id.as_bytes());
    body.extend_from_slice(&0u64.to_be_bytes());
    body.extend_from_slice(&ciphertext);
    let envelope_len = 1 + body.len();
    assert!(
        envelope_len <= DATA_PLANE_MAX_PAYLOAD_BYTES,
        "full-size Relay chunk envelope ({envelope_len} B) exceeds the 512 KiB data-plane bound"
    );

    let data = Arc::new(
        RelayDataClient::new(
            "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            vec![0u8; 32],
            "credential".into(),
            [0u8; 32],
        )
        .expect("relay data client"),
    );
    // 满块信封必须通过尺寸校验：未连接客户端在出站阶段才报 NotConnected；若尺寸
    // 超限则会在校验处直接报 InvalidConfiguration。
    assert!(matches!(
        send_data_envelope(&data, DATA_ENV_FILE_CHUNK, &body).await,
        Err(RelayError::NotConnected)
    ));
}

/// 回归 #6：单条 reservation 数据面断开（relay_data_disconnected →
/// cleanup_relay_state Some(peer)）只清理该对端的 Relay 状态；另一对端的在途
/// 接收/发送状态（active incoming、acceptance/completion waiter、crypto 握手
/// 队列）原样保留，而不是像旧的全量清理那样把其他对端一并清空。
#[tokio::test]
async fn relay_disconnect_cleanup_is_scoped_to_the_disconnecting_peer() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));

    // peer-b 与 peer-c 各自有在途接收传输 + 等待中的 accept/completion/crypto waiter。
    let manifest_b = relay_test_manifest("relay-transfer-b");
    let manifest_c = relay_test_manifest("relay-transfer-c");
    assert!(
        state
            .transfer
            .manager
            .register_incoming(manifest_b.clone(), "peer-b".into())
            .await
    );
    assert!(
        state
            .transfer
            .manager
            .register_incoming(manifest_c.clone(), "peer-c".into())
            .await
    );
    assert!(
        state
            .transfer
            .manager
            .mark_transferring("relay-transfer-b")
            .await
    );
    state.relay.active_incoming.lock().await.insert(
        "relay-transfer-b".into(),
        relay_test_active(PendingRelayIncoming {
            transfer_id: "relay-transfer-b".into(),
            session_id: "000000000000000000000000000000bb".into(),
            sender_id: "peer-b".into(),
            manifest: manifest_b,
            manifest_hash: "a".repeat(64),
            crypto_session_id: "00000000000000bb".into(),
        }),
    );
    state.relay.active_incoming.lock().await.insert(
        "relay-transfer-c".into(),
        relay_test_active(PendingRelayIncoming {
            transfer_id: "relay-transfer-c".into(),
            session_id: "000000000000000000000000000000cc".into(),
            sender_id: "peer-c".into(),
            manifest: manifest_c,
            manifest_hash: "a".repeat(64),
            crypto_session_id: "00000000000000cc".into(),
        }),
    );
    state
        .relay
        .acceptances
        .write()
        .await
        .insert("relay-transfer-b".into(), oneshot::channel().0);
    state
        .relay
        .acceptances
        .write()
        .await
        .insert("relay-transfer-c".into(), oneshot::channel().0);
    state
        .relay
        .completions
        .write()
        .await
        .insert("relay-transfer-b".into(), oneshot::channel().0);
    state
        .relay
        .completions
        .write()
        .await
        .insert("relay-transfer-c".into(), oneshot::channel().0);
    let (wait_b, _) = mpsc::channel::<(u8, Vec<u8>)>(1);
    let (wait_c, _) = mpsc::channel::<(u8, Vec<u8>)>(1);
    state
        .relay
        .crypto_waiters
        .write()
        .await
        .insert(relay_crypto_key("peer-b", "token-b"), wait_b);
    state
        .relay
        .crypto_waiters
        .write()
        .await
        .insert(relay_crypto_key("peer-c", "token-c"), wait_c);

    // peer-b 断开：只清理 peer-b 的条目，peer-c 的全部保留。
    cleanup_relay_state(&state, Some("peer-b")).await;

    assert!(
        state
            .relay
            .active_incoming
            .lock()
            .await
            .contains_key("relay-transfer-c"),
        "peer-c active incoming must survive peer-b disconnecting"
    );
    assert!(!state
        .relay
        .active_incoming
        .lock()
        .await
        .contains_key("relay-transfer-b"));
    assert!(state
        .relay
        .acceptances
        .read()
        .await
        .contains_key("relay-transfer-c"));
    assert!(!state
        .relay
        .acceptances
        .read()
        .await
        .contains_key("relay-transfer-b"));
    assert!(state
        .relay
        .completions
        .read()
        .await
        .contains_key("relay-transfer-c"));
    assert!(!state
        .relay
        .completions
        .read()
        .await
        .contains_key("relay-transfer-b"));
    assert!(
        state
            .relay
            .crypto_waiters
            .read()
            .await
            .contains_key(&relay_crypto_key("peer-c", "token-c")),
        "peer-c crypto waiter must survive peer-b disconnecting"
    );
    assert!(!state
        .relay
        .crypto_waiters
        .read()
        .await
        .contains_key(&relay_crypto_key("peer-b", "token-b")));
    // peer-c 的接收传输未被暂停；peer-b 的被暂停（保留 checkpoint）。
    assert_eq!(
        state
            .transfer
            .manager
            .snapshot("relay-transfer-c")
            .await
            .unwrap()
            .state,
        network_transfer::TransferState::WaitingApproval
    );
    assert_eq!(
        state
            .transfer
            .manager
            .snapshot("relay-transfer-b")
            .await
            .unwrap()
            .state,
        network_transfer::TransferState::Paused
    );

    // 全部断开（disconnect_relay_data 路径）仍清理所有对端的路径。
    cleanup_relay_state(&state, None).await;
    assert!(state.relay.active_incoming.lock().await.is_empty());
    assert!(state.relay.acceptances.read().await.is_empty());
    assert!(state.relay.completions.read().await.is_empty());
    assert!(state.relay.crypto_waiters.read().await.is_empty());
}

/// 回归 #12：未获批的 Relay 传入 Offer 在审批超时后必须释放 transfer_id；随后
/// 同一 transfer_id 的再 Offer 必须能被 register_incoming 接受（不得报
/// "TransferId is already active"）。
#[tokio::test(start_paused = true)]
async fn relay_approval_timeout_releases_transfer_id_for_reoffer() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let sender = network_identity::DeviceIdentity::from_private_keys(
        "sender".into(),
        [11u8; 32],
        [21u8; 32],
    );
    let receiver = network_identity::DeviceIdentity::from_private_keys(
        "receiver".into(),
        [12u8; 32],
        [22u8; 32],
    );
    state.peers.write().await.insert(
        "sender".into(),
        PeerConfig {
            endpoint: None,
            identity_public_key: [0u8; 32],
            e2e_public_key: *sender.public_e2e_key().as_bytes(),
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test("sender").await;
    let data = Arc::new(
        RelayDataClient::new(
            "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            vec![0u8; 32],
            "credential".into(),
            [0u8; 32],
        )
        .expect("relay data client"),
    );
    let manifest = relay_test_manifest("relay-reoffer-transfer");
    // 两个 Offer 都在把 receiver 移入 state 前构造（encrypt 需要借用其公钥）。
    let first_envelope = build_relay_offer_envelope(
        &sender,
        &receiver,
        "00000000000000000000000000000001",
        &manifest,
        "0000000000000001",
    );
    let second_envelope = build_relay_offer_envelope(
        &sender,
        &receiver,
        "00000000000000000000000000000002",
        &manifest,
        "0000000000000002",
    );
    state
        .lifecycle
        .identity
        .write()
        .await
        .replace(Arc::new(receiver));

    receive_relay_offer(&state, &data, "sender", &first_envelope)
        .await
        .expect("first offer is accepted for approval");
    assert_eq!(
        state
            .transfer
            .manager
            .snapshot("relay-reoffer-transfer")
            .await
            .unwrap()
            .state,
        network_transfer::TransferState::WaitingApproval
    );
    // 先让 timeout 任务被 poll 一次、注册 30s 睡眠定时器，再快进时钟。
    tokio::task::yield_now().await;

    // 快进超过审批超时，让 relay-approval-timeout 任务执行。
    tokio::time::advance(INCOMING_APPROVAL_TIMEOUT + std::time::Duration::from_secs(1)).await;
    tokio::task::yield_now().await;
    tokio::task::yield_now().await;

    // 超时任务必须移除 TransferManager 条目并清空 pending，释放 transfer_id。
    assert!(
        state
            .transfer
            .manager
            .snapshot("relay-reoffer-transfer")
            .await
            .is_none(),
        "timed-out transfer must be removed so the transfer_id can be reused"
    );
    assert!(state.relay.pending_incoming.read().await.is_empty());

    // 同一 transfer_id 的新 Offer（新 session_id）必须能被接受，不得报 already active。
    receive_relay_offer(&state, &data, "sender", &second_envelope)
        .await
        .expect("second offer of the same transfer_id is accepted after timeout");
}

#[tokio::test]
async fn relay_offer_validation_rejects_malformed_envelopes_and_metadata() {
    let sender = network_identity::DeviceIdentity::from_private_keys(
        "sender".into(),
        [61u8; 32],
        [71u8; 32],
    );
    let receiver = network_identity::DeviceIdentity::from_private_keys(
        "receiver".into(),
        [62u8; 32],
        [72u8; 32],
    );
    let state = relay_state_with_peer(&sender, &receiver).await;
    let data = disconnected_relay_data();
    let manifest = relay_test_manifest("offer-validation");
    let session_id = "00000000000000000000000000000011";
    let crypto_session_id = "0000000000000011";

    let error = receive_relay_offer(&state, &data, "sender", &[])
        .await
        .expect_err("empty offer must be rejected");
    assert!(error.to_string().contains("truncated"));

    let error = receive_relay_offer(&state, &data, "sender", &[b'a'; 31])
        .await
        .expect_err("short session prefix must be rejected");
    assert!(error.to_string().contains("truncated"));

    let mut uppercase_session = vec![b'A'; 32];
    uppercase_session.extend_from_slice(b"AA");
    let error = receive_relay_offer(&state, &data, "sender", &uppercase_session)
        .await
        .expect_err("uppercase session IDs are not accepted");
    assert!(error.to_string().contains("session ID is invalid"));

    let mut invalid_utf8 = session_id.as_bytes().to_vec();
    invalid_utf8.push(0xff);
    let error = receive_relay_offer(&state, &data, "sender", &invalid_utf8)
        .await
        .expect_err("non-UTF8 encoded offer must be rejected");
    assert!(error.to_string().to_ascii_lowercase().contains("utf-8"));

    let mut invalid_base64 = session_id.as_bytes().to_vec();
    invalid_base64.extend_from_slice(b"!");
    let error = receive_relay_offer(&state, &data, "sender", &invalid_base64)
        .await
        .expect_err("invalid base64 offer must be rejected");
    assert!(error.to_string().contains("Invalid"));

    let valid_value =
        relay_offer_value(&sender, &receiver, session_id, &manifest, crypto_session_id);
    let valid_body = encode_relay_offer_value(&receiver, session_id, &valid_value);

    state.lifecycle.identity.write().await.take();
    let error = receive_relay_offer(&state, &data, "sender", &valid_body)
        .await
        .expect_err("offer requires a runtime identity");
    assert!(error.to_string().contains("identity is unavailable"));
    state.lifecycle.identity.write().await.replace(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "receiver".into(),
            [62u8; 32],
            [72u8; 32],
        ),
    ));

    let wrong_receiver = network_identity::DeviceIdentity::from_private_keys(
        "wrong-receiver".into(),
        [63u8; 32],
        [73u8; 32],
    );
    let wrong_body = encode_relay_offer_value(&wrong_receiver, session_id, &valid_value);
    let error = receive_relay_offer(&state, &data, "sender", &wrong_body)
        .await
        .expect_err("offer encrypted to another identity must be rejected");
    assert!(error.to_string().contains("decrypt") || error.to_string().contains("crypto"));

    for field in [
        "transfer_id",
        "file_name",
        "file_size",
        "modified_at",
        "content_hash",
        "manifest_hash",
    ] {
        let mut value = valid_value.clone();
        value.as_object_mut().unwrap().remove(field);
        let body = encode_relay_offer_value(&receiver, session_id, &value);
        let error = receive_relay_offer(&state, &data, "sender", &body)
            .await
            .expect_err("required offer metadata must be present");
        assert!(!error.to_string().is_empty(), "missing {field}: {error}");
    }

    let mut metadata_cases = Vec::new();
    let mut value = valid_value.clone();
    value["v"] = serde_json::json!(2);
    metadata_cases.push(value);
    let mut value = valid_value.clone();
    value["crypto_suite"] = serde_json::json!("unknown-suite");
    metadata_cases.push(value);
    let mut value = valid_value.clone();
    value["session_id"] = serde_json::json!("00000000000000000000000000000012");
    metadata_cases.push(value);
    let mut value = valid_value.clone();
    value["transfer_id"] = serde_json::json!("other-transfer");
    metadata_cases.push(value);
    let mut value = valid_value.clone();
    value["sender_id"] = serde_json::json!("other-peer");
    metadata_cases.push(value);
    let mut value = valid_value.clone();
    value["receiver_id"] = serde_json::json!("other-receiver");
    metadata_cases.push(value);
    let mut value = valid_value.clone();
    value["content_hash"] = serde_json::json!("not-a-digest");
    metadata_cases.push(value);
    let mut value = valid_value.clone();
    value["manifest_hash"] = serde_json::json!("not-a-digest");
    metadata_cases.push(value);
    let mut value = valid_value.clone();
    value["file_name"] = serde_json::json!("../escape");
    metadata_cases.push(value);
    for value in metadata_cases {
        let body = encode_relay_offer_value(&receiver, session_id, &value);
        let error = receive_relay_offer(&state, &data, "sender", &body)
            .await
            .expect_err("offer identity and metadata must be bound");
        assert!(error.to_string().contains("metadata"));
    }

    let mut invalid_crypto_session = valid_value.clone();
    invalid_crypto_session["crypto_session_id"] = serde_json::json!("short");
    let body = encode_relay_offer_value(&receiver, session_id, &invalid_crypto_session);
    let error = receive_relay_offer(&state, &data, "sender", &body)
        .await
        .expect_err("crypto SessionId must be fixed-width hexadecimal");
    assert!(error.to_string().contains("crypto SessionId"));

    let invalid_manifest = FileManifest {
        transfer_id: "unsafe/id".into(),
        ..manifest.clone()
    };
    let mut invalid_manifest_value = relay_offer_value(
        &sender,
        &receiver,
        session_id,
        &invalid_manifest,
        crypto_session_id,
    );
    invalid_manifest_value["manifest_hash"] =
        serde_json::json!(relay_manifest_hash(&invalid_manifest));
    let body = encode_relay_offer_value(&receiver, session_id, &invalid_manifest_value);
    let error = receive_relay_offer(&state, &data, "sender", &body)
        .await
        .expect_err("unsafe transfer IDs must be rejected by manifest validation");
    assert!(error.to_string().contains("unsafe"));

    let mut hash_mismatch = valid_value;
    hash_mismatch["manifest_hash"] = serde_json::json!("c".repeat(64));
    let body = encode_relay_offer_value(&receiver, session_id, &hash_mismatch);
    let error = receive_relay_offer(&state, &data, "sender", &body)
        .await
        .expect_err("manifest hash must bind the complete offer");
    assert!(error.to_string().contains("does not match"));
}

#[tokio::test]
async fn relay_offer_pending_state_enforces_capacity_identity_and_active_ownership() {
    let sender = network_identity::DeviceIdentity::from_private_keys(
        "sender".into(),
        [81u8; 32],
        [91u8; 32],
    );
    let receiver = network_identity::DeviceIdentity::from_private_keys(
        "receiver".into(),
        [82u8; 32],
        [92u8; 32],
    );
    let manifest = relay_test_manifest("offer-state");
    let session_id = "00000000000000000000000000000021";
    let body = build_relay_offer_envelope(
        &sender,
        &receiver,
        session_id,
        &manifest,
        "0000000000000021",
    );
    let data = disconnected_relay_data();

    let state = relay_state_with_peer(&sender, &receiver).await;
    let unknown_error = receive_relay_offer(&state, &data, "unknown-peer", &body)
        .await
        .expect_err("offers from unknown peers must be rejected");
    assert!(unknown_error.to_string().contains("registered peer"));

    receive_relay_offer(&state, &data, "sender", &body)
        .await
        .expect("first offer should wait for approval");
    receive_relay_offer(&state, &data, "sender", &body)
        .await
        .expect("identical retransmission should refresh the pending offer");
    assert!(state
        .relay
        .pending_incoming
        .read()
        .await
        .contains_key(&manifest.transfer_id));

    let active_state = relay_state_with_peer(&sender, &receiver).await;
    active_state.relay.active_incoming.lock().await.insert(
        manifest.transfer_id.clone(),
        relay_test_active(relay_pending_for(
            manifest.clone(),
            "00000000000000000000000000000022",
            "sender",
        )),
    );
    let error = receive_relay_offer(&active_state, &data, "sender", &body)
        .await
        .expect_err("an already active transfer cannot be offered again");
    assert!(error.to_string().contains("already receiving"));

    let conflicting_state = relay_state_with_peer(&sender, &receiver).await;
    let mut conflicting_manifest = manifest.clone();
    conflicting_manifest.modified_at += 1;
    conflicting_state
        .relay
        .pending_incoming
        .write()
        .await
        .insert(
            manifest.transfer_id.clone(),
            relay_pending_for(conflicting_manifest, session_id, "sender"),
        );
    let error = receive_relay_offer(&conflicting_state, &data, "sender", &body)
        .await
        .expect_err("a transfer ID cannot change its manifest while pending");
    assert!(error.to_string().contains("different manifest"));

    let capacity_state = relay_state_with_peer(&sender, &receiver).await;
    for index in 0..MAX_PENDING_INCOMING_TRANSFERS {
        let transfer_id = format!("pending-{index}");
        capacity_state.relay.pending_incoming.write().await.insert(
            transfer_id.clone(),
            relay_pending_for(
                FileManifest {
                    transfer_id,
                    ..manifest.clone()
                },
                &format!("{index:032x}"),
                "sender",
            ),
        );
    }
    let error = receive_relay_offer(&capacity_state, &data, "sender", &body)
        .await
        .expect_err("pending offer capacity must be bounded");
    assert!(error.to_string().contains("too many pending"));

    let conflict_manager_state = relay_state_with_peer(&sender, &receiver).await;
    assert!(
        conflict_manager_state
            .transfer
            .manager
            .register_incoming(manifest.clone(), "sender".into())
            .await
    );
    let error = receive_relay_offer(&conflict_manager_state, &data, "sender", &body)
        .await
        .expect_err("an active TransferManager session must reject a new offer");
    assert!(error.to_string().contains("already active"));
    assert!(conflict_manager_state
        .relay
        .pending_incoming
        .read()
        .await
        .is_empty());
}

#[tokio::test]
async fn relay_accept_pending_failures_keep_checkpoint_and_route_ownership_safe() {
    let sender = network_identity::DeviceIdentity::from_private_keys(
        "sender".into(),
        [101u8; 32],
        [111u8; 32],
    );
    let receiver = network_identity::DeviceIdentity::from_private_keys(
        "receiver".into(),
        [102u8; 32],
        [112u8; 32],
    );
    let data = disconnected_relay_data();
    let manifest = relay_test_manifest("accept-pending");

    let missing_state = relay_state_with_peer(&sender, &receiver).await;
    let error = accept_pending_relay_incoming(&missing_state, &data, &manifest.transfer_id)
        .await
        .expect_err("accepting a missing pending offer must fail");
    assert!(error.to_string().contains("not pending"));

    let no_directory_state = relay_state_with_peer(&sender, &receiver).await;
    no_directory_state
        .relay
        .pending_incoming
        .write()
        .await
        .insert(
            manifest.transfer_id.clone(),
            relay_pending_for(
                manifest.clone(),
                "00000000000000000000000000000031",
                "sender",
            ),
        );
    let error = accept_pending_relay_incoming(&no_directory_state, &data, &manifest.transfer_id)
        .await
        .expect_err("accepting without a receive directory must fail closed");
    assert!(error.to_string().contains("receive directory"));

    let existing_file_state = relay_state_with_peer(&sender, &receiver).await;
    let existing_root = relay_temp_dir("existing-file");
    tokio::fs::create_dir_all(&existing_root).await.unwrap();
    *existing_file_state
        .lifecycle
        .receive_directory
        .write()
        .await = Some(existing_root.clone());
    tokio::fs::write(existing_root.join(&manifest.file_name), b"different")
        .await
        .unwrap();
    existing_file_state
        .relay
        .pending_incoming
        .write()
        .await
        .insert(
            manifest.transfer_id.clone(),
            relay_pending_for(
                manifest.clone(),
                "00000000000000000000000000000032",
                "sender",
            ),
        );
    let error = accept_pending_relay_incoming(&existing_file_state, &data, &manifest.transfer_id)
        .await
        .expect_err("a destination with a different hash must not be overwritten");
    assert!(error.to_string().contains("different hash"));
    tokio::fs::remove_dir_all(existing_root).await.unwrap();

    let invalid_partial_state = relay_state_with_peer(&sender, &receiver).await;
    let invalid_root = relay_temp_dir("invalid-partial");
    tokio::fs::create_dir_all(&invalid_root).await.unwrap();
    *invalid_partial_state
        .lifecycle
        .receive_directory
        .write()
        .await = Some(invalid_root.clone());
    tokio::fs::write(
        relay_partial_path(&invalid_root, &manifest.transfer_id),
        b"x",
    )
    .await
    .unwrap();
    invalid_partial_state
        .relay
        .pending_incoming
        .write()
        .await
        .insert(
            manifest.transfer_id.clone(),
            relay_pending_for(
                manifest.clone(),
                "00000000000000000000000000000033",
                "sender",
            ),
        );
    let error = accept_pending_relay_incoming(&invalid_partial_state, &data, &manifest.transfer_id)
        .await
        .expect_err("partial checkpoints must be aligned to a Relay chunk");
    assert!(error.to_string().contains("chunk boundary"));
    tokio::fs::remove_dir_all(invalid_root).await.unwrap();

    let checkpoint_state = relay_state_with_peer(&sender, &receiver).await;
    let checkpoint_root = relay_temp_dir("checkpoint");
    tokio::fs::create_dir_all(&checkpoint_root).await.unwrap();
    *checkpoint_state.lifecycle.receive_directory.write().await = Some(checkpoint_root.clone());
    assert!(
        checkpoint_state
            .transfer
            .manager
            .register_incoming(manifest.clone(), "sender".into())
            .await
    );
    assert!(
        checkpoint_state
            .transfer
            .manager
            .mark_transferring(&manifest.transfer_id)
            .await
    );
    assert!(
        checkpoint_state
            .transfer
            .manager
            .update_progress(&manifest.transfer_id, RELAY_FILE_CHUNK_BYTES)
            .await
    );
    assert!(
        checkpoint_state
            .transfer
            .manager
            .pause_for_network(&manifest.transfer_id)
            .await
    );
    assert_eq!(
        checkpoint_state
            .transfer
            .manager
            .claim_incoming_resume(&manifest, "sender")
            .await,
        Some(RELAY_FILE_CHUNK_BYTES)
    );
    checkpoint_state
        .relay
        .pending_incoming
        .write()
        .await
        .insert(
            manifest.transfer_id.clone(),
            relay_pending_for(
                manifest.clone(),
                "00000000000000000000000000000034",
                "sender",
            ),
        );
    let error = accept_pending_relay_incoming(&checkpoint_state, &data, &manifest.transfer_id)
        .await
        .expect_err("a stale checkpoint must not be silently rewritten");
    assert!(error.to_string().contains("checkpoint offset"));
    tokio::fs::remove_dir_all(checkpoint_root).await.unwrap();

    let inactive_state = relay_state_with_peer(&sender, &receiver).await;
    let inactive_root = relay_temp_dir("inactive");
    tokio::fs::create_dir_all(&inactive_root).await.unwrap();
    *inactive_state.lifecycle.receive_directory.write().await = Some(inactive_root.clone());
    inactive_state.relay.pending_incoming.write().await.insert(
        manifest.transfer_id.clone(),
        relay_pending_for(
            manifest.clone(),
            "00000000000000000000000000000035",
            "sender",
        ),
    );
    let error = accept_pending_relay_incoming(&inactive_state, &data, &manifest.transfer_id)
        .await
        .expect_err("a TransferManager-less offer must not become active");
    assert!(error.to_string().contains("no longer active"));
    tokio::fs::remove_dir_all(inactive_root).await.unwrap();

    let send_failure_state = relay_state_with_peer(&sender, &receiver).await;
    let send_failure_root = relay_temp_dir("send-failure");
    tokio::fs::create_dir_all(&send_failure_root).await.unwrap();
    *send_failure_state.lifecycle.receive_directory.write().await = Some(send_failure_root.clone());
    assert!(
        send_failure_state
            .transfer
            .manager
            .register_incoming(manifest.clone(), "sender".into())
            .await
    );
    send_failure_state
        .relay
        .pending_incoming
        .write()
        .await
        .insert(
            manifest.transfer_id.clone(),
            relay_pending_for(
                manifest.clone(),
                "00000000000000000000000000000036",
                "sender",
            ),
        );
    install_disconnected_relay_test_path(&send_failure_state, &data).await;
    let error = accept_pending_relay_incoming(&send_failure_state, &data, &manifest.transfer_id)
        .await
        .expect_err("a failed Relay acceptance send must be recoverable");
    assert!(matches!(
        error.downcast_ref::<RelayError>(),
        Some(RelayError::NotConnected)
    ));
    assert!(send_failure_state
        .relay
        .pending_incoming
        .read()
        .await
        .contains_key(&manifest.transfer_id));
    assert!(send_failure_state
        .relay
        .active_incoming
        .lock()
        .await
        .is_empty());
    assert_eq!(
        send_failure_state
            .transfer
            .manager
            .snapshot(&manifest.transfer_id)
            .await
            .unwrap()
            .state,
        network_transfer::TransferState::Paused
    );
    tokio::fs::remove_dir_all(send_failure_root).await.unwrap();
}

#[tokio::test]
async fn relay_chunk_authentication_ordering_and_progress_are_enforced() {
    let sender = network_identity::DeviceIdentity::from_private_keys(
        "sender".into(),
        [121u8; 32],
        [131u8; 32],
    );
    let receiver = network_identity::DeviceIdentity::from_private_keys(
        "receiver".into(),
        [122u8; 32],
        [132u8; 32],
    );
    let data = disconnected_relay_data();
    let session_id = "00000000000000000000000000000041";
    let payload = b"relay chunk";
    let manifest = relay_chunk_manifest("chunk-success", payload);

    let missing_state = relay_state_with_peer(&sender, &receiver).await;
    let error = receive_relay_chunk(&missing_state, &data, session_id, 0, &[0u8; 16])
        .await
        .expect_err("a chunk without an accepted session must fail");
    assert!(error.to_string().contains("not accepted"));

    let state = relay_state_with_peer(&sender, &receiver).await;
    let root = [141u8; 32];
    install_relay_test_crypto(&state, "sender", "00000000000000aa", root, false);
    let root_dir = relay_temp_dir("chunk-success");
    tokio::fs::create_dir_all(&root_dir).await.unwrap();
    let temporary_path = root_dir.join("chunk.part");
    let file = tokio::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .read(true)
        .write(true)
        .open(&temporary_path)
        .await
        .unwrap();
    assert!(
        state
            .transfer
            .manager
            .register_incoming(manifest.clone(), "sender".into())
            .await
    );
    assert!(
        state
            .transfer
            .manager
            .mark_transferring(&manifest.transfer_id)
            .await
    );
    state.relay.active_incoming.lock().await.insert(
        manifest.transfer_id.clone(),
        ActiveRelayIncoming {
            offer: relay_pending_for(manifest.clone(), session_id, "sender"),
            file: Some(file),
            temporary_path: temporary_path.clone(),
            final_path: root_dir.join(&manifest.file_name),
            next_sequence: 0,
            received_bytes: 0,
            hasher: Sha256::new(),
            already_completed: false,
        },
    );

    let aad = crypto::file_chunk_aad(
        "00000000000000aa",
        &manifest.transfer_id,
        &relay_manifest_hash(&manifest),
        0,
    );
    let mut sender_context = crate::crypto::CryptoContext::from_session_root(root, true);
    let ciphertext = sender_context
        .encrypt(&aad, payload)
        .expect("encrypt Relay chunk");

    let error = receive_relay_chunk(&state, &data, session_id, 1, &ciphertext)
        .await
        .expect_err("out-of-order chunks must be rejected");
    assert!(error.to_string().contains("replayed or reordered"));

    let error = receive_relay_chunk(&state, &data, session_id, 0, &[0u8; 16])
        .await
        .expect_err("unauthenticated chunk ciphertext must be rejected");
    assert!(error.to_string().contains("crypto") || error.to_string().contains("envelope"));

    receive_relay_chunk(&state, &data, session_id, 0, &ciphertext)
        .await
        .expect("authenticated chunk should be written");
    {
        let mut active = state.relay.active_incoming.lock().await;
        active
            .get_mut(&manifest.transfer_id)
            .unwrap()
            .file
            .as_mut()
            .unwrap()
            .flush()
            .await
            .unwrap();
        assert_eq!(
            active.get(&manifest.transfer_id).unwrap().received_bytes,
            payload.len() as u64
        );
        assert_eq!(active.get(&manifest.transfer_id).unwrap().next_sequence, 1);
    }
    assert_eq!(tokio::fs::read(&temporary_path).await.unwrap(), payload);
    assert_eq!(
        state
            .transfer
            .manager
            .snapshot(&manifest.transfer_id)
            .await
            .unwrap()
            .confirmed_offset,
        payload.len() as u64
    );
    tokio::fs::remove_dir_all(root_dir).await.unwrap();

    let empty_state = relay_state_with_peer(&sender, &receiver).await;
    install_relay_test_crypto(&empty_state, "sender", "00000000000000aa", root, false);
    let empty_manifest = relay_chunk_manifest("chunk-empty", b"");
    let empty_root = relay_temp_dir("chunk-empty");
    tokio::fs::create_dir_all(&empty_root).await.unwrap();
    let empty_file = tokio::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .read(true)
        .write(true)
        .open(empty_root.join("empty.part"))
        .await
        .unwrap();
    assert!(
        empty_state
            .transfer
            .manager
            .register_incoming(empty_manifest.clone(), "sender".into())
            .await
    );
    assert!(
        empty_state
            .transfer
            .manager
            .mark_transferring(&empty_manifest.transfer_id)
            .await
    );
    empty_state.relay.active_incoming.lock().await.insert(
        empty_manifest.transfer_id.clone(),
        ActiveRelayIncoming {
            offer: relay_pending_for(
                empty_manifest.clone(),
                "00000000000000000000000000000042",
                "sender",
            ),
            file: Some(empty_file),
            temporary_path: empty_root.join("empty.part"),
            final_path: empty_root.join("empty.bin"),
            next_sequence: 0,
            received_bytes: 0,
            hasher: Sha256::new(),
            already_completed: false,
        },
    );
    let empty_aad = crypto::file_chunk_aad(
        "00000000000000aa",
        &empty_manifest.transfer_id,
        &relay_manifest_hash(&empty_manifest),
        0,
    );
    let mut empty_context = crate::crypto::CryptoContext::from_session_root(root, true);
    let empty_ciphertext = empty_context.encrypt(&empty_aad, b"").unwrap();
    let error = receive_relay_chunk(
        &empty_state,
        &data,
        "00000000000000000000000000000042",
        0,
        &empty_ciphertext,
    )
    .await
    .expect_err("empty plaintext chunks must be rejected");
    assert!(error.to_string().contains("exceeds declared"), "{error}");
    tokio::fs::remove_dir_all(empty_root).await.unwrap();

    let oversize_state = relay_state_with_peer(&sender, &receiver).await;
    install_relay_test_crypto(&oversize_state, "sender", "00000000000000aa", root, false);
    let oversize_manifest = FileManifest {
        file_size: 1,
        ..relay_chunk_manifest("chunk-oversize", b"oversized")
    };
    let oversize_root = relay_temp_dir("chunk-oversize");
    tokio::fs::create_dir_all(&oversize_root).await.unwrap();
    let oversize_file = tokio::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .read(true)
        .write(true)
        .open(oversize_root.join("oversize.part"))
        .await
        .unwrap();
    assert!(
        oversize_state
            .transfer
            .manager
            .register_incoming(oversize_manifest.clone(), "sender".into())
            .await
    );
    assert!(
        oversize_state
            .transfer
            .manager
            .mark_transferring(&oversize_manifest.transfer_id)
            .await
    );
    oversize_state.relay.active_incoming.lock().await.insert(
        oversize_manifest.transfer_id.clone(),
        ActiveRelayIncoming {
            offer: relay_pending_for(
                oversize_manifest.clone(),
                "00000000000000000000000000000043",
                "sender",
            ),
            file: Some(oversize_file),
            temporary_path: oversize_root.join("oversize.part"),
            final_path: oversize_root.join("oversize.bin"),
            next_sequence: 0,
            received_bytes: 0,
            hasher: Sha256::new(),
            already_completed: false,
        },
    );
    let oversize_aad = crypto::file_chunk_aad(
        "00000000000000aa",
        &oversize_manifest.transfer_id,
        &relay_manifest_hash(&oversize_manifest),
        0,
    );
    let mut oversize_context = crate::crypto::CryptoContext::from_session_root(root, true);
    let oversize_ciphertext = oversize_context
        .encrypt(&oversize_aad, b"oversized")
        .unwrap();
    let error = receive_relay_chunk(
        &oversize_state,
        &data,
        "00000000000000000000000000000043",
        0,
        &oversize_ciphertext,
    )
    .await
    .expect_err("a chunk beyond the declared file size must be rejected");
    assert!(error.to_string().contains("declared file size"));
    tokio::fs::remove_dir_all(oversize_root).await.unwrap();
}

#[tokio::test]
async fn relay_completion_validates_sender_hash_destination_and_ack_boundary() {
    let sender = network_identity::DeviceIdentity::from_private_keys(
        "sender".into(),
        [151u8; 32],
        [161u8; 32],
    );
    let receiver = network_identity::DeviceIdentity::from_private_keys(
        "receiver".into(),
        [152u8; 32],
        [162u8; 32],
    );
    let data = disconnected_relay_data();
    let payload = b"complete payload";
    let manifest = relay_chunk_manifest("completion-transfer", payload);

    let missing_state = relay_state_with_peer(&sender, &receiver).await;
    let error = complete_relay_incoming(&missing_state, &data, "missing-session", Some("sender"))
        .await
        .expect_err("completion without an active session must fail");
    assert!(error.to_string().contains("not accepted"));

    let incomplete_state = relay_state_with_peer(&sender, &receiver).await;
    let incomplete_root = relay_temp_dir("completion-incomplete");
    let incomplete_temp = setup_relay_completion_active(
        &incomplete_state,
        &manifest,
        RelayCompletionSetup {
            session_id: "00000000000000000000000000000051",
            sender_id: "sender",
            root: &incomplete_root,
            payload: Some(payload),
            already_completed: false,
            final_path: incomplete_root.join("final.bin"),
        },
    )
    .await;
    {
        let mut active = incomplete_state.relay.active_incoming.lock().await;
        active
            .get_mut(&manifest.transfer_id)
            .unwrap()
            .received_bytes = 0;
    }
    let error = complete_relay_incoming(
        &incomplete_state,
        &data,
        "00000000000000000000000000000051",
        Some("wrong-sender"),
    )
    .await
    .expect_err("completion sender and byte count are authenticated");
    assert!(error.to_string().contains("before all bytes"));
    assert!(!incomplete_temp.exists());
    assert!(incomplete_state
        .transfer
        .manager
        .snapshot(&manifest.transfer_id)
        .await
        .is_none());
    tokio::fs::remove_dir_all(incomplete_root).await.unwrap();

    let already_state = relay_state_with_peer(&sender, &receiver).await;
    let already_root = relay_temp_dir("completion-already");
    let already_manifest = relay_chunk_manifest("completion-already", payload);
    let _already_temp = setup_relay_completion_active(
        &already_state,
        &already_manifest,
        RelayCompletionSetup {
            session_id: "00000000000000000000000000000052",
            sender_id: "sender",
            root: &already_root,
            payload: None,
            already_completed: true,
            final_path: already_root.join("already.bin"),
        },
    )
    .await;
    install_disconnected_relay_test_path(&already_state, &data).await;
    let error = complete_relay_incoming(
        &already_state,
        &data,
        "00000000000000000000000000000052",
        Some("sender"),
    )
    .await
    .expect_err("an idempotent completion still requires a reachable ACK path");
    assert!(matches!(
        error.downcast_ref::<RelayError>(),
        Some(RelayError::NotConnected)
    ));
    assert!(already_state
        .transfer
        .manager
        .snapshot(&already_manifest.transfer_id)
        .await
        .is_none());
    tokio::fs::remove_dir_all(already_root).await.unwrap();

    let hash_state = relay_state_with_peer(&sender, &receiver).await;
    let hash_root = relay_temp_dir("completion-hash");
    let hash_manifest = relay_chunk_manifest("completion-hash", payload);
    let hash_temp = setup_relay_completion_active(
        &hash_state,
        &hash_manifest,
        RelayCompletionSetup {
            session_id: "00000000000000000000000000000053",
            sender_id: "sender",
            root: &hash_root,
            payload: Some(payload),
            already_completed: false,
            final_path: hash_root.join("hash.bin"),
        },
    )
    .await;
    {
        let mut active = hash_state.relay.active_incoming.lock().await;
        active.get_mut(&hash_manifest.transfer_id).unwrap().hasher = Sha256::new();
    }
    let error = complete_relay_incoming(
        &hash_state,
        &data,
        "00000000000000000000000000000053",
        Some("sender"),
    )
    .await
    .expect_err("content hash must be checked before commit");
    assert!(error.to_string().contains("hash does not match"));
    assert!(!hash_temp.exists());
    tokio::fs::remove_dir_all(hash_root).await.unwrap();

    let unavailable_state = relay_state_with_peer(&sender, &receiver).await;
    let unavailable_root = relay_temp_dir("completion-unavailable");
    let unavailable_manifest = relay_chunk_manifest("completion-unavailable", b"");
    setup_relay_completion_active(
        &unavailable_state,
        &unavailable_manifest,
        RelayCompletionSetup {
            session_id: "00000000000000000000000000000054",
            sender_id: "sender",
            root: &unavailable_root,
            payload: None,
            already_completed: false,
            final_path: unavailable_root.join("unavailable.bin"),
        },
    )
    .await;
    let error = complete_relay_incoming(
        &unavailable_state,
        &data,
        "00000000000000000000000000000054",
        Some("sender"),
    )
    .await
    .expect_err("a non-idempotent completion needs an open file");
    assert!(error.to_string().contains("active file is unavailable"));
    tokio::fs::remove_dir_all(unavailable_root).await.unwrap();

    let existing_state = relay_state_with_peer(&sender, &receiver).await;
    let existing_root = relay_temp_dir("completion-existing");
    let existing_manifest = relay_chunk_manifest("completion-existing", payload);
    let existing_final = existing_root.join(&existing_manifest.file_name);
    let existing_temp = setup_relay_completion_active(
        &existing_state,
        &existing_manifest,
        RelayCompletionSetup {
            session_id: "00000000000000000000000000000055",
            sender_id: "sender",
            root: &existing_root,
            payload: Some(payload),
            already_completed: false,
            final_path: existing_final.clone(),
        },
    )
    .await;
    tokio::fs::write(&existing_final, b"different")
        .await
        .unwrap();
    let error = complete_relay_incoming(
        &existing_state,
        &data,
        "00000000000000000000000000000055",
        Some("sender"),
    )
    .await
    .expect_err("a different destination file must not be replaced");
    assert!(error.to_string().contains("different hash"));
    assert!(!existing_temp.exists());
    tokio::fs::remove_dir_all(existing_root).await.unwrap();

    let rename_state = relay_state_with_peer(&sender, &receiver).await;
    let rename_root = relay_temp_dir("completion-rename");
    let rename_manifest = relay_chunk_manifest("completion-rename", payload);
    let rename_temp = setup_relay_completion_active(
        &rename_state,
        &rename_manifest,
        RelayCompletionSetup {
            session_id: "00000000000000000000000000000056",
            sender_id: "sender",
            root: &rename_root,
            payload: Some(payload),
            already_completed: false,
            final_path: rename_root.join("missing-parent").join("final.bin"),
        },
    )
    .await;
    let error = complete_relay_incoming(
        &rename_state,
        &data,
        "00000000000000000000000000000056",
        Some("sender"),
    )
    .await
    .expect_err("rename failures must fail the business transfer");
    assert!(!error.to_string().is_empty());
    assert!(!rename_temp.exists());
    tokio::fs::remove_dir_all(rename_root).await.unwrap();

    let success_state = relay_state_with_peer(&sender, &receiver).await;
    let success_root = relay_temp_dir("completion-success");
    let success_manifest = relay_chunk_manifest("completion-success", payload);
    let success_final = success_root.join(&success_manifest.file_name);
    let success_temp = setup_relay_completion_active(
        &success_state,
        &success_manifest,
        RelayCompletionSetup {
            session_id: "00000000000000000000000000000057",
            sender_id: "sender",
            root: &success_root,
            payload: Some(payload),
            already_completed: false,
            final_path: success_final.clone(),
        },
    )
    .await;
    install_disconnected_relay_test_path(&success_state, &data).await;
    let error = complete_relay_incoming(
        &success_state,
        &data,
        "00000000000000000000000000000057",
        Some("sender"),
    )
    .await
    .expect_err("the file can commit even when the test client cannot ACK");
    assert!(matches!(
        error.downcast_ref::<RelayError>(),
        Some(RelayError::NotConnected)
    ));
    assert!(!success_temp.exists());
    assert_eq!(tokio::fs::read(&success_final).await.unwrap(), payload);
    assert!(success_state
        .transfer
        .manager
        .snapshot(&success_manifest.transfer_id)
        .await
        .is_none());
    tokio::fs::remove_dir_all(success_root).await.unwrap();

    let idem_state = relay_state_with_peer(&sender, &receiver).await;
    let idem_root = relay_temp_dir("completion-idempotent-existing");
    let idem_manifest = relay_chunk_manifest("completion-idempotent-existing", payload);
    let idem_final = idem_root.join(&idem_manifest.file_name);
    let idem_temp = setup_relay_completion_active(
        &idem_state,
        &idem_manifest,
        RelayCompletionSetup {
            session_id: "00000000000000000000000000000058",
            sender_id: "sender",
            root: &idem_root,
            payload: Some(payload),
            already_completed: false,
            final_path: idem_final.clone(),
        },
    )
    .await;
    install_disconnected_relay_test_path(&idem_state, &data).await;
    tokio::fs::write(&idem_final, payload).await.unwrap();
    let error = complete_relay_incoming(
        &idem_state,
        &data,
        "00000000000000000000000000000058",
        Some("sender"),
    )
    .await
    .expect_err("idempotent destination still needs a completion ACK");
    assert!(matches!(
        error.downcast_ref::<RelayError>(),
        Some(RelayError::NotConnected)
    ));
    assert!(!idem_temp.exists());
    tokio::fs::remove_dir_all(idem_root).await.unwrap();
}

#[tokio::test]
async fn relay_approval_and_cancel_route_errors_are_typed_and_scoped() {
    let sender = network_identity::DeviceIdentity::from_private_keys(
        "sender".into(),
        [171u8; 32],
        [181u8; 32],
    );
    let receiver = network_identity::DeviceIdentity::from_private_keys(
        "receiver".into(),
        [172u8; 32],
        [182u8; 32],
    );
    let manifest = relay_test_manifest("approval-cancel");
    let no_route_state = relay_state_with_peer(&sender, &receiver).await;
    no_route_state.relay.pending_incoming.write().await.insert(
        manifest.transfer_id.clone(),
        relay_pending_for(
            manifest.clone(),
            "00000000000000000000000000000061",
            "sender",
        ),
    );
    let error = respond_to_relay_incoming(&no_route_state, &manifest.transfer_id, false)
        .await
        .expect_err("approval without a current Relay path must fail");
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);
    assert!(no_route_state
        .relay
        .pending_incoming
        .read()
        .await
        .is_empty());

    let reject_state = relay_state_with_peer(&sender, &receiver).await;
    let reject_data = disconnected_relay_data();
    let reject_session = crate::session::SessionId::new();
    reject_state
        .connection_sessions
        .register_pending_session("sender", reject_session)
        .await
        .expect("reserve logical session");
    reject_state
        .admit_authenticated_session("sender", Some(reject_session), "remote-reject")
        .await
        .expect("install current logical session");
    assert!(
        reject_state
            .mark_relay_route_connected("sender", reject_session, Some(Arc::clone(&reject_data)))
            .await
    );
    assert!(
        reject_state
            .transfer
            .manager
            .register_incoming(manifest.clone(), "sender".into())
            .await
    );
    reject_state.relay.pending_incoming.write().await.insert(
        manifest.transfer_id.clone(),
        relay_pending_for(
            manifest.clone(),
            "00000000000000000000000000000062",
            "sender",
        ),
    );
    let error = respond_to_relay_incoming(&reject_state, &manifest.transfer_id, false)
        .await
        .expect_err("a disconnected Relay data socket must report cancellation failure");
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);
    assert!(reject_state
        .transfer
        .manager
        .snapshot(&manifest.transfer_id)
        .await
        .is_none());

    let accept_state = relay_state_with_peer(&sender, &receiver).await;
    let accept_data = disconnected_relay_data();
    let accept_session = crate::session::SessionId::new();
    accept_state
        .connection_sessions
        .register_pending_session("sender", accept_session)
        .await
        .expect("reserve logical session");
    accept_state
        .admit_authenticated_session("sender", Some(accept_session), "remote-accept")
        .await
        .expect("install current logical session");
    assert!(
        accept_state
            .mark_relay_route_connected("sender", accept_session, Some(Arc::clone(&accept_data)))
            .await
    );
    let accept_root = relay_temp_dir("approval-accept");
    tokio::fs::create_dir_all(&accept_root).await.unwrap();
    *accept_state.lifecycle.receive_directory.write().await = Some(accept_root.clone());
    assert!(
        accept_state
            .transfer
            .manager
            .register_incoming(manifest.clone(), "sender".into())
            .await
    );
    accept_state.relay.pending_incoming.write().await.insert(
        manifest.transfer_id.clone(),
        relay_pending_for(
            manifest.clone(),
            "00000000000000000000000000000063",
            "sender",
        ),
    );
    let error = respond_to_relay_incoming(&accept_state, &manifest.transfer_id, true)
        .await
        .expect_err("acceptance send failure must be translated to RelayError");
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);
    assert!(accept_state.relay.pending_incoming.read().await.is_empty());
    assert!(accept_state.relay.active_incoming.lock().await.is_empty());
    tokio::fs::remove_dir_all(accept_root).await.unwrap();

    let cancel_state = relay_state_with_peer(&sender, &receiver).await;
    let cancel_data = disconnected_relay_data();
    let cancel_session = crate::session::SessionId::new();
    cancel_state
        .connection_sessions
        .register_pending_session("sender", cancel_session)
        .await
        .expect("reserve logical session");
    cancel_state
        .admit_authenticated_session("sender", Some(cancel_session), "remote-cancel")
        .await
        .expect("install current logical session");
    assert!(
        cancel_state
            .mark_relay_route_connected("sender", cancel_session, Some(Arc::clone(&cancel_data)))
            .await
    );
    assert!(
        cancel_state
            .transfer
            .manager
            .register_incoming(manifest.clone(), "sender".into())
            .await
    );
    cancel_transfer(&cancel_state, &manifest.transfer_id).await;
    assert!(cancel_state
        .transfer
        .manager
        .snapshot(&manifest.transfer_id)
        .await
        .is_none());
}
