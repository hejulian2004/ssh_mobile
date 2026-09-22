use super::*;

/// 分派一条数据面信封。
pub(crate) async fn handle_relay_data_payload(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
    peer_id: &str,
    envelope: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let Some((&kind, body)) = envelope.split_first() else {
        return Err(std::io::Error::other("relay data envelope is empty").into());
    };
    if kind != DATA_ENV_CRYPTO && !state.relay.relay_path_ready.read().await.contains(peer_id) {
        return Err(std::io::Error::other(
            "Relay Session admission is not complete; business envelope rejected",
        )
        .into());
    }
    match kind {
        DATA_ENV_CRYPTO => {
            // body = [token 32][step+payload]
            if body.len() < 32 {
                return Err(std::io::Error::other("relay crypto envelope is truncated").into());
            }
            let token = std::str::from_utf8(&body[..32])?.to_string();
            handle_relay_crypto_handshake(state, data, &token, peer_id, &body[32..]).await
        }
        DATA_ENV_FILE_OFFER => receive_relay_offer(state, data, peer_id, body).await,
        DATA_ENV_FILE_ACCEPT => {
            let payload = std::str::from_utf8(body)?;
            let acceptance = serde_json::from_str::<RelayAcceptance>(payload)?;
            // 发送方按 transfer_id 等待 accept 应答。
            if let Some(sender) = state
                .relay
                .acceptances
                .write()
                .await
                .remove(&acceptance.transfer_id)
            {
                let _ = sender.send(Some(acceptance));
            }
            Ok(())
        }
        DATA_ENV_FILE_COMPLETE => {
            let session_id = std::str::from_utf8(body)?;
            complete_relay_incoming(state, data, session_id, Some(peer_id)).await
        }
        DATA_ENV_FILE_COMPLETE_ACK => {
            let transfer_id = std::str::from_utf8(body)?.to_string();
            if let Some(sender) = state.relay.completions.write().await.remove(&transfer_id) {
                let _ = sender.send(true);
            }
            Ok(())
        }
        DATA_ENV_FILE_CANCEL => {
            let transfer_id = std::str::from_utf8(body)?.to_string();
            if let Some(sender) = state.relay.acceptances.write().await.remove(&transfer_id) {
                let _ = sender.send(None);
            }
            if let Some(sender) = state.relay.completions.write().await.remove(&transfer_id) {
                let _ = sender.send(false);
            }
            cancel_relay_incoming(state, &transfer_id).await;
            Ok(())
        }
        DATA_ENV_FILE_CHUNK => {
            // body = [session_id 32][sequence u64 BE][ciphertext]
            if body.len() < 40 {
                return Err(std::io::Error::other("relay chunk envelope is truncated").into());
            }
            let session_id = std::str::from_utf8(&body[..32])?.to_string();
            let sequence = u64::from_be_bytes(body[32..40].try_into()?);
            receive_relay_chunk(state, data, &session_id, sequence, &body[40..]).await
        }
        DATA_ENV_CHANNEL => {
            let (token, payload) = decode_token_envelope(body)?;
            let payload = payload.to_vec();
            receive_relay_channel_message(state, data, peer_id, token, &payload).await
        }
        DATA_ENV_CHANNEL_ACK => {
            let (token, payload) = decode_token_envelope(body)?;
            let payload = payload.to_vec();
            receive_relay_delivery_ack(state, data, peer_id, token, &payload).await
        }
        DATA_ENV_STREAM => {
            let (token, payload) = decode_token_envelope(body)?;
            let payload = payload.to_vec();
            receive_relay_stream_frame(state, data, peer_id, token, &payload).await
        }
        other => {
            Err(std::io::Error::other(format!("unknown relay data envelope kind {other}")).into())
        }
    }
}
