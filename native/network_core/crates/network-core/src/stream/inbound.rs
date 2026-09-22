use std::sync::Arc;

use network_relay::RelayDataClient;
use quinn::Connection;

use crate::connection::GenericFrameKind;
use crate::runtime::RuntimeState;

use super::session::{
    bind_inbound_attempt, close_stream_after_path_loss, inbound_stream_opener,
    local_stream_opener_peer_id,
};
use super::ssh_gateway::spawn_ssh_gateway;
use super::{
    decode_stream_bytes_frame, decode_stream_close_frame, decode_stream_open_frame, StreamConsumer,
    StreamError, StreamOpener, MAX_STREAM_FRAME_BYTES, STREAM_SERVICE_SSH,
};

/// Identifies the physical carrier that delivered an inbound stream frame.
/// The identity is deliberately stronger than a route preference: a path
/// replacement must not rebind an already-arrived stream to a different
/// carrier.
#[derive(Clone)]
pub(crate) enum InboundPath {
    Quic(Connection),
    Generic(crate::connection::GenericRouteId),
    Relay(Arc<RelayDataClient>),
    #[cfg(test)]
    Current,
}

/// Routes an inbound generic stream frame (from the generic-route receiver or
/// the relay channel receiver) to the per-stream reassembly buffer. A malformed
/// stream frame fails that stream only; it never tears down the route.
pub(crate) async fn handle_inbound_stream_frame(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    kind: GenericFrameKind,
    payload: &[u8],
    path: InboundPath,
) -> Result<(), StreamError> {
    match kind {
        GenericFrameKind::StreamOpen => {
            let (opener_peer_id, stream_id, service) = decode_stream_open_frame(payload)?;
            if inbound_stream_opener(state, peer_id, &opener_peer_id).await? != StreamOpener::Remote
            {
                return Err(StreamError::InvalidFrame);
            }
            handle_inbound_open(
                state,
                peer_id,
                StreamOpener::Remote,
                stream_id,
                &service,
                path,
            )
            .await
        }
        GenericFrameKind::StreamBytes => {
            let (opener_peer_id, stream_id, seq, data) = decode_stream_bytes_frame(payload)?;
            let opener = inbound_stream_opener(state, peer_id, &opener_peer_id).await?;
            let manager = state.stream_manager(peer_id).await;
            manager
                .handle_bytes(peer_id, opener, stream_id, seq, data.to_vec())
                .await
        }
        GenericFrameKind::StreamClose => {
            let (opener_peer_id, stream_id) = decode_stream_close_frame(payload)?;
            let opener = inbound_stream_opener(state, peer_id, &opener_peer_id).await?;
            let manager = state.stream_manager(peer_id).await;
            manager.handle_close(peer_id, opener, stream_id).await
        }
        _ => Err(StreamError::InvalidFrame),
    }
}

/// Handles an inbound stream open. A stream whose service hint is `ssh`
/// activates the native gateway-to-sshd bridge on this peer; any other service
/// is delivered to the app as events.
pub(crate) async fn handle_inbound_open(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
    service: &str,
    path: InboundPath,
) -> Result<(), StreamError> {
    let consumer = if service == STREAM_SERVICE_SSH {
        StreamConsumer::Bridge
    } else {
        StreamConsumer::Event
    };
    let manager = state.stream_manager(peer_id).await;
    match manager
        .handle_open(opener, stream_id, service, consumer)
        .await
    {
        Ok(()) => {}
        Err(StreamError::AlreadyOpen) => {
            // 同一 stream_id 的重复 open：丢弃这个重复的 open，已存在的活动流
            // 保持原样。绝不能调用 handle_close——那会把现有活动流的接收侧
            // 标记关闭，拆掉一条活着的 SSH 会话（修复 #5）。
            return Ok(());
        }
        Err(error) => return Err(error),
    }
    if let Err(error) =
        bind_inbound_attempt(state, peer_id, &manager, opener, stream_id, &path).await
    {
        let _ = close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await;
        return Err(error);
    }
    if consumer == StreamConsumer::Bridge {
        spawn_ssh_gateway(Arc::clone(state), peer_id.to_string(), opener, stream_id);
    } else {
        spawn_stream_event_emitter(state, peer_id, opener, stream_id).await;
    }
    Ok(())
}

