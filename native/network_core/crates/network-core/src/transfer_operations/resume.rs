use super::*;

/// 新 ConnectionSession 建立后领取同一 Peer 的暂停传输（§19 ResumeTransfer）。
///
/// 领取按 transfer_id + peer_id 进行；当前 ConnectionSession 的 wire key 作为
/// `session_id` 附加到每个 ResumableTransfer（Relay E2EE / 任务分组），并在新的
/// QUIC/Relay 连接上重新协商 confirmed_offset。
pub(crate) async fn resume_transfers_for_peer(state: Arc<RuntimeState>, peer_id: String) {
    if !is_valid_peer_id(&peer_id) {
        return;
    }
    let dispatcher = TransferDispatcher::new(Arc::clone(&state));
    let Some(session_id) = state.connection_sessions.current_session_id(&peer_id).await else {
        return;
    };
    let session_key = session_id.wire_key();
    let transfers = state
        .transfer
        .manager
        .take_resumable_for_peer(&peer_id, &session_key)
        .await;
    for transfer in transfers {
        let identity = TransferIdentity {
            peer_id: peer_id.clone(),
            transfer_id: transfer.transfer_id.clone(),
        };
        let attempt = match dispatcher.select_attempt(&identity).await {
            Ok(attempt) => attempt,
            Err(error) => {
                let _ = state
                    .transfer
                    .manager
                    .pause_for_network(&transfer.transfer_id)
                    .await;
                tracing::debug!(
                    peer_id = %peer_id,
                    transfer_id = %transfer.transfer_id,
                    error = ?error,
                    "transfer resume waited for a fresh path lease"
                );
                continue;
            }
        };
        if dispatcher
            .dispatch_outgoing(attempt.0, attempt.1, transfer)
            .await
            .is_err()
        {
            tracing::debug!(peer_id = %peer_id, "transfer remained paused after resume dispatch failed");
        }
    }
}

/// Relay socket 重连后恢复所有仍处于 Relay Route 的暂停传输。
pub(crate) async fn resume_relay_transfers(state: Arc<RuntimeState>) {
    let peer_ids = state.peers.read().await.keys().cloned().collect::<Vec<_>>();
    for peer_id in peer_ids {
        resume_transfers_for_peer(Arc::clone(&state), peer_id).await;
    }
}
