use super::*;

use crate::connect::CAPABILITY_RELIABLE_STREAM;

/// 发送文件控制取消信封（body = transfer_id）。
pub(crate) async fn send_file_cancel(
    data: &RelayDataClient,
    transfer_id: &str,
) -> Result<(), RelayError> {
    send_data_envelope(data, DATA_ENV_FILE_CANCEL, transfer_id.as_bytes()).await
}

/// 取消或失败后移除待处理和临时 Relay 状态。
pub(crate) async fn cancel_relay_incoming(state: &RuntimeState, session_or_transfer_id: &str) {
    let pending = state
        .relay
        .pending_incoming
        .write()
        .await
        .remove(session_or_transfer_id);
    let active = {
        let mut active_transfers = state.relay.active_incoming.lock().await;
        if let Some(active) = active_transfers.remove(session_or_transfer_id) {
            Some((session_or_transfer_id.to_string(), active))
        } else {
            let transfer_id = active_transfers
                .iter()
                .find(|(_, active)| active.offer.session_id == session_or_transfer_id)
                .map(|(transfer_id, _)| transfer_id.clone());
            transfer_id.and_then(|transfer_id| {
                active_transfers
                    .remove(&transfer_id)
                    .map(|active| (transfer_id, active))
            })
        }
    };
    let transfer_id = pending
        .as_ref()
        .map(|pending| pending.transfer_id.clone())
        .or_else(|| active.as_ref().map(|(transfer_id, _)| transfer_id.clone()))
        .unwrap_or_else(|| session_or_transfer_id.to_string());
    if let Some((_, active)) = active {
        drop(active.file);
        tokio::fs::remove_file(active.temporary_path).await.ok();
    } else if let Some(directory) = state.lifecycle.receive_directory.read().await.clone() {
        tokio::fs::remove_file(relay_partial_path(&directory, &transfer_id))
            .await
            .ok();
    }
    state.transfer.manager.cancel_transfer(&transfer_id).await;
    state.transfer.manager.remove_transfer(&transfer_id).await;
}

/// CancelTransfer 的 Relay 侧清理入口；显式取消才会删除 checkpoint。
pub(crate) async fn cancel_transfer(state: &RuntimeState, transfer_id: &str) {
    // 取消只发到承载该 transfer 的对端 reservation 连接（按 transfer 所属 peer 定位）。
    if let Some(peer_id) = state
        .transfer
        .manager
        .snapshot(transfer_id)
        .await
        .map(|snapshot| snapshot.peer_id)
    {
        if let Ok(lease) = state
            .acquire_relay_path_lease(&peer_id, CAPABILITY_RELIABLE_STREAM)
            .await
        {
            if let Some(data) = lease.relay_data() {
                let _ = send_file_cancel(&data, transfer_id).await;
            }
        }
    }
    // Explicit cancellation is an owner boundary for both waiter maps. Drop
    // their senders so an in-flight offer/complete awaiter wakes immediately
    // instead of retaining a dead transfer identity after RemovePeer or
    // CancelTransfer.
    state.relay.acceptances.write().await.remove(transfer_id);
    state.relay.completions.write().await.remove(transfer_id);
    cancel_relay_incoming(state, transfer_id).await;
}

impl RelayTransferPort for RuntimeState {
    fn dispatch_relay_transfer(
        self: Arc<Self>,
        peer: PeerConfig,
        transfer: ResumableTransfer,
        lease: crate::connect::PathLease,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'static>> {
        Box::pin(async move {
            send_file_over_relay(peer, transfer, self, lease).await;
        })
    }

    fn respond_to_relay_incoming<'a>(
        &'a self,
        transfer_id: &'a str,
        accepted: bool,
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<Output = Result<(), network_protocol::NetworkError>>
                + Send
                + 'a,
        >,
    > {
        Box::pin(respond_to_relay_incoming(self, transfer_id, accepted))
    }

    fn cancel_relay_transfer<'a>(
        &'a self,
        transfer_id: &'a str,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>> {
        Box::pin(cancel_transfer(self, transfer_id))
    }
}