/// Handles an inbound QUIC bidi reliable stream (preamble already read by the
/// shared `accept_bi` loop). Registers the stream, pumps the peer's write half
/// into the reassembly buffer, and activates the SSH gateway when the service
/// hint is `ssh`.
pub(crate) async fn handle_incoming_quic_stream(
    state: Arc<RuntimeState>,
    peer_id: String,
    stream_id: u16,
    service: String,
    connection: Connection,
    send: quinn::SendStream,
    receive: quinn::RecvStream,
) {
    let consumer = if service == STREAM_SERVICE_SSH {
        StreamConsumer::Bridge
    } else {
        StreamConsumer::Event
    };
    let manager = state.stream_manager(&peer_id).await;
    match manager
        .handle_open(StreamOpener::Remote, stream_id, &service, consumer)
        .await
    {
        Ok(()) => {}
        Err(StreamError::AlreadyOpen) => {
            // 重复 open：丢弃这个重复的 QUIC 流，已存在的活动流保持原样，
            // 绝不能 handle_close 掉现有流（修复 #5）。
            return;
        }
        Err(_) => return,
    }
    if bind_inbound_attempt(
        &state,
        &peer_id,
        &manager,
        StreamOpener::Remote,
        stream_id,
        &InboundPath::Quic(connection),
    )
    .await
    .is_err()
    {
        let _ =
            close_stream_after_path_loss(&manager, &peer_id, StreamOpener::Remote, stream_id).await;
        return;
    }
    if manager
        .register_quic_send(StreamOpener::Remote, stream_id, send)
        .await
        .is_err()
    {
        let _ = manager
            .handle_close(&peer_id, StreamOpener::Remote, stream_id)
            .await;
        return;
    }
    spawn_quic_stream_reader(&state, &peer_id, StreamOpener::Remote, stream_id, receive).await;
    if consumer == StreamConsumer::Bridge {
        spawn_ssh_gateway(state, peer_id, StreamOpener::Remote, stream_id);
    } else {
        spawn_stream_event_emitter(&state, &peer_id, StreamOpener::Remote, stream_id).await;
    }
}

// ---------------------------------------------------------------------------
// QUIC stream reader pump, Event-mode drainer and the SSH gateway bridge
// ---------------------------------------------------------------------------

/// 启动 Event-mode 流的 per-stream drainer 任务（设计 §17）：把有界缓冲区里
/// 的入站字节转成 `SshStreamDataReceived` 事件。Event 流因此与 Bridge/Poll
/// 共享同一有界缓冲区与背压——writer 在 `MAX_PER_STREAM_BUFFER_CAPACITY`
/// 处阻塞，而不是逐帧直接灌入无界事件通道。
pub(crate) async fn spawn_stream_event_emitter(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
) {
    let opener_device_id = match opener {
        StreamOpener::Local => match local_stream_opener_peer_id(state).await {
            Ok(device_id) => device_id,
            Err(_) => return,
        },
        StreamOpener::Remote => peer_id.to_string(),
    };
    let manager = state.stream_manager(peer_id).await;
    let peer_id = peer_id.to_string();
    let task_key = format!("stream:{peer_id}:{stream_id}");
    let _ = state
        .task_supervisor
        .spawn_session(task_key, "stream-event-emitter", async move {
            manager
                .drain_events(&peer_id, opener, stream_id, &opener_device_id)
                .await
        });
}

/// Pumps a QUIC `RecvStream` (the peer's write half of a logical byte stream)
/// into the per-stream reassembly buffer.
pub(crate) async fn spawn_quic_stream_reader(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
    mut recv: quinn::RecvStream,
) {
    let state = Arc::clone(state);
    let peer_id = peer_id.to_string();
    let task_key = format!("stream:{peer_id}:{stream_id}");
    let supervisor = Arc::clone(&state.task_supervisor);
    let _ = supervisor.spawn_session(task_key, "reliable-stream-reader", async move {
        let manager = state.stream_manager(&peer_id).await;
        let mut buf = vec![0u8; MAX_STREAM_FRAME_BYTES];
        let mut seq = 0u64;
        loop {
            match recv.read(&mut buf).await {
                Ok(Some(n)) => {
                    let data = buf[..n].to_vec();
                    let _ = manager
                        .handle_bytes(&peer_id, opener, stream_id, seq, data)
                        .await;
                    seq += 1;
                }
                Ok(None) | Err(_) => {
                    let _ = manager.handle_close(&peer_id, opener, stream_id).await;
                    return;
                }
            }
        }
    });
}
