use super::*;

use crate::connect::CAPABILITY_RELIABLE_STREAM;

/// 在通知 UI 前解密并校验传入 Relay 申请。
pub(crate) async fn receive_relay_offer(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
    sender_id: &str,
    body: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !state.peers.read().await.contains_key(sender_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay sender is not a registered peer",
        )
        .into());
    }
    // body = [session_id 32][base64(encrypted offer)]：session_id 用于派生 offer 的
    // 加密 nonce（与 V2 同构），必须在明文中。
    if body.len() < 32 {
        return Err(std::io::Error::other("Relay offer envelope is truncated").into());
    }
    let session_id = std::str::from_utf8(&body[..32])?.to_string();
    if session_id.len() != 32
        || !session_id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay offer session ID is invalid",
        )
        .into());
    }
    let encoded_payload = std::str::from_utf8(&body[32..])?;
    let envelope = URL_SAFE_NO_PAD.decode(encoded_payload)?;
    let session_bytes: [u8; 16] = hex::decode(&session_id)?.try_into().map_err(|_| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid Relay session ID")
    })?;
    let identity = state
        .lifecycle
        .identity
        .read()
        .await
        .clone()
        .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?;
    let clear = crypto::decrypt_application_offer(&envelope, &identity.e2e_key, &session_bytes)?;
    let value: serde_json::Value = serde_json::from_slice(&clear)?;
    let transfer_id = value
        .get("transfer_id")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| std::io::Error::other("Relay transfer ID is missing"))?
        .to_string();
    let file_name = value
        .get("file_name")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| std::io::Error::other("Relay file name is missing"))?;
    let total_bytes = value
        .get("file_size")
        .and_then(serde_json::Value::as_u64)
        .ok_or_else(|| std::io::Error::other("Relay file size is invalid"))?;
    let modified_at = value
        .get("modified_at")
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| std::io::Error::other("Relay modified time is invalid"))?;
    let content_hash = value
        .get("content_hash")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| std::io::Error::other("Relay content hash is missing"))?;
    let manifest_hash = value
        .get("manifest_hash")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| std::io::Error::other("Relay manifest hash is missing"))?;
    let offer_sender = value.get("sender_id").and_then(serde_json::Value::as_str);
    let receiver = value.get("receiver_id").and_then(serde_json::Value::as_str);
    if value.get("v").and_then(serde_json::Value::as_u64) != Some(1)
        || value
            .get("crypto_suite")
            .and_then(serde_json::Value::as_str)
            != Some(APPLICATION_CRYPTO_SUITE)
        || value.get("session_id").and_then(serde_json::Value::as_str) != Some(session_id.as_str())
        || value.get("transfer_id").and_then(serde_json::Value::as_str)
            != Some(transfer_id.as_str())
        || offer_sender != Some(sender_id)
        || receiver != Some(identity.device_id.as_str())
        || !is_sha256_hash(content_hash)
        || !is_sha256_hash(manifest_hash)
        || !is_safe_file_name(file_name)
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay offer identity or metadata is invalid",
        )
        .into());
    }
    let crypto_session_id = value
        .get("crypto_session_id")
        .and_then(serde_json::Value::as_str)
        .filter(|value| value.len() == 16 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or_else(|| std::io::Error::other("Relay crypto SessionId is invalid"))?
        .to_string();
    let manifest = FileManifest {
        transfer_id: transfer_id.clone(),
        file_name: file_name.to_string(),
        file_size: total_bytes,
        modified_at,
        content_hash: content_hash.to_string(),
        protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
    };
    manifest
        .validate()
        .map_err(|message| std::io::Error::new(std::io::ErrorKind::InvalidData, message))?;
    if relay_manifest_hash(&manifest) != manifest_hash {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay manifest hash does not match metadata",
        )
        .into());
    }
    let pending = PendingRelayIncoming {
        transfer_id: transfer_id.clone(),
        session_id: session_id.clone(),
        sender_id: sender_id.to_string(),
        manifest: manifest.clone(),
        manifest_hash: manifest_hash.to_string(),
        crypto_session_id,
    };
    if state
        .relay
        .active_incoming
        .lock()
        .await
        .values()
        .any(|active| active.offer.transfer_id == transfer_id)
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "Relay transfer is already receiving",
        )
        .into());
    }
    let mut is_new_offer = false;
    {
        let mut pending_transfers = state.relay.pending_incoming.write().await;
        if !pending_transfers.contains_key(&transfer_id)
            && pending_transfers.len() >= MAX_PENDING_INCOMING_TRANSFERS
        {
            return Err(std::io::Error::other("too many pending Relay offers").into());
        }
        if let Some(previous) = pending_transfers.get(&transfer_id) {
            if previous.sender_id != sender_id
                || previous.manifest != manifest
                || previous.manifest_hash != manifest_hash
            {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "TransferId is already bound to a different manifest",
                )
                .into());
            }
        } else {
            is_new_offer = true;
        }
        pending_transfers.insert(transfer_id.clone(), pending);
    }

    let resume_offset = state
        .transfer
        .manager
        .claim_incoming_resume(&manifest, sender_id)
        .await;
    let receive_directory = state.lifecycle.receive_directory.read().await.clone();
    let completed_path = if let Some(directory) = receive_directory.as_ref() {
        existing_completed_file(&manifest, directory).await?
    } else {
        None
    };
    if is_new_offer && resume_offset.is_none() {
        if !state
            .transfer
            .manager
            .register_incoming(manifest.clone(), sender_id.to_string())
            .await
        {
            state
                .relay
                .pending_incoming
                .write()
                .await
                .remove(&transfer_id);
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "TransferId is already active",
            )
            .into());
        }
        if completed_path.is_none() {
            emit_incoming_offer(&state.event_tx, sender_id, &manifest, RouteType::Relay);
        }
    }
    if resume_offset.is_some() || completed_path.is_some() {
        accept_pending_relay_incoming(state, data, &transfer_id).await?;
        return Ok(());
    }
    let expiry_state = Arc::clone(state);
    let expiry_transfer_id = transfer_id;
    let _ = state
        .task_supervisor
        .spawn_runtime("relay-approval-timeout", async move {
            tokio::time::sleep(INCOMING_APPROVAL_TIMEOUT).await;
            let (expired, sender_id) = {
                let pending = expiry_state.relay.pending_incoming.read().await;
                let entry = pending.get(&expiry_transfer_id);
                (
                    entry.is_some_and(|pending| pending.session_id == session_id),
                    entry.map(|pending| pending.sender_id.clone()),
                )
            };
            if expired {
                expiry_state
                    .relay
                    .pending_incoming
                    .write()
                    .await
                    .remove(&expiry_transfer_id);
                expiry_state
                    .transfer
                    .manager
                    .fail_transfer(&expiry_transfer_id, TransferFailureReason::UserRejected)
                    .await;
                // 审批超时是终态失败：移除 TransferManager 条目，释放 transfer_id。
                // 否则条目停留在 Failed，register_incoming/claim_incoming_resume 只接受
                // Vacant 或 Paused，后续同一 transfer_id 的再 Offer 会被
                // "TransferId is already active" 永久拒绝。
                expiry_state
                    .transfer
                    .manager
                    .remove_transfer(&expiry_transfer_id)
                    .await;
                // 取消只发到承载该 transfer 的对端 reservation 连接。
                if let Some(sender_id) = sender_id {
                    if let Ok(lease) = expiry_state
                        .acquire_relay_path_lease(&sender_id, CAPABILITY_RELIABLE_STREAM)
                        .await
                    {
                        if let Some(data) = lease.relay_data() {
                            let _ = send_file_cancel(&data, &expiry_transfer_id).await;
                        }
                    }
                }
            }
        });
    Ok(())
}
