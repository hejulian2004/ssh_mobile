use super::*;

/// 封装并发送一个数据面信封（sequence=0；文件分块单独使用真实序号）。
pub(crate) async fn send_data_envelope(
    data: &RelayDataClient,
    kind: u8,
    body: &[u8],
) -> Result<(), RelayError> {
    let mut envelope = Vec::with_capacity(1 + body.len());
    envelope.push(kind);
    envelope.extend_from_slice(body);
    data.send(0, &envelope).await
}

/// 封装并发送一个带 token 前缀的数据面信封（crypto/channel/stream 使用）。
pub(crate) async fn send_data_envelope_with_token(
    data: &RelayDataClient,
    kind: u8,
    token: &str,
    body: &[u8],
) -> Result<(), RelayError> {
    if token.len() > u8::MAX as usize {
        return Err(RelayError::InvalidConfiguration(
            "relay data envelope token is too long".into(),
        ));
    }
    let mut envelope = Vec::with_capacity(1 + 1 + token.len() + body.len());
    envelope.push(kind);
    envelope.push(token.len() as u8);
    envelope.extend_from_slice(token.as_bytes());
    envelope.extend_from_slice(body);
    data.send(0, &envelope).await
}

/// 发送一条 Relay E2EE 握手帧（加密握手不是业务数据，但复用数据面不透明转发）。
pub(crate) async fn send_relay_crypto(
    data: &RelayDataClient,
    token: &str,
    step: u8,
    payload: &[u8],
) -> Result<(), RelayError> {
    let frame = crate::crypto_handshake::encode_relay_frame(step, payload)
        .map_err(|error| RelayError::Protocol(error.to_string()))?;
    if token.len() != 32
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(RelayError::InvalidConfiguration(
            "relay crypto token must be 32 lowercase hexadecimal characters".into(),
        ));
    }
    let mut body = Vec::with_capacity(32 + frame.len());
    body.extend_from_slice(token.as_bytes());
    body.extend_from_slice(&frame);
    send_data_envelope(data, DATA_ENV_CRYPTO, &body).await
}

/// 发送一条 Relay 可靠消息（DataMessage protobuf 封装）。
pub(crate) async fn send_relay_channel_message(
    data: &RelayDataClient,
    token: &str,
    payload: &[u8],
) -> Result<(), RelayError> {
    send_data_envelope_with_token(data, DATA_ENV_CHANNEL, token, payload).await
}

/// 发送一条 Relay DeliveryAck。
pub(crate) async fn send_relay_channel_ack(
    data: &RelayDataClient,
    token: &str,
    payload: &[u8],
) -> Result<(), RelayError> {
    send_data_envelope_with_token(data, DATA_ENV_CHANNEL_ACK, token, payload).await
}

/// 发送一条 Relay byte-stream 帧（StreamOpen/StreamBytes/StreamClose）。
pub(crate) async fn send_relay_stream_frame(
    data: &RelayDataClient,
    token: &str,
    payload: &[u8],
) -> Result<(), RelayError> {
    send_data_envelope_with_token(data, DATA_ENV_STREAM, token, payload).await
}

/// 解码一个 token 前缀信封，返回 (token, body)。
pub(crate) fn decode_token_envelope(envelope: &[u8]) -> Result<(&str, &[u8]), RelayError> {
    if envelope.len() < 2 {
        return Err(RelayError::Protocol(
            "relay data envelope is truncated".into(),
        ));
    }
    let token_len = envelope[0] as usize;
    if envelope.len() < 1 + token_len {
        return Err(RelayError::Protocol(
            "relay data envelope token is truncated".into(),
        ));
    }
    let token = std::str::from_utf8(&envelope[1..1 + token_len])
        .map_err(|_| RelayError::Protocol("relay data envelope token is not UTF-8".into()))?;
    Ok((token, &envelope[1 + token_len..]))
}

/// 发送一条已编码的 crypto 帧（data 侧加 token 前缀）。
pub(crate) async fn send_relay_crypto_raw(
    data: &RelayDataClient,
    token: &str,
    encoded_frame: &[u8],
) -> Result<(), RelayError> {
    if token.len() != 32
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(RelayError::InvalidConfiguration(
            "relay crypto token must be 32 lowercase hexadecimal characters".into(),
        ));
    }
    let mut body = Vec::with_capacity(32 + encoded_frame.len());
    body.extend_from_slice(token.as_bytes());
    body.extend_from_slice(encoded_frame);
    send_data_envelope(data, DATA_ENV_CRYPTO, &body).await
}
