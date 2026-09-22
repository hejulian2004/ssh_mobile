use super::*;

use crate::connect::CAPABILITY_RELIABLE_STREAM;

/// 应用传入 Relay 审批，并创建临时文件。
pub(crate) async fn respond_to_relay_incoming(
    state: &RuntimeState,
    transfer_id: &str,
    accepted: bool,
) -> Result<(), ProtocolError> {
    let pending = state
        .relay
        .pending_incoming
        .write()
        .await
        .remove(transfer_id)
        .ok_or_else(|| {
            protocol_error_with_context(
                NetworkErrorCode::InvalidArgument,
                "incoming transfer is not awaiting approval",
                "respond_incoming",
                None,
            )
        })?;
    let lease = state
        .acquire_relay_path_lease(&pending.sender_id, CAPABILITY_RELIABLE_STREAM)
        .await
        .map_err(|_| {
            protocol_error_with_context(
                NetworkErrorCode::RelayError,
                "Relay data plane is unavailable",
                "respond_incoming",
                None,
            )
        })?;
    let data = lease.relay_data().ok_or_else(|| {
        protocol_error_with_context(
            NetworkErrorCode::RelayError,
            "Relay data plane is unavailable",
            "respond_incoming",
            None,
        )
    })?;
    if !accepted {
        state.transfer.manager.cancel_transfer(transfer_id).await;
        state.transfer.manager.remove_transfer(transfer_id).await;
        send_file_cancel(&data, transfer_id).await.map_err(|_| {
            protocol_error(NetworkErrorCode::RelayError, "Relay cancellation failed")
        })?;
        return Ok(());
    }
    state
        .relay
        .pending_incoming
        .write()
        .await
        .insert(transfer_id.to_string(), pending);
    if let Err(error) = accept_pending_relay_incoming(state, &data, transfer_id).await {
        cancel_relay_incoming(state, transfer_id).await;
        return Err(protocol_error_with_context(
            NetworkErrorCode::RelayError,
            error.to_string(),
            "respond_incoming",
            None,
        ));
    }
    Ok(())
}

/// 为首次审批或同一 TransferSession 的自动恢复创建接收 attempt。
pub(crate) async fn accept_pending_relay_incoming(
    state: &RuntimeState,
    data: &Arc<RelayDataClient>,
    transfer_id: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let pending = state
        .relay
        .pending_incoming
        .write()
        .await
        .remove(transfer_id)
        .ok_or_else(|| std::io::Error::other("Relay transfer is not pending"))?;
    let receive_directory = state
        .lifecycle
        .receive_directory
        .read()
        .await
        .clone()
        .ok_or_else(|| std::io::Error::other("receive directory is unavailable"))?;
    tokio::fs::create_dir_all(&receive_directory).await?;
    let final_path = receive_directory.join(&pending.manifest.file_name);
    let temporary_path = relay_partial_path(&receive_directory, &pending.manifest.transfer_id);
    let (file, offset, hasher, already_completed) =
        if existing_completed_file(&pending.manifest, &receive_directory)
            .await?
            .is_some()
        {
            (None, pending.manifest.file_size, Sha256::new(), true)
        } else {
            if tokio::fs::symlink_metadata(&final_path).await.is_ok() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "destination file already exists with a different hash",
                )
                .into());
            }
            let offset = existing_partial_offset(&pending.manifest, &receive_directory).await?;
            if !valid_relay_offset(offset, pending.manifest.file_size) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "partial file offset is not aligned to Relay chunk boundary",
                )
                .into());
            }
            let hasher = hash_partial_file(&temporary_path, offset).await?;
            let mut options = tokio::fs::OpenOptions::new();
            options.write(true).read(true);
            let mut file = if offset == 0 {
                options
                    .create(true)
                    .truncate(true)
                    .open(&temporary_path)
                    .await?
            } else {
                let mut file = options.open(&temporary_path).await?;
                file.seek(SeekFrom::Start(offset)).await?;
                file
            };
            file.seek(SeekFrom::Start(offset)).await?;
            (Some(file), offset, hasher, false)
        };

    let expected_offset = state
        .transfer
        .manager
        .snapshot(transfer_id)
        .await
        .filter(|snapshot| snapshot.state == network_transfer::TransferState::Resuming)
        .map(|snapshot| snapshot.confirmed_offset);
    if expected_offset.is_some_and(|expected| expected != offset) {
        drop(file);
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "checkpoint offset does not match TransferSession",
        )
        .into());
    }
    state
        .transfer
        .manager
        .update_progress(transfer_id, offset)
        .await;
    if !state.transfer.manager.mark_transferring(transfer_id).await {
        drop(file);
        return Err(std::io::Error::other("Relay transfer is no longer active").into());
    }
    let acceptance = serde_json::to_string(&RelayAcceptancePayload {
        v: 1,
        transfer_id: pending.transfer_id.clone(),
        manifest_hash: pending.manifest_hash.clone(),
        file_hash: pending.manifest.content_hash.clone(),
        offset,
    })?;
    let lease = match state
        .acquire_path_lease_for_relay_data(&pending.sender_id, data, CAPABILITY_RELIABLE_STREAM)
        .await
    {
        Ok(lease) => lease,
        Err(error) => {
            drop(file);
            state.transfer.manager.pause_for_network(transfer_id).await;
            state
                .relay
                .pending_incoming
                .write()
                .await
                .insert(transfer_id.to_string(), pending);
            return Err(error.into());
        }
    };
    let leased_data = lease
        .relay_data()
        .ok_or_else(|| std::io::Error::other("Relay data plane is unavailable"))?;
    state.relay.active_incoming.lock().await.insert(
        transfer_id.to_string(),
        ActiveRelayIncoming {
            offer: pending.clone(),
            file,
            temporary_path,
            final_path,
            next_sequence: offset / RELAY_FILE_CHUNK_BYTES,
            received_bytes: offset,
            hasher,
            already_completed,
        },
    );
    if let Err(error) =
        send_data_envelope(&leased_data, DATA_ENV_FILE_ACCEPT, acceptance.as_bytes()).await
    {
        if let Some(active) = state.relay.active_incoming.lock().await.remove(transfer_id) {
            drop(active.file);
        }
        state.transfer.manager.pause_for_network(transfer_id).await;
        state
            .relay
            .pending_incoming
            .write()
            .await
            .insert(transfer_id.to_string(), pending);
        return Err(error.into());
    }
    Ok(())
}

