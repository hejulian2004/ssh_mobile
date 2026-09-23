use std::sync::Arc;

use network_protocol::{CommunicationClass, StreamHandle};
use tokio::io::AsyncWriteExt;

use crate::channel::{select_business_path_lease, send_business_frame};
use crate::connect::CAPABILITY_RELIABLE_STREAM;
use crate::connection::{GenericFrameKind, RouteTransport};
use crate::runtime::RuntimeState;

use super::inbound::{spawn_quic_stream_reader, spawn_stream_event_emitter};
use super::{
    encode_quic_stream_preamble, encode_stream_bytes_frame, encode_stream_close_frame,
    encode_stream_open_frame, stream_relay_token, validate_peer, InboundPath,
    ReliableStreamManager, StreamConsumer, StreamError, StreamOpener, MAX_STREAM_FRAME_BYTES,
};

// ---------------------------------------------------------------------------
// RuntimeState-level byte-stream operations
// ---------------------------------------------------------------------------

pub(crate) async fn local_stream_opener_peer_id(
    state: &Arc<RuntimeState>,
) -> Result<String, StreamError> {
    state
        .lifecycle
        .identity
        .read()
        .await
        .as_ref()
        .map(|identity| identity.device_id.clone())
        .ok_or(StreamError::NotConnected)
}

async fn stream_opener_peer_id(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
) -> Result<String, StreamError> {
    match opener {
        StreamOpener::Local => local_stream_opener_peer_id(state).await,
        StreamOpener::Remote => Ok(peer_id.to_string()),
    }
}

/// Resolves the opener for an FFI command from its explicit business handle.
/// A command can target either a locally opened stream or a stream opened by the
/// remote peer; the handle, never stream existence order, selects the namespace.
async fn command_stream_opener(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    handle: &StreamHandle,
) -> Result<(StreamOpener, u16), StreamError> {
    if !validate_peer(&handle.opener_device_id) {
        return Err(StreamError::InvalidArgument);
    }
    let stream_id = u16::try_from(handle.stream_id).map_err(|_| StreamError::InvalidArgument)?;
    if stream_id == 0 {
        return Err(StreamError::InvalidArgument);
    }
    let local_peer_id = local_stream_opener_peer_id(state).await?;
    let opener = if handle.opener_device_id == local_peer_id {
        StreamOpener::Local
    } else if handle.opener_device_id == peer_id {
        StreamOpener::Remote
    } else {
        return Err(StreamError::InvalidArgument);
    };
    let manager = state.stream_manager(peer_id).await;
    if manager.is_open(opener, stream_id).await {
        Ok((opener, stream_id))
    } else {
        Err(StreamError::NotFound)
    }
}

pub(crate) async fn inbound_stream_opener(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener_peer_id: &str,
) -> Result<StreamOpener, StreamError> {
    let local_peer_id = local_stream_opener_peer_id(state).await?;
    if opener_peer_id == local_peer_id {
        Ok(StreamOpener::Local)
    } else if opener_peer_id == peer_id {
        Ok(StreamOpener::Remote)
    } else {
        Err(StreamError::InvalidFrame)
    }
}

pub(crate) async fn close_stream_after_path_loss(
    manager: &ReliableStreamManager,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
) -> StreamError {
    // SSH/ReliableStream has no transparent recovery. Mark both halves closed
    // and wake the consumer so the application can explicitly open a new
    // logical stream after it has decided to reconnect.
    let _ = manager.handle_close(peer_id, opener, stream_id).await;
    let _ = manager.close_local(peer_id, opener, stream_id).await;
    StreamError::Closed
}

pub(crate) async fn bind_inbound_attempt(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    manager: &ReliableStreamManager,
    opener: StreamOpener,
    stream_id: u16,
    path: &InboundPath,
) -> Result<(), StreamError> {
    let lease_result = match path {
        InboundPath::Quic(connection) => {
            state
                .acquire_path_lease_for_connection(peer_id, connection, CAPABILITY_RELIABLE_STREAM)
                .await
        }
        InboundPath::Generic(route_id) => {
            state
                .acquire_path_lease_for_generic_route(
                    peer_id,
                    *route_id,
                    CAPABILITY_RELIABLE_STREAM,
                )
                .await
        }
        InboundPath::Relay(data) => {
            state
                .acquire_path_lease_for_relay_data(peer_id, data, CAPABILITY_RELIABLE_STREAM)
                .await
        }
        #[cfg(test)]
        InboundPath::Current => {
            select_business_path_lease(state, peer_id, CAPABILITY_RELIABLE_STREAM).await
        }
    };
    let lease = match lease_result {
        Ok(lease) => lease,
        Err(_) => {
            return Err(close_stream_after_path_loss(manager, peer_id, opener, stream_id).await)
        }
    };
    if !lease.is_active() {
        return Err(StreamError::NotConnected);
    }
    manager.bind_lease(opener, stream_id, lease).await
}

