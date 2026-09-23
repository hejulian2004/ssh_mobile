use network_protocol::{PeerConnectionState, RouteType};
use network_quic::{read_channel_frame, ChannelFrameKind};
use network_relay::RelayDataClient;
use quinn::Connection;
use std::future::Future;
use std::sync::{atomic::Ordering, Arc};
use tokio::sync::{mpsc, oneshot};

use crate::connection::{GenericFrameKind, GenericInboundFrame, GenericRouteHandle};
use crate::events::emit_peer_state;
use crate::runtime::RuntimeState;
use crate::session::SessionId;

use super::GENERIC_ROUTE_CONNECT_TIMEOUT;

/// Owns session-scoped QUIC/generic receivers and path-loss cleanup.
pub(crate) struct ConnectionReceiverSupervisor;

/// 接受一个已认证对端的双向流。共享的 `accept_bi` 循环按首 4 字节路由：
/// 文件 offer (`SMFT`) 走 `handle_incoming_file_after_offer`，ReliableStream
/// 前导 (`SMSS`) 走 `crate::stream`（§17）。首 4 字节被消耗后，
/// 文件 offer 的其余字段由 `read_file_offer_after_magic` 续读，因此文件数据
/// 路径与原 `read_file_offer` 完全一致。
impl ConnectionReceiverSupervisor {
    pub(crate) async fn receive_file_streams(
        peer_id: String,
        connection: Connection,
        state: Arc<RuntimeState>,
        session_id: SessionId,
    ) {
        loop {
            match connection.accept_bi().await {
                Ok((send, mut receive)) => {
                    let state = Arc::clone(&state);
                    let peer_id = peer_id.clone();
                    let inbound_connection = connection.clone();
                    let supervisor = Arc::clone(&state.task_supervisor);
                    let _ = supervisor.spawn_session(
                    session_id.wire_key(),
                    "bidi-stream-receiver",
                    async move {
                        let mut magic = [0u8; 4];
                        if tokio::time::timeout(
                            GENERIC_ROUTE_CONNECT_TIMEOUT,
                            receive.read_exact(&mut magic),
                        )
                        .await
                        .ok()
                        .and_then(Result::ok)
                        .is_none()
                        {
                            return;
                        }
                        if magic == crate::stream::FILE_OFFER_MAGIC {
                            match crate::transfer::read_file_offer_after_magic(&mut receive).await {
                                Ok(manifest) => {
                                    let path_lease = match state
                                        .acquire_path_lease_for_connection(
                                            &peer_id,
                                            &inbound_connection,
                                            crate::connect::CAPABILITY_RELIABLE_STREAM,
                                        )
                                        .await
                                    {
                                        Ok(lease) => lease,
                                        Err(error) => {
                                            tracing::debug!(
                                                peer_id = %peer_id,
                                                error = %error,
                                                "rejected QUIC file offer without its carrier path"
                                            );
                                            return;
                                        }
                                    };
                                    crate::transfer::handle_incoming_file_after_offer(
                                        peer_id, send, receive, manifest, state, path_lease,
                                    )
                                    .await;
                                }
                                Err(error) => {
                                    tracing::debug!(
                                        peer_id = %peer_id,
                                        error = %error,
                                        "rejected QUIC file offer"
                                    );
                                }
                            }
                        } else if magic == crate::stream::STREAM_QUIC_PREAMBLE_MAGIC {
                            match crate::stream::read_quic_stream_preamble_after_magic(&mut receive)
                                .await
                            {
                                Ok((stream_id, service)) => {
                                    crate::stream::handle_incoming_quic_stream(
                                        state,
                                        peer_id,
                                        stream_id,
                                        service,
                                        inbound_connection,
                                        send,
                                        receive,
                                    )
                                    .await;
                                }
                                Err(error) => {
                                    tracing::debug!(
                                        peer_id = %peer_id,
                                        error = %error,
                                        "rejected QUIC reliable-stream preamble"
                                    );
                                }
                            }
                        }
                    },
                );
                }
                Err(_) => {
                    Self::handle_connection_disconnect(&state, &peer_id, &connection).await;
                    return;
                }
            }
        }
    }

