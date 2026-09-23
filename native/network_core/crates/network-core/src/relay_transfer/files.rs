use super::*;

/// 返回 Relay 文件名是否是单个安全路径组件。
pub(crate) fn is_safe_file_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && !value.contains(['/', '\\', '\0'])
        && std::path::Path::new(value).components().count() == 1
        && !matches!(
            std::path::Path::new(value).components().next(),
            Some(std::path::Component::ParentDir | std::path::Component::CurDir)
        )
}

/// 返回值是否为小写或大写形式的 SHA-256 十六进制摘要。
pub(crate) fn is_sha256_hash(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// 返回接收内容的 SHA-256 摘要是否与 enrollment offer 一致。
pub(crate) fn relay_hash_matches(hasher: Sha256, expected: &str) -> bool {
    hex::encode(hasher.finalize()).eq_ignore_ascii_case(expected)
}

/// 计算稳定的 Manifest Hash；socket session token 不参与，因此重连可复用它。
pub(crate) fn relay_manifest_hash(manifest: &FileManifest) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"ssh-mobile/relay-manifest/V2\0");
    hasher.update(manifest.transfer_id.as_bytes());
    hasher.update([0]);
    hasher.update(manifest.file_name.as_bytes());
    hasher.update([0]);
    hasher.update(manifest.file_size.to_be_bytes());
    hasher.update(manifest.modified_at.to_be_bytes());
    hasher.update(manifest.content_hash.as_bytes());
    hasher.update(manifest.protocol_version.to_be_bytes());
    hex::encode(hasher.finalize())
}

pub(crate) fn relay_partial_path(directory: &std::path::Path, transfer_id: &str) -> PathBuf {
    directory.join(format!("{transfer_id}.part"))
}

pub(crate) fn valid_relay_offset(offset: u64, total_bytes: u64) -> bool {
    offset <= total_bytes
        && (offset == 0 || offset == total_bytes || offset.is_multiple_of(RELAY_FILE_CHUNK_BYTES))
}

pub(crate) async fn hash_partial_file(
    path: &std::path::Path,
    offset: u64,
) -> Result<Sha256, Box<dyn std::error::Error + Send + Sync>> {
    let mut hasher = Sha256::new();
    if offset == 0 && tokio::fs::symlink_metadata(path).await.is_err() {
        return Ok(hasher);
    }
    let mut file = tokio::fs::File::open(path).await?;
    let mut remaining = offset;
    let mut buffer = vec![0u8; RELAY_FILE_CHUNK_BYTES as usize];
    while remaining > 0 {
        let to_read = std::cmp::min(remaining, buffer.len() as u64) as usize;
        let read = file.read(&mut buffer[..to_read]).await?;
        if read == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "partial file ended before its declared offset",
            )
            .into());
        }
        hasher.update(&buffer[..read]);
        remaining -= read as u64;
    }
    Ok(hasher)
}

