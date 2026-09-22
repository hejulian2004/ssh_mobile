use super::*;

/// 校验传入申请，并等待接收方审批决定。
/// Mirrors `network_quic::read_file_offer` for the shared bidi dispatcher: the
/// first four magic bytes have already been consumed to route the stream, so
/// the remaining offer fields are parsed here without re-touching the magic.
/// Kept in network-core to avoid coupling the accept loop to a network-quic
/// signature change; the wire format is identical to `read_file_offer`.
pub(crate) async fn read_file_offer_after_magic(
    receive: &mut RecvStream,
) -> Result<FileManifest, Box<dyn Error + Send + Sync>> {
    let protocol_version = receive.read_u32().await?;
    if protocol_version != NETWORK_TRANSFER_PROTOCOL_VERSION {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "unsupported file protocol",
        )
        .into());
    }
    let transfer_id = read_bounded_utf8(receive, MAX_TRANSFER_ID_BYTES, "transfer ID").await?;
    let file_name = read_bounded_utf8(receive, MAX_FILE_NAME_BYTES, "file name").await?;
    let file_size = receive.read_u64().await?;
    let modified_at = receive.read_i64().await?;
    let mut hash = [0u8; 32];
    receive.read_exact(&mut hash).await?;
    let manifest = FileManifest {
        transfer_id,
        file_name,
        file_size,
        modified_at,
        content_hash: hex::encode(hash),
        protocol_version,
    };
    manifest
        .validate()
        .map_err(|message| std::io::Error::new(std::io::ErrorKind::InvalidData, message))?;
    Ok(manifest)
}

pub(crate) async fn read_bounded_utf8(
    receive: &mut RecvStream,
    maximum: usize,
    label: &str,
) -> Result<String, Box<dyn Error + Send + Sync>> {
    let length = receive.read_u16().await? as usize;
    if length == 0 || length > maximum {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("invalid {label} length"),
        )
        .into());
    }
    let mut value = vec![0u8; length];
    receive.read_exact(&mut value).await?;
    String::from_utf8(value).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("{label} is not UTF-8"),
        )
        .into()
    })
}

const MAX_TRANSFER_ID_BYTES: usize = 128;
const MAX_FILE_NAME_BYTES: usize = 255;