    /// 接收一条 QUIC 单向 Delivery stream；stream 关闭只影响当前 Connection，
    /// 逻辑消息仍由 DeliveryManager 在下一条 Connection 上恢复。
    pub(crate) async fn receive_channel_streams(
        peer_id: String,
        connection: Connection,
        state: Arc<RuntimeState>,
        session_id: SessionId,
    ) {
        loop {
            match connection.accept_uni().await {
                Ok(mut receive) => {
                    let state = Arc::clone(&state);
                    let peer_id = peer_id.clone();
                    let supervisor = Arc::clone(&state.task_supervisor);
                    let _ = supervisor.spawn_session(
                    session_id.wire_key(),
                    "channel-stream-receiver",
                    async move {
                    match read_channel_frame(&mut receive).await {
                        Ok((ChannelFrameKind::DataMessage, payload)) => {
                            if let Err(error) =
                                crate::channel::handle_data_message(&state, &peer_id, &payload)
                                    .await
                            {
                                tracing::debug!(peer_id = %peer_id, error = %error, "rejected QUIC DataMessage");
                            }
                        }
                        Ok((ChannelFrameKind::DeliveryAck, payload)) => {
                            if let Err(error) =
                                crate::channel::handle_delivery_ack(&state, &peer_id, &payload)
                                    .await
                            {
                                tracing::debug!(peer_id = %peer_id, error = %error, "rejected QUIC DeliveryAck");
                            }
                        }
                        Err(error) => {
                            tracing::debug!(peer_id = %peer_id, error = %error, "QUIC channel stream failed");
                        }
                    }
                    },
                );
                }
                Err(_) => {
                    Self::handle_connection_disconnect(&state, &peer_id, &connection).await;
                    return;
                }
            }
        }
    }

    pub(crate) fn spawn_session_receivers(
        state: Arc<RuntimeState>,
        peer_id: String,
        connection: Connection,
        session_id: SessionId,
    ) {
        let supervisor = Arc::clone(&state.task_supervisor);
        let _ = supervisor.spawn_session(
            session_id.wire_key(),
            "file-receiver",
            Self::receive_file_streams(
                peer_id.clone(),
                connection.clone(),
                Arc::clone(&state),
                session_id,
            ),
        );
        let _ = supervisor.spawn_session(
            session_id.wire_key(),
            "channel-receiver",
            Self::receive_channel_streams(peer_id, connection, Arc::clone(&state), session_id),
        );
    }
}

pub(crate) struct GenericReceiverStopGuard {
    pub(crate) route_stop: crate::task_supervisor::CancellationToken,
    pub(crate) stopping: Arc<std::sync::atomic::AtomicBool>,
}

impl Drop for GenericReceiverStopGuard {
    fn drop(&mut self) {
        if !self.stopping.load(Ordering::Acquire) {
            self.route_stop.cancel();
        }
    }
}

impl ConnectionReceiverSupervisor {
    pub(crate) fn generic_route_receiver_task(
        state: Arc<RuntimeState>,
        peer_id: String,
        handle: GenericRouteHandle,
        mut inbound: mpsc::Receiver<GenericInboundFrame>,
        session_id: SessionId,
        route_stop: crate::task_supervisor::CancellationToken,
        stopping: Arc<std::sync::atomic::AtomicBool>,
    ) -> (
        impl Future<Output = ()> + Send + 'static,
        oneshot::Receiver<()>,
    ) {
        let (ready_tx, ready_rx) = oneshot::channel();
        let route_id = handle.id();
        let task = async move {
            let _stop_guard = GenericReceiverStopGuard {
                route_stop: route_stop.clone(),
                stopping: Arc::clone(&stopping),
            };
            if ready_tx.send(()).is_err() {
                return;
            }
            loop {
                tokio::select! {
                    _ = route_stop.cancelled() => {
                        if !stopping.load(Ordering::Acquire) {
                            Self::notify_generic_route_loss(&state, &peer_id, route_id, session_id).await;
                        }
                        return;
                    }
                    frame = inbound.recv() => {
                        let Some(frame) = frame else {
                            route_stop.cancel();
                            if !stopping.load(Ordering::Acquire) {
                                Self::notify_generic_route_loss(&state, &peer_id, route_id, session_id).await;
                            }
                            return;
                        };
                        let result = match frame.kind {
                            GenericFrameKind::DataMessage => crate::channel::handle_data_message(
                                &state,
                                &peer_id,
                                &frame.payload,
                            )
                            .await
                            .map_err(|error| std::io::Error::other(error.to_string())),
                            GenericFrameKind::DeliveryAck => crate::channel::handle_delivery_ack(
                                &state,
                                &peer_id,
                                &frame.payload,
                            )
                            .await
                            .map_err(|error| std::io::Error::other(error.to_string())),
                            GenericFrameKind::StreamBytes
                            | GenericFrameKind::StreamOpen
                            | GenericFrameKind::StreamClose => crate::stream::handle_inbound_stream_frame(
                                &state,
                                &peer_id,
                                frame.kind,
                                &frame.payload,
                                crate::stream::InboundPath::Generic(route_id),
                            )
                            .await
                            .map_err(|error| std::io::Error::other(error.to_string())),
                        };
                        if let Err(error) = result {
                            // StreamBytes is a data path: a malformed stream frame
                            // fails that stream only, never the route (§17).
                            tracing::debug!(peer_id = %peer_id, error = %error, "rejected generic channel frame");
                        }
                    }
                }
            }
        };
        (task, ready_rx)
    }