/// 认证、排序并写入一个加密 Relay 分块。
pub(crate) async fn receive_relay_chunk(
    state: &RuntimeState,
    data: &Arc<RelayDataClient>,
    session_id: &str,
    sequence: u64,
    ciphertext: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut active_transfers = state.relay.active_incoming.lock().await;
    let active = active_transfers
        .values_mut()
        .find(|active| active.offer.session_id == session_id)
        .ok_or_else(|| std::io::Error::other("Relay session is not accepted"))?;
    let transfer_id = active.offer.transfer_id.clone();
    if active.already_completed
        || sequence != active.next_sequence
        || ciphertext.len() < 16
        || active.file.is_none()
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay chunk is replayed or reordered",
        )
        .into());
    }
    let crypto_session_id = active.offer.crypto_session_id.clone();
    let manifest_hash = active.offer.manifest_hash.clone();
    let aad = crypto::file_chunk_aad(&crypto_session_id, &transfer_id, &manifest_hash, sequence);
    let clear = state
        .decrypt_application_payload(
            &active.offer.sender_id,
            &crypto_session_id,
            &aad,
            ciphertext,
        )
        .await?;
    if clear.is_empty()
        || active.received_bytes + clear.len() as u64 > active.offer.manifest.file_size
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay chunk exceeds declared file size",
        )
        .into());
    }
    active
        .file
        .as_mut()
        .expect("Relay active file checked above")
        .write_all(&clear)
        .await?;
    active.hasher.update(&clear);
    active.received_bytes += clear.len() as u64;
    active.next_sequence = crypto::next_sequence(active.next_sequence)?;
    emit_transfer_progress(
        &state.event_tx,
        &active.offer.sender_id,
        &transfer_id,
        active.received_bytes,
        active.offer.manifest.file_size,
    );
    state
        .transfer
        .manager
        .update_progress(&transfer_id, active.received_bytes)
        .await;
    let _ = data;
    Ok(())
}