/// Processes an incoming transfer whose offer has already been parsed by the
/// shared bidi dispatcher (`read_file_offer_after_magic`), so the file data
/// path never duplicates the transfer lifecycle.
pub(crate) async fn handle_incoming_file_after_offer(
    peer_id: String,
    mut send: SendStream,
    mut receive: RecvStream,
    manifest: FileManifest,
    state: Arc<RuntimeState>,
    path_lease: PathLease,
) {
    // Keep the exact inbound carrier reserved for the whole transfer
    // lifecycle. A reconnect may publish a better path, but it must not
    // silently move this accepted QUIC stream to that replacement.
    if !path_lease.is_active() {
        let _ = write_file_decision(&mut send, false, 0).await;
        let _ = send.finish();
        return;
    }
    if !valid_transfer_identity(&manifest.transfer_id, &peer_id) {
        let _ = write_file_decision(&mut send, false, 0).await;
        let _ = send.finish();
        return;
    }
    let mut active_transfer_id = None;
    let mut registered_transfer = false;
    let result = async {
        active_transfer_id = Some(manifest.transfer_id.clone());
        // SessionId is only a transport-local task grouping key. The incoming
        // business operation remains keyed by (peer_id, transfer_id).
        let session_key = state
            .connection_sessions
            .current_session_id(&peer_id)
            .await
            .map(|session_id| session_id.wire_key())
            .unwrap_or_else(|| format!("transfer:{}", manifest.transfer_id));
        if !state
            .transfer
            .manager
            .register_incoming(manifest.clone(), peer_id.clone())
            .await
        {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "transfer ID is already active",
                )
                .into(),
            );
        }
        registered_transfer = true;
        let (decision_tx, decision_rx) = tokio::sync::oneshot::channel();
        {
            let mut decisions = state.transfer.incoming_decisions.write().await;
            if decisions.len() >= MAX_PENDING_INCOMING_TRANSFERS {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    std::io::Error::other("too many pending incoming transfers").into(),
                );
            }
            match decisions.entry(manifest.transfer_id.clone()) {
                Entry::Vacant(entry) => {
                    entry.insert(decision_tx);
                }
                Entry::Occupied(_) => {
                    return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                        std::io::Error::new(
                            std::io::ErrorKind::AlreadyExists,
                            "duplicate transfer ID",
                        )
                        .into(),
                    );
                }
            }
        }
        emit_incoming_offer(&state.event_tx, &peer_id, &manifest, RouteType::QuicDirect);
        let accepted = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, decision_rx)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false);
        state
            .transfer
            .incoming_decisions
            .write()
            .await
            .remove(&manifest.transfer_id);
        if !accepted {
            write_file_decision(&mut send, false, 0).await?;
            send.finish()?;
            state
                .transfer
                .manager
                .cancel_transfer(&manifest.transfer_id)
                .await;
            state
                .transfer
                .manager
                .remove_transfer(&manifest.transfer_id)
                .await;
            return Ok(());
        }

        let receive_directory = state
            .lifecycle
            .receive_directory
            .read()
            .await
            .clone()
            .ok_or_else(|| std::io::Error::other("receive directory is unavailable"))?;
        let completed_path = existing_completed_file(&manifest, &receive_directory).await?;
        let resume_offset = match completed_path.as_ref() {
            Some(_) => manifest.file_size,
            None => existing_partial_offset(&manifest, &receive_directory).await?,
        };
        write_file_decision(&mut send, true, resume_offset).await?;
        if let Some(local_path) = completed_path {
            if !state
                .transfer
                .manager
                .mark_transferring(&manifest.transfer_id)
                .await
                || !state
                    .transfer
                    .manager
                    .update_progress(&manifest.transfer_id, manifest.file_size)
                    .await
                || !state
                    .transfer
                    .manager
                    .mark_verifying(&manifest.transfer_id)
                    .await
            {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    TransferAttemptError::stale_attempt(TransferFailureReason::Protocol).into(),
                );
            }
            write_file_completion(&mut send).await?;
            send.finish()?;
            if !state
                .transfer
                .manager
                .mark_completed(&manifest.transfer_id)
                .await
            {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    TransferAttemptError::stale_attempt(TransferFailureReason::Protocol).into(),
                );
            }
            state
                .transfer
                .manager
                .remove_transfer(&manifest.transfer_id)
                .await;
            emit_transfer_completed(
                &state.event_tx,
                &peer_id,
                &manifest.transfer_id,
                &local_path,
            );
            return Ok(());
        }
        if !state
            .transfer
            .manager
            .mark_transferring(&manifest.transfer_id)
            .await
        {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "transfer is no longer awaiting approval",
                )
                .into(),
            );
        }
        state
            .transfer
            .manager
            .update_progress(&manifest.transfer_id, resume_offset)
            .await;
        let cancellation = state
            .transfer
            .manager
            .cancellation_token(&manifest.transfer_id)
            .await;
        let (progress_tx, progress_rx) = channel(TRANSFER_PROGRESS_QUEUE_CAPACITY);
        let _ = state.task_supervisor.spawn_session(
            session_key.clone(),
            "file-receive-progress",
            forward_progress(
                manifest.transfer_id.clone(),
                peer_id.clone(),
                progress_rx,
                state.event_tx.clone(),
                state.transfer.manager.clone(),
                true,
            ),
        );
        let local_path = stream_receive_file_cancellable(
            &manifest,
            &receive_directory,
            resume_offset,
            &mut receive,
            Some(progress_tx),
            cancellation.as_ref(),
        )
        .await?;
        if !state
            .transfer
            .manager
            .mark_verifying(&manifest.transfer_id)
            .await
        {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError::stale_attempt(TransferFailureReason::Protocol).into(),
            );
        }
        write_file_completion(&mut send).await?;
        send.finish()?;
        if !state
            .transfer
            .manager
            .mark_completed(&manifest.transfer_id)
            .await
        {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError::stale_attempt(TransferFailureReason::Protocol).into(),
            );
        }
        state
            .transfer
            .manager
            .remove_transfer(&manifest.transfer_id)
            .await;
        emit_transfer_completed(
            &state.event_tx,
            &peer_id,
            &manifest.transfer_id,
            &local_path,
        );
        Ok(())
    }
    .await;
    let preserve_partial = result
        .as_ref()
        .err()
        .is_some_and(|error| is_transient_transport_error(error.as_ref()));
    if let Some(transfer_id) = active_transfer_id.as_deref() {
        state
            .transfer
            .incoming_decisions
            .write()
            .await
            .remove(transfer_id);
        if registered_transfer && result.is_err() && preserve_partial {
            state.transfer.manager.pause_for_network(transfer_id).await;
        } else if registered_transfer && result.is_err() {
            state.transfer.manager.remove_transfer(transfer_id).await;
            let receive_directory = state.lifecycle.receive_directory.read().await.clone();
            if let Some(receive_directory) = receive_directory {
                tokio::fs::remove_file(receive_directory.join(format!("{transfer_id}.part")))
                    .await
                    .ok();
            }
        }
    }
    if let Err(error) = result {
        if let Some(transfer_id) = active_transfer_id.as_deref() {
            if state.transfer.manager.snapshot(transfer_id).await.is_none() {
                return;
            }
        }
        if preserve_partial {
            tracing::debug!(peer_id = %peer_id, error = %error, "incoming native transfer paused for resume");
            return;
        }
        let reason = error
            .downcast_ref::<TransferAttemptError>()
            .map_or(TransferFailureReason::Io, |error| error.reason);
        emit_transfer_error(
            &state.event_tx,
            active_transfer_id.as_deref().unwrap_or("incoming"),
            transfer_failure_code(reason),
            "incoming file transfer failed".to_string(),
            "receive",
            Some(&peer_id),
        );
        tracing::debug!(peer_id = %peer_id, error = %error, "incoming native file transfer failed");
    }
}

/// 将 UI 审批决定应用到待处理直连传输。
pub(crate) async fn respond_to_incoming(
    state: &RuntimeState,
    response: RespondIncomingTransferCommand,
) -> Result<(), ProtocolError> {
    if let Some(sender) = state
        .transfer
        .incoming_decisions
        .write()
        .await
        .remove(&response.transfer_id)
    {
        return sender.send(response.accept).map_err(|_| {
            protocol_error(
                NetworkErrorCode::Cancelled,
                "incoming transfer approval expired",
            )
        });
    }
    state
        .respond_to_relay_incoming(&response.transfer_id, response.accept)
        .await
}