pub(crate) fn is_transient_relay_error(error: &(dyn std::error::Error + 'static)) -> bool {
    let mut current = Some(error);
    while let Some(error) = current {
        if let Some(error) = error.downcast_ref::<RelayError>() {
            if matches!(error, RelayError::NotConnected | RelayError::Socket(_)) {
                return true;
            }
        }
        if let Some(error) = error.downcast_ref::<std::io::Error>() {
            if matches!(
                error.kind(),
                std::io::ErrorKind::BrokenPipe
                    | std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::NotConnected
                    | std::io::ErrorKind::UnexpectedEof
                    | std::io::ErrorKind::TimedOut
            ) {
                return true;
            }
        }
        current = error.source();
    }
    false
}

/// 发送加密 Relay 申请、分块和完成确认（reservation 数据面）。
pub(crate) async fn send_file_over_relay(
    peer: PeerConfig,
    transfer: ResumableTransfer,
    state: Arc<RuntimeState>,
    lease: crate::connect::PathLease,
) {
    let transfer_id = transfer.transfer_id.clone();
    let peer_id = transfer.peer_id.clone();
    let path = transfer.source_path.clone();
    let result = async {
        let data = lease.relay_data().filter(|_| lease.is_active()).ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::NotConnected, "Relay is unavailable")
            })?;
        let current_manifest = build_file_manifest(transfer_id.clone(), &path).await?;
        if current_manifest != transfer.manifest {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "source file changed during Relay transfer",
                )
                .into(),
            );
        }
        if !valid_relay_offset(transfer.offset, transfer.manifest.file_size) {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "transfer offset is not aligned to Relay chunk boundary",
                )
                .into(),
            );
        }
        let manifest = transfer.manifest.clone();
        let mut session_bytes = [0u8; 16];
        rand::rngs::OsRng.fill_bytes(&mut session_bytes);
        let session_id = hex::encode(session_bytes);
        let offer = serde_json::to_vec(&json!({
            "v": 1,
            "crypto_suite": APPLICATION_CRYPTO_SUITE,
            "session_id": session_id,
            "crypto_session_id": transfer.session_id,
            "transfer_id": manifest.transfer_id,
            "manifest_hash": relay_manifest_hash(&manifest),
            "sender_id": state.lifecycle.identity.read().await.as_ref().map(|identity| identity.device_id.as_str())
                .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?,
            "receiver_id": peer_id,
            "file_name": manifest.file_name,
            "file_size": manifest.file_size,
            "modified_at": manifest.modified_at,
            "content_hash": manifest.content_hash,
        }))?;
        // offer 用对端 E2E 公钥加密（与 V2 同构）；信封 = [session_id][base64(密文)]。
        let encrypted_offer =
            crypto::encrypt_application_offer(&offer, peer.e2e_public_key, &session_bytes)?;
        let encoded_offer = URL_SAFE_NO_PAD.encode(encrypted_offer);
        let mut offer_envelope = Vec::with_capacity(32 + encoded_offer.len());
        offer_envelope.extend_from_slice(session_id.as_bytes());
        offer_envelope.extend_from_slice(encoded_offer.as_bytes());
        let (acceptance_tx, acceptance_rx) = oneshot::channel();
        state
            .relay.acceptances
            .write()
            .await
            .insert(transfer_id.clone(), acceptance_tx);
        send_data_envelope(&data, DATA_ENV_FILE_OFFER, &offer_envelope).await?;
        let acceptance_result = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, acceptance_rx).await;
        state
            .relay.acceptances
            .write()
            .await
            .remove(&transfer_id);
        let acceptance = match acceptance_result {
            Ok(Ok(Some(acceptance))) => acceptance,
            Ok(Ok(None)) => {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    std::io::Error::new(
                        std::io::ErrorKind::PermissionDenied,
                        "Relay receiver rejected file",
                    )
                    .into(),
                )
            }
            Ok(Err(_)) => {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    std::io::Error::new(
                        std::io::ErrorKind::NotConnected,
                        "Relay acceptance channel closed",
                    )
                    .into(),
                )
            }
            Err(_) => {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "Relay receiver approval timed out",
                    )
                    .into(),
                )
            }
        };
        let expected_manifest_hash = relay_manifest_hash(&manifest);
        if acceptance.transfer_id != manifest.transfer_id
            || acceptance.v != 1
            || acceptance.manifest_hash != expected_manifest_hash
            || !acceptance.file_hash.eq_ignore_ascii_case(&manifest.content_hash)
            || !valid_relay_offset(acceptance.offset, manifest.file_size)
            || acceptance.offset < transfer.offset
        {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Relay acceptance does not match TransferSession",
                )
                .into(),
            );
        }
        if !state.transfer.manager.mark_transferring(&transfer_id).await {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::other("transfer is no longer active").into(),
            );
        }
        state
            .transfer.manager
            .update_progress(&transfer_id, acceptance.offset)
            .await;
        let mut file = tokio::fs::File::open(&path).await?;
        file.seek(SeekFrom::Start(acceptance.offset)).await?;
        // 缓冲区按明文分块大小分配：整块加密后 + 信封开销仍落在数据面载荷上限内。
        let mut buffer = vec![0u8; RELAY_FILE_CHUNK_BYTES as usize];
        let mut sequence = acceptance.offset / RELAY_FILE_CHUNK_BYTES;
        let mut transferred = acceptance.offset;
        let cancellation = state.transfer.manager.cancellation_token(&transfer_id).await;
        loop {
            if cancellation
                .as_ref()
                .is_some_and(network_transfer::TransferCancellation::is_cancelled)
            {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::Interrupted,
                    "Relay transfer cancelled",
                )
                .into());
            }
            let to_read = std::cmp::min(
                buffer.len() as u64,
                manifest.file_size.saturating_sub(transferred),
            ) as usize;
            let read = file.read(&mut buffer[..to_read]).await?;
            if read == 0 {
                break;
            }
            let aad = crypto::file_chunk_aad(
                &transfer.session_id,
                &manifest.transfer_id,
                &relay_manifest_hash(&manifest),
                sequence,
            );
            let ciphertext = state
                .encrypt_application_payload(
                    &peer_id,
                    &transfer.session_id,
                    &aad,
                    &buffer[..read],
                )
                .await?;
            // body = [session_id 32][sequence u64 BE][ciphertext]
            let mut chunk = Vec::with_capacity(40 + ciphertext.len());
            chunk.extend_from_slice(session_id.as_bytes());
            chunk.extend_from_slice(&sequence.to_be_bytes());
            chunk.extend_from_slice(&ciphertext);
            send_data_envelope(&data, DATA_ENV_FILE_CHUNK, &chunk).await?;
            sequence = crypto::next_sequence(sequence)?;
            transferred += read as u64;
            state
                .transfer.manager
                .update_progress(&transfer_id, transferred)
                .await;
            emit_transfer_progress(
                &state.event_tx,
                &peer_id,
                &transfer_id,
                transferred,
                manifest.file_size,
            );
        }
        if transferred != manifest.file_size {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "Relay source size changed during transfer",
            )
            .into());
        }
        let (completion_tx, completion_rx) = oneshot::channel();
        state
            .relay.completions
            .write()
            .await
            .insert(transfer_id.clone(), completion_tx);
        send_data_envelope(&data, DATA_ENV_FILE_COMPLETE, transfer_id.as_bytes()).await?;
        let completed = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, completion_rx)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false);
        state.relay.completions.write().await.remove(&transfer_id);
        if !completed {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Relay completion acknowledgement timed out",
            )
                .into());
        }
        state.transfer.manager.mark_verifying(&transfer_id).await;
        if state.transfer.manager.mark_completed(&transfer_id).await {
            emit_transfer_completed(&state.event_tx, &peer_id, &transfer_id, "");
        }
        Ok(())
    }
    .await;
    if result.is_err()
        && result
            .as_ref()
            .err()
            .is_some_and(|error| !is_transient_relay_error(error.as_ref()))
    {
        if let Some(data) = lease.relay_data().filter(|_| lease.is_active()) {
            let _ = send_file_cancel(&data, &transfer_id).await;
        }
    }
    if result.is_err()
        && state
            .transfer
            .manager
            .snapshot(&transfer_id)
            .await
            .is_none()
    {
        return;
    }
    if result.is_ok() || state.transfer.manager.is_cancelled(&transfer_id).await {
        state.transfer.manager.remove_transfer(&transfer_id).await;
    } else if let Err(error) = result {
        if is_transient_relay_error(error.as_ref())
            && state.transfer.manager.pause_for_network(&transfer_id).await
        {
            tracing::debug!(
                transfer_id = %transfer_id,
                error = %error,
                "native Relay transfer paused for socket recovery"
            );
            return;
        }
        let reason = if error
            .downcast_ref::<std::io::Error>()
            .is_some_and(|error| error.kind() == std::io::ErrorKind::InvalidData)
        {
            TransferFailureReason::SourceChanged
        } else {
            TransferFailureReason::Io
        };
        state
            .transfer
            .manager
            .fail_transfer(&transfer_id, reason)
            .await;
        emit_transfer_error(
            &state.event_tx,
            &transfer_id,
            NetworkErrorCode::RelayError,
            "Relay transfer failed".to_string(),
            "send",
            Some(&peer_id),
        );
        state.transfer.manager.remove_transfer(&transfer_id).await;
        tracing::debug!(transfer_id = %transfer_id, error = %error, "native Relay file transfer failed");
    }
}
