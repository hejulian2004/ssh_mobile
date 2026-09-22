use super::*;

/// Relay 只转发不透明 DataMessage；业务解码仍在 native core。
pub(crate) async fn receive_relay_channel_message(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
    peer_id: &str,
    session_token: &str,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !state.peers.read().await.contains_key(peer_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay channel sender is not a registered peer",
        )
        .into());
    }
    // ReliableStream frames ride the same Relay data channel (design §17 Relay
    // Stream): transparent forwarding, the Relay never parses business bytes.
    if let Ok(frame) = decode_generic_frame(payload) {
        match frame.kind {
            GenericFrameKind::StreamOpen
            | GenericFrameKind::StreamBytes
            | GenericFrameKind::StreamClose => {
                if !state.peers.read().await.contains_key(peer_id) {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::PermissionDenied,
                        "Relay channel sender is not a registered peer",
                    )
                    .into());
                }
                let (opener_peer_id, stream_id) =
                    crate::stream::decode_stream_frame_identity(frame.kind, &frame.payload)
                        .map_err(|error| {
                            std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string())
                        })?;
                let expected_token = crate::stream::stream_relay_token(&opener_peer_id, stream_id);
                if session_token != expected_token {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "Relay stream token does not match stream opener and id",
                    )
                    .into());
                }
                crate::stream::handle_inbound_stream_frame(
                    state,
                    peer_id,
                    frame.kind,
                    &frame.payload,
                    crate::stream::InboundPath::Relay(Arc::clone(data)),
                )
                .await?;
                return Ok(());
            }
            _ => {}
        }
    }
    let message = DataMessage::decode(payload)?;
    if hex::encode(&message.message_id) != session_token {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay channel token does not match MessageId",
        )
        .into());
    }
    crate::channel::handle_data_message(state, peer_id, payload).await
}

/// 专门处理 Relay byte-stream 帧（`DATA_ENV_STREAM`）。
pub(crate) async fn receive_relay_stream_frame(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
    peer_id: &str,
    session_token: &str,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !state.peers.read().await.contains_key(peer_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay channel sender is not a registered peer",
        )
        .into());
    }
    let frame = decode_generic_frame(payload)?;
    if !matches!(
        frame.kind,
        GenericFrameKind::StreamOpen
            | GenericFrameKind::StreamBytes
            | GenericFrameKind::StreamClose
    ) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay stream envelope must carry a stream frame",
        )
        .into());
    }
    let (opener_peer_id, stream_id) =
        crate::stream::decode_stream_frame_identity(frame.kind, &frame.payload).map_err(
            |error| std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string()),
        )?;
    let expected_token = crate::stream::stream_relay_token(&opener_peer_id, stream_id);
    if session_token != expected_token {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay stream token does not match stream opener and id",
        )
        .into());
    }
    crate::stream::handle_inbound_stream_frame(
        state,
        peer_id,
        frame.kind,
        &frame.payload,
        crate::stream::InboundPath::Relay(Arc::clone(data)),
    )
    .await
    .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string()))?;
    Ok(())
}

pub(crate) async fn receive_relay_delivery_ack(
    state: &Arc<RuntimeState>,
    _data: &Arc<RelayDataClient>,
    peer_id: &str,
    session_token: &str,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !state.peers.read().await.contains_key(peer_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay channel sender is not a registered peer",
        )
        .into());
    }
    let ack = DeliveryAck::decode(payload)?;
    if hex::encode(&ack.message_id) != session_token {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay ACK token does not match MessageId",
        )
        .into());
    }
    crate::channel::handle_delivery_ack(state, peer_id, payload).await
}
