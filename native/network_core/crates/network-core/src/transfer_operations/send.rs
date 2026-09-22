use super::*;

/// Ensure a business-capable path without enabling long-lived peer maintenance.
///
/// SessionId is deliberately absent from this decision: it is only attached
/// later when a concrete transport attempt needs a current wire/task key.
pub(crate) async fn ensure_business_path(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    command_id: &str,
    class: CommunicationClass,
    required_capabilities: u8,
) -> Result<(), CoreNetworkError> {
    if let Ok(lease) = state
        .acquire_path_lease(peer_id, required_capabilities)
        .await
    {
        drop(lease);
        return Ok(());
    }
    RuntimeState::ensure_business_path(
        Arc::clone(state),
        peer_id,
        command_id,
        class,
        required_capabilities,
    )
    .await
    .map(|_| ())
}

/// 校验源文件，并交给当前逻辑 Session 的 Route Dispatcher。
pub(crate) async fn start_file_send(
    state: Arc<RuntimeState>,
    command: SendFileCommand,
) -> Result<(), ProtocolError> {
    if !valid_transfer_identity(&command.transfer_id, &command.peer_id)
        || command.file_path.is_empty()
    {
        return Err(crate::events::protocol_error_with_context(
            NetworkErrorCode::InvalidArgument,
            "transfer_id, peer_id, and file_path are required",
            "send",
            Some(&command.peer_id),
        ));
    }
    let path = PathBuf::from(&command.file_path);
    let metadata = tokio::fs::metadata(&path).await.map_err(|_| {
        protocol_error_with_peer(
            NetworkErrorCode::IoError,
            "source file is unavailable",
            "send",
            &command.peer_id,
        )
    })?;
    if !metadata.is_file() {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "source is not a regular file",
            "send",
            &command.peer_id,
        ));
    }
    if !state.peers.read().await.contains_key(&command.peer_id) {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "peer is not registered",
            "send",
            &command.peer_id,
        ));
    }
    let manifest = build_file_manifest(command.transfer_id.clone(), &path)
        .await
        .map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::IoError,
                "source file cannot be hashed",
                "send",
                &command.peer_id,
            )
        })?;
    manifest.validate().map_err(|message| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            message,
            "send",
            &command.peer_id,
        )
    })?;
    let identity = TransferIdentity::new(command.peer_id.clone(), command.transfer_id.clone())
        .map_err(|message| {
            protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                message,
                "send",
                &command.peer_id,
            )
        })?;
    let dispatcher = TransferDispatcher::new(Arc::clone(&state));
    let (route, lease) = dispatcher.select_attempt(&identity).await?;
    // §19：TransferOperation 按 transfer_id + peer_id 注册，SessionId 不进入
    // 持久化的业务状态；仅为本次 transport attempt 附加当前 wire/task key。
    if !state
        .transfer
        .manager
        .register_outgoing(manifest.clone(), path.clone(), command.peer_id.clone())
        .await
    {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "transfer_id is already active",
            "send",
            &command.peer_id,
        ));
    }
    let session_key = state
        .connection_sessions
        .current_session_id(&identity.peer_id)
        .await
        .map(|session_id| session_id.wire_key())
        .unwrap_or_else(|| format!("transfer:{}", identity.transfer_id));
    let transfer = ResumableTransfer {
        transfer_id: manifest.transfer_id.clone(),
        peer_id: identity.peer_id.clone(),
        session_id: session_key,
        source_path: path,
        manifest,
        offset: 0,
    };
    if let Err(error) = dispatcher.dispatch_outgoing(route, lease, transfer).await {
        state
            .transfer
            .manager
            .remove_transfer(&command.transfer_id)
            .await;
        return Err(error);
    }
    Ok(())
}