/// Opens a byte stream to a peer. `consumer` selects how inbound bytes are
/// delivered (events / bridge / poll).
pub(crate) async fn open_stream(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    stream_id: u16,
    service: &str,
    consumer: StreamConsumer,
) -> Result<(), StreamError> {
    crate::transfer::ensure_business_path(
        state,
        peer_id,
        &format!("stream-{stream_id}"),
        CommunicationClass::ReliableStream,
        CAPABILITY_RELIABLE_STREAM,
    )
    .await
    .map_err(|_| StreamError::NotConnected)?;
    let lease = select_business_path_lease(state, peer_id, CAPABILITY_RELIABLE_STREAM)
        .await
        .map_err(|_| StreamError::NotConnected)?;
    let opener_peer_id = local_stream_opener_peer_id(state).await?;
    let manager = state.stream_manager(peer_id).await;
    // Reserve the lease before emitting any wire bytes.  This prevents a
    // stale handle from sending StreamOpen on a new Session before the
    // manager rejects its retired identity.
    manager
        .open(StreamOpener::Local, stream_id, service, consumer)
        .await?;
    manager
        .bind_lease(StreamOpener::Local, stream_id, lease)
        .await?;
    // Keep the lease in the entry between operations; temporarily borrow it
    // only while the opening frame is written.
    let lease = manager.take_lease(StreamOpener::Local, stream_id).await?;
    let result = match lease.profile().transport() {
        RouteTransport::Quic => {
            async {
                if !lease.is_active() {
                    return Err(StreamError::Closed);
                }
                let connection = lease.connection().ok_or(StreamError::NotConnected)?;
                let (mut send, recv) = connection
                    .open_bi()
                    .await
                    .map_err(|error| StreamError::Send(error.to_string()))?;
                if !lease.is_active() {
                    return Err(StreamError::Closed);
                }
                let preamble = encode_quic_stream_preamble(stream_id, service)?;
                send.write_all(&preamble)
                    .await
                    .map_err(|error| StreamError::Send(error.to_string()))?;
                send.flush()
                    .await
                    .map_err(|error| StreamError::Send(error.to_string()))?;
                if !lease.is_active() {
                    return Err(StreamError::Closed);
                }
                manager
                    .register_quic_send(StreamOpener::Local, stream_id, send)
                    .await?;
                spawn_quic_stream_reader(state, peer_id, StreamOpener::Local, stream_id, recv)
                    .await;
                Ok(())
            }
            .await
        }
        _ => {
            async {
                let payload = encode_stream_open_frame(&opener_peer_id, stream_id, service)?;
                send_business_frame(
                    state,
                    peer_id,
                    &lease,
                    &stream_relay_token(&opener_peer_id, stream_id),
                    GenericFrameKind::StreamOpen,
                    &payload,
                )
                .await
                .map_err(|error| StreamError::Send(error.to_string()))
            }
            .await
        }
    };
    if let Err(error) = result {
        let _ =
            close_stream_after_path_loss(&manager, peer_id, StreamOpener::Local, stream_id).await;
        drop(lease);
        return Err(error);
    }
    if !manager
        .restore_lease(StreamOpener::Local, stream_id, lease)
        .await
    {
        let _ =
            close_stream_after_path_loss(&manager, peer_id, StreamOpener::Local, stream_id).await;
        return Err(StreamError::Closed);
    }
    if consumer == StreamConsumer::Event {
        spawn_stream_event_emitter(state, peer_id, StreamOpener::Local, stream_id).await;
    }
    Ok(())
}

/// Sends bytes on a byte stream. The generic route splits into bounded
/// StreamBytes frames and awaits the bounded route send (never drops); the
/// QUIC route writes raw bytes on the real QUIC stream.
pub(crate) async fn send_stream(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    handle: &StreamHandle,
    data: &[u8],
) -> Result<(), StreamError> {
    let (opener, stream_id) = command_stream_opener(state, peer_id, handle).await?;
    send_stream_with_opener(state, peer_id, opener, stream_id, data).await
}