/// 校验 Relay 完成状态，提交文件并发送 complete_ack。
pub(crate) async fn complete_relay_incoming(
    state: &RuntimeState,
    data: &Arc<RelayDataClient>,
    session_or_transfer_id: &str,
    sender_id: Option<&str>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (transfer_id, mut active) = {
        let mut active_transfers = state.relay.active_incoming.lock().await;
        let transfer_id = active_transfers
            .iter()
            .find(|(transfer_id, active)| {
                *transfer_id == session_or_transfer_id
                    || active.offer.session_id == session_or_transfer_id
            })
            .map(|(transfer_id, _)| transfer_id.clone())
            .ok_or_else(|| std::io::Error::other("Relay session is not accepted"))?;
        let active = active_transfers
            .remove(&transfer_id)
            .ok_or_else(|| std::io::Error::other("Relay session is not accepted"))?;
        (transfer_id, active)
    };
    if sender_id != Some(active.offer.sender_id.as_str())
        || active.received_bytes != active.offer.manifest.file_size
    {
        drop(active.file);
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        state
            .transfer
            .manager
            .fail_transfer(&transfer_id, TransferFailureReason::Protocol)
            .await;
        state.transfer.manager.remove_transfer(&transfer_id).await;
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay completion arrived before all bytes",
        )
        .into());
    }
    if active.already_completed {
        state.transfer.manager.mark_verifying(&transfer_id).await;
        state.transfer.manager.mark_completed(&transfer_id).await;
        state.transfer.manager.remove_transfer(&transfer_id).await;
        let lease = state
            .acquire_path_lease_for_relay_data(
                &active.offer.sender_id,
                data,
                CAPABILITY_RELIABLE_STREAM,
            )
            .await?;
        let leased_data = lease
            .relay_data()
            .ok_or_else(|| std::io::Error::other("Relay data plane is unavailable"))?;
        send_data_envelope(
            &leased_data,
            DATA_ENV_FILE_COMPLETE_ACK,
            transfer_id.as_bytes(),
        )
        .await?;
        return Ok(());
    }
    if !relay_hash_matches(active.hasher, &active.offer.manifest.content_hash) {
        drop(active.file);
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        state
            .transfer
            .manager
            .fail_transfer(&transfer_id, TransferFailureReason::HashMismatch)
            .await;
        state.transfer.manager.remove_transfer(&transfer_id).await;
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay content hash does not match the offer",
        )
        .into());
    }
    if let Some(file) = active.file.as_mut() {
        if let Err(error) = file.flush().await {
            drop(active.file.take());
            tokio::fs::remove_file(&active.temporary_path).await.ok();
            state
                .transfer
                .manager
                .fail_transfer(&transfer_id, TransferFailureReason::Io)
                .await;
            state.transfer.manager.remove_transfer(&transfer_id).await;
            return Err(error.into());
        }
    } else {
        return Err(std::io::Error::other("Relay active file is unavailable").into());
    }
    drop(active.file.take());
    if tokio::fs::symlink_metadata(&active.final_path)
        .await
        .is_ok()
    {
        if existing_completed_file(
            &active.offer.manifest,
            active
                .final_path
                .parent()
                .ok_or_else(|| std::io::Error::other("final path has no parent"))?,
        )
        .await?
        .is_none()
        {
            tokio::fs::remove_file(&active.temporary_path).await.ok();
            state
                .transfer
                .manager
                .fail_transfer(&transfer_id, TransferFailureReason::Io)
                .await;
            state.transfer.manager.remove_transfer(&transfer_id).await;
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "destination file already exists with a different hash",
            )
            .into());
        }
        tokio::fs::remove_file(&active.temporary_path).await.ok();
    } else if let Err(error) = tokio::fs::rename(&active.temporary_path, &active.final_path).await {
        drop(active.file);
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        state
            .transfer
            .manager
            .fail_transfer(&transfer_id, TransferFailureReason::Io)
            .await;
        state.transfer.manager.remove_transfer(&transfer_id).await;
        return Err(error.into());
    }
    state.transfer.manager.mark_verifying(&transfer_id).await;
    let completed = state.transfer.manager.mark_completed(&transfer_id).await;
    state.transfer.manager.remove_transfer(&transfer_id).await;
    if completed {
        emit_transfer_completed(
            &state.event_tx,
            &active.offer.sender_id,
            &transfer_id,
            &active.final_path.to_string_lossy(),
        );
    }
    let lease = state
        .acquire_path_lease_for_relay_data(
            &active.offer.sender_id,
            data,
            CAPABILITY_RELIABLE_STREAM,
        )
        .await?;
    let leased_data = lease
        .relay_data()
        .ok_or_else(|| std::io::Error::other("Relay data plane is unavailable"))?;
    send_data_envelope(
        &leased_data,
        DATA_ENV_FILE_COMPLETE_ACK,
        transfer_id.as_bytes(),
    )
    .await?;
    Ok(())
}