    async fn notify_generic_route_loss(
        state: &Arc<RuntimeState>,
        peer_id: &str,
        route_id: crate::connection::GenericRouteId,
        session_id: SessionId,
    ) {
        if state
            .close_direct_path(peer_id, Some(route_id))
            .await
            .is_none()
        {
            return;
        }
        Self::finalize_path_loss(state, peer_id, session_id).await;
    }

    /// §18/§35：reservation 数据面断开即销毁 Relay ConnectionSession。仅当当前
    /// Session 的 route 仍由 `data` 承载时才拆除，并发布类型化断开状态。
    pub(crate) async fn teardown_relay_route(
        state: &Arc<RuntimeState>,
        peer_id: &str,
        data: &Arc<RelayDataClient>,
    ) {
        if !state.path_is_current_relay_data(peer_id, data).await {
            return;
        }
        let Some(session_id) = state.connection_sessions.current_session_id(peer_id).await else {
            return;
        };
        if state.close_relay_path(peer_id, Some(data)).await.is_none() {
            return;
        }
        Self::finalize_path_loss(state, peer_id, session_id).await;
    }

    async fn handle_connection_disconnect(
        state: &Arc<RuntimeState>,
        peer_id: &str,
        connection: &Connection,
    ) {
        let Some(session_id) = state.connection_sessions.current_session_id(peer_id).await else {
            return;
        };
        if state
            .close_direct_path_for_connection(peer_id, connection)
            .await
            .is_none()
        {
            return;
        }
        Self::finalize_path_loss(state, peer_id, session_id).await;
    }

    async fn finalize_path_loss(state: &Arc<RuntimeState>, peer_id: &str, session_id: SessionId) {
        if state.connection_sessions.current_session_id(peer_id).await != Some(session_id)
            || state.path_is_connected(peer_id).await
        {
            // Direct/Relay are independent physical slots. Losing one does not
            // invalidate the Session while the other remains usable.
            return;
        }
        if !state
            .connection_sessions
            .retire_session(peer_id, session_id)
            .await
        {
            return;
        }
        // This function is commonly called by a session-scoped receiver task.
        // Joining that same task group inline would await the current task and
        // deadlock before the public Disconnected event can be emitted.
        let cleanup_state = Arc::clone(state);
        let cleanup_peer_id = peer_id.to_string();
        let _ = state
            .task_supervisor
            .spawn_runtime("path-loss-cleanup", async move {
                cleanup_state
                    .cancel_session_tasks(&cleanup_peer_id, session_id)
                    .await;
            });
        if let Ok(supervisor) = state.peer_supervisors.get_or_create(peer_id) {
            supervisor.path_lost();
        }
        emit_peer_state(
            &state.event_tx,
            peer_id,
            PeerConnectionState::Disconnected,
            RouteType::Unspecified,
            None,
        );
        // transport-network v2（§18/§35）：最后一条 transport 丢失即销毁
        // ConnectionSession，不自动重连（无 RECONNECTING）。业务下次 `connect()`
        // 会重新 Resolve，并按需新建连接（新 SessionId + 新 Noise root）。
    }
}
