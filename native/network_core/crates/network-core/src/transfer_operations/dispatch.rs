use super::*;

pub(crate) fn valid_transfer_identity(transfer_id: &str, peer_id: &str) -> bool {
    is_valid_peer_id(peer_id)
        && !transfer_id.is_empty()
        && transfer_id.len() <= 128
        && transfer_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

/// 将流 worker 的有界传输进度转发为事件。
pub(crate) async fn forward_progress(
    transfer_id: String,
    peer_id: String,
    mut progress: Receiver<(u64, u64)>,
    event_tx: EventSender,
    manager: TransferManager,
    confirm_offset: bool,
) {
    while let Some((bytes_transferred, total_bytes)) = progress.recv().await {
        let accepted = if confirm_offset {
            manager
                .update_progress(&transfer_id, bytes_transferred)
                .await
        } else {
            manager.snapshot(&transfer_id).await.is_some()
        };
        if accepted {
            emit_transfer_progress_for_peer(
                &event_tx,
                &peer_id,
                &transfer_id,
                bytes_transferred,
                total_bytes,
                false,
            );
        } else {
            return;
        }
    }
}

/// 区分可通过新 Connection 恢复的 transport 失败与 manifest/审批/校验失败。
pub(crate) fn is_transient_transport_error(error: &(dyn Error + 'static)) -> bool {
    let mut current = Some(error);
    while let Some(error) = current {
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
        if let Some(error) = error.downcast_ref::<quinn::ConnectionError>() {
            if matches!(
                error,
                quinn::ConnectionError::TransportError(_)
                    | quinn::ConnectionError::ConnectionClosed(_)
                    | quinn::ConnectionError::ApplicationClosed(_)
                    | quinn::ConnectionError::Reset
                    | quinn::ConnectionError::TimedOut
            ) {
                return true;
            }
        }
        current = error.source();
    }
    false
}

pub(crate) fn transfer_failure_code(reason: TransferFailureReason) -> NetworkErrorCode {
    match reason {
        TransferFailureReason::UserRejected => NetworkErrorCode::Cancelled,
        TransferFailureReason::Permission => NetworkErrorCode::InvalidArgument,
        TransferFailureReason::Protocol => NetworkErrorCode::InvalidArgument,
        TransferFailureReason::HashMismatch
        | TransferFailureReason::SourceChanged
        | TransferFailureReason::Io => NetworkErrorCode::IoError,
        TransferFailureReason::RetryBudgetExhausted => NetworkErrorCode::Timeout,
        TransferFailureReason::SessionReplaced => NetworkErrorCode::PathLost,
    }
}

/// 将传输专属命令分发到所属传输子系统。
pub(crate) async fn dispatch_transfer_command(
    state: Arc<RuntimeState>,
    command: NetworkCommand,
) -> Result<(), ProtocolError> {
    match command.payload {
        Some(network_protocol::network_command::Payload::SendFile(send)) => {
            start_file_send(state, send).await
        }
        Some(network_protocol::network_command::Payload::CancelTransfer(cancel)) => {
            if state
                .transfer
                .manager
                .cancel_transfer(&cancel.transfer_id)
                .await
            {
                // A direct receiver may still be waiting for the UI decision.
                // Wake that exact waiter so CancelTransfer is observable on
                // the wire instead of leaving the sender blocked until the
                // approval timeout.
                if let Some(decision) = state
                    .transfer
                    .incoming_decisions
                    .write()
                    .await
                    .remove(&cancel.transfer_id)
                {
                    let _ = decision.send(false);
                }
                state.cancel_relay_transfer(&cancel.transfer_id).await;
                Ok(())
            } else {
                Err(protocol_error(
                    NetworkErrorCode::InvalidArgument,
                    "transfer is not active",
                ))
            }
        }
        Some(network_protocol::network_command::Payload::RespondIncomingTransfer(response)) => {
            respond_to_incoming(&state, response).await
        }
        _ => Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "unsupported transfer command",
        )),
    }
}

impl TransferRelayPort for RuntimeState {
    fn resume_relay_transfers(
        self: Arc<Self>,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'static>> {
        Box::pin(async move {
            resume_relay_transfers(self).await;
        })
    }

    fn resume_transfers_for_peer(
        self: Arc<Self>,
        peer_id: String,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'static>> {
        Box::pin(async move {
            resume_transfers_for_peer(self, peer_id).await;
        })
    }
}