/// 流式传输直连 QUIC 文件；Route handle 由 dispatcher 注入，业务状态仍
/// 只通过 TransferManager 更新。
pub(crate) async fn send_file(
    connection: Connection,
    transfer: ResumableTransfer,
    state: Arc<RuntimeState>,
    lease: PathLease,
) {
    let transfer_id = transfer.transfer_id.clone();
    let peer_id = transfer.peer_id.clone();
    let result = async {
        if !lease.is_active() {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(std::io::ErrorKind::NotConnected, "business path was lost")
                    .into(),
            );
        }
        let current_manifest =
            build_file_manifest(transfer_id.clone(), &transfer.source_path).await?;
        if current_manifest != transfer.manifest {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError {
                    reason: TransferFailureReason::SourceChanged,
                    recovery_error: BusinessRecoveryError::ResumeRejected,
                    terminal: true,
                    message: "source file changed during resumable transfer",
                }
                .into(),
            );
        }
        let (mut send, mut receive) = connection.open_bi().await?;
        if !lease.is_active() {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(std::io::ErrorKind::NotConnected, "business path was lost")
                    .into(),
            );
        }
        write_file_offer(&mut send, &transfer.manifest).await?;
        let offset = read_file_decision(&mut receive)
            .await?
            .ok_or(TransferAttemptError {
                reason: TransferFailureReason::UserRejected,
                recovery_error: BusinessRecoveryError::ResumeRejected,
                terminal: true,
                message: "receiver rejected file",
            })?;
        if offset > transfer.manifest.file_size {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError {
                    reason: TransferFailureReason::Protocol,
                    recovery_error: BusinessRecoveryError::ResumeRejected,
                    terminal: true,
                    message: "invalid resume offset",
                }
                .into(),
            );
        }
        if !state.transfer.manager.mark_transferring(&transfer_id).await {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError {
                    reason: TransferFailureReason::Protocol,
                    recovery_error: BusinessRecoveryError::ResumeRejected,
                    terminal: true,
                    message: "transfer is no longer resumable",
                }
                .into(),
            );
        }
        state
            .transfer
            .manager
            .update_progress(&transfer_id, offset)
            .await;
        let (progress_tx, progress_rx) = channel(TRANSFER_PROGRESS_QUEUE_CAPACITY);
        let _ = state.task_supervisor.spawn_session(
            transfer.session_id.clone(),
            "file-send-progress",
            forward_progress(
                transfer_id.clone(),
                peer_id.clone(),
                progress_rx,
                state.event_tx.clone(),
                state.transfer.manager.clone(),
                false,
            ),
        );
        let cancellation = state
            .transfer
            .manager
            .cancellation_token(&transfer_id)
            .await;
        if !lease.is_active() {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(std::io::ErrorKind::NotConnected, "business path was lost")
                    .into(),
            );
        }
        stream_send_file_cancellable(
            &transfer.source_path,
            offset,
            &mut send,
            Some(progress_tx),
            cancellation.as_ref(),
        )
        .await?;
        if !lease.is_active() {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(std::io::ErrorKind::NotConnected, "business path was lost")
                    .into(),
            );
        }
        send.finish()?;
        if !state.transfer.manager.mark_verifying(&transfer_id).await {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError::stale_attempt(TransferFailureReason::Protocol).into(),
            );
        }
        tokio::time::timeout(
            TRANSFER_COMPLETION_TIMEOUT,
            read_file_completion(&mut receive),
        )
        .await
        .map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::TimedOut, "file completion timed out")
        })??;
        if !state
            .transfer
            .manager
            .update_progress(&transfer_id, transfer.manifest.file_size)
            .await
            || !state.transfer.manager.mark_completed(&transfer_id).await
        {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError::stale_attempt(TransferFailureReason::Protocol).into(),
            );
        }
        emit_transfer_completed(&state.event_tx, &peer_id, &transfer_id, "");
        Ok(())
    }
    .await;
    match result {
        Ok(()) => state.transfer.manager.remove_transfer(&transfer_id).await,
        Err(error)
            if !state.transfer.manager.is_cancelled(&transfer_id).await
                && is_transient_transport_error(error.as_ref())
                && state.transfer.manager.pause_for_network(&transfer_id).await =>
        {
            // 保留源文件、TransferId 和接收端的 `.part`，等待
            // 同一 Peer 的下一次兼容 PathLease。
            tracing::debug!(transfer_id = %transfer_id, error = %error, "native QUIC transfer paused for resume");
        }
        Err(error) => {
            if error
                .downcast_ref::<TransferAttemptError>()
                .is_some_and(|attempt| !attempt.terminal)
            {
                return;
            }
            if state
                .transfer
                .manager
                .snapshot(&transfer_id)
                .await
                .is_none()
            {
                return;
            }
            let reason = error
                .downcast_ref::<TransferAttemptError>()
                .map_or(TransferFailureReason::Io, |error| error.reason);
            let recovery_error = error
                .downcast_ref::<TransferAttemptError>()
                .map_or(BusinessRecoveryError::OperationExpired, |error| {
                    error.recovery_error()
                });
            let code = transfer_failure_code(reason);
            if state
                .transfer
                .manager
                .fail_transfer(&transfer_id, reason)
                .await
            {
                emit_transfer_error(
                    &state.event_tx,
                    &transfer_id,
                    code,
                    "file transfer failed".to_string(),
                    "send",
                    Some(&peer_id),
                );
                state.transfer.manager.remove_transfer(&transfer_id).await;
            }
            tracing::debug!(
                transfer_id = %transfer_id,
                recovery_error = %recovery_error,
                error = %error,
                "native file transfer failed"
            );
        }
    }
}