pub(crate) async fn send_stream_with_opener(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
    data: &[u8],
) -> Result<(), StreamError> {
    if data.is_empty() {
        return Ok(());
    }
    let manager = state.stream_manager(peer_id).await;
    let opener_peer_id = stream_opener_peer_id(state, peer_id, opener).await?;
    let send_guard = manager.send_guard(opener, stream_id).await?;
    let _guard = send_guard.lock().await;
    let lease = match manager.take_lease(opener, stream_id).await {
        Ok(lease) => lease,
        Err(error) => {
            let _ = close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await;
            return Err(error);
        }
    };
    let result = match lease.profile().transport() {
        RouteTransport::Quic => {
            if !lease.is_active() {
                Err(StreamError::Closed)
            } else {
                manager.quic_send_bytes(opener, stream_id, data).await
            }
        }
        _ => {
            async {
                let seq = manager.next_send_seq(opener, stream_id).await?;
                let mut chunks = 0u64;
                for chunk in data.chunks(MAX_STREAM_FRAME_BYTES) {
                    let payload =
                        encode_stream_bytes_frame(&opener_peer_id, stream_id, seq + chunks, chunk)?;
                    send_business_frame(
                        state,
                        peer_id,
                        &lease,
                        &stream_relay_token(&opener_peer_id, stream_id),
                        GenericFrameKind::StreamBytes,
                        &payload,
                    )
                    .await
                    .map_err(|error| StreamError::Send(error.to_string()))?;
                    chunks += 1;
                }
                manager.bump_send_seq(opener, stream_id, chunks).await?;
                Ok(())
            }
            .await
        }
    };
    if !lease.is_active() {
        drop(lease);
        let _ = close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await;
        return Err(StreamError::Closed);
    }
    if let Err(error) = result {
        drop(lease);
        let _ = close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await;
        return Err(error);
    }
    if !manager.restore_lease(opener, stream_id, lease).await {
        let _ = close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await;
        return Err(StreamError::Closed);
    }
    Ok(())
}

/// Drains buffered bytes for a Bridge/Poll consumer.
#[allow(dead_code)]
pub(crate) async fn receive_stream(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    stream_id: u16,
    buf: &mut [u8],
) -> Result<usize, StreamError> {
    receive_stream_with_opener(state, peer_id, StreamOpener::Local, stream_id, buf).await
}

pub(crate) async fn receive_stream_with_opener(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
    buf: &mut [u8],
) -> Result<usize, StreamError> {
    let manager = state.stream_manager(peer_id).await;
    manager.receive(opener, stream_id, buf).await
}

/// Closes a byte stream locally and tells the peer.
pub(crate) async fn close_stream(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    handle: &StreamHandle,
) -> Result<(), StreamError> {
    let (opener, stream_id) = command_stream_opener(state, peer_id, handle).await?;
    close_stream_with_opener(state, peer_id, opener, stream_id).await
}

pub(crate) async fn close_stream_with_opener(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
) -> Result<(), StreamError> {
    let manager = state.stream_manager(peer_id).await;
    let opener_peer_id = stream_opener_peer_id(state, peer_id, opener).await?;
    let lease = match manager.take_lease(opener, stream_id).await {
        Ok(lease) => lease,
        Err(error) => {
            let _ = close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await;
            return Err(error);
        }
    };
    let result = match lease.profile().transport() {
        RouteTransport::Quic => {
            if !lease.is_active() {
                Err(StreamError::Closed)
            } else {
                manager.quic_finish_send(opener, stream_id).await
            }
        }
        _ => {
            async {
                let payload = encode_stream_close_frame(&opener_peer_id, stream_id)?;
                send_business_frame(
                    state,
                    peer_id,
                    &lease,
                    &stream_relay_token(&opener_peer_id, stream_id),
                    GenericFrameKind::StreamClose,
                    &payload,
                )
                .await
                .map_err(|error| StreamError::Send(error.to_string()))?;
                Ok(())
            }
            .await
        }
    };
    if !lease.is_active() || result.is_err() {
        drop(lease);
        return Err(close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await);
    }
    // A graceful local close keeps the reservation if the receive half is
    // still draining; the final remote close drops it.
    manager.close_local(peer_id, opener, stream_id).await?;
    let _ = manager.restore_lease(opener, stream_id, lease).await;
    Ok(())
}
