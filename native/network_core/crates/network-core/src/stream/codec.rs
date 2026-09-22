use tokio::io::AsyncReadExt;

use crate::connection::GenericFrameKind;

use super::{StreamError, MAX_SERVICE_BYTES, STREAM_QUIC_PREAMBLE_MAGIC};

// ---------------------------------------------------------------------------
// Wire encoders / decoders (generic-route frames and QUIC preamble)
// ---------------------------------------------------------------------------

/// Generic stream frame header: opener_len(u8) + opener bytes +
/// stream_id(u16) + the frame-specific fields.  The opener is carried on
/// every frame because bytes flow in both directions on one logical stream;
/// transport direction alone is not enough to disambiguate two peers opening
/// the same stream_id at the same time.
const STREAM_OPENER_LENGTH_BYTES: usize = 1;
const STREAM_ID_BYTES: usize = 2;
const STREAM_GENERIC_BYTES_HEADER_BYTES: usize =
    STREAM_OPENER_LENGTH_BYTES + STREAM_ID_BYTES + 8 + 4;
const STREAM_GENERIC_OPEN_HEADER_BYTES: usize = STREAM_OPENER_LENGTH_BYTES + STREAM_ID_BYTES + 2;
const STREAM_GENERIC_CLOSE_HEADER_BYTES: usize = STREAM_OPENER_LENGTH_BYTES + STREAM_ID_BYTES;

/// Owns every ReliableStream wire representation: generic-route frames, QUIC
/// preambles, and Relay stream tokens. It has no stream registry or path lease.
struct StreamFrameCodec;

impl StreamFrameCodec {
    fn append_stream_opener(out: &mut Vec<u8>, opener_peer_id: &str) -> Result<(), StreamError> {
        if opener_peer_id.is_empty() || opener_peer_id.len() > 128 {
            return Err(StreamError::InvalidArgument);
        }
        out.push(opener_peer_id.len() as u8);
        out.extend_from_slice(opener_peer_id.as_bytes());
        Ok(())
    }

    fn decode_stream_opener(payload: &[u8], cursor: &mut usize) -> Result<String, StreamError> {
        if payload.len() < *cursor + STREAM_OPENER_LENGTH_BYTES {
            return Err(StreamError::InvalidFrame);
        }
        let opener_len = payload[*cursor] as usize;
        *cursor += STREAM_OPENER_LENGTH_BYTES;
        if opener_len == 0 || opener_len > 128 || payload.len() < *cursor + opener_len {
            return Err(StreamError::InvalidFrame);
        }
        let opener = std::str::from_utf8(&payload[*cursor..*cursor + opener_len])
            .map_err(|_| StreamError::InvalidFrame)?
            .to_string();
        *cursor += opener_len;
        Ok(opener)
    }

    pub(crate) fn encode_stream_bytes_frame(
        opener_peer_id: &str,
        stream_id: u16,
        seq: u64,
        data: &[u8],
    ) -> Result<Vec<u8>, StreamError> {
        if data.is_empty() {
            return Err(StreamError::InvalidArgument);
        }
        let mut out = Vec::with_capacity(
            STREAM_GENERIC_BYTES_HEADER_BYTES + opener_peer_id.len() + data.len(),
        );
        Self::append_stream_opener(&mut out, opener_peer_id)?;
        out.extend_from_slice(&stream_id.to_be_bytes());
        out.extend_from_slice(&seq.to_be_bytes());
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        out.extend_from_slice(data);
        Ok(out)
    }

    pub(crate) fn decode_stream_bytes_frame(
        payload: &[u8],
    ) -> Result<(String, u16, u64, &[u8]), StreamError> {
        if payload.len() < STREAM_GENERIC_BYTES_HEADER_BYTES {
            return Err(StreamError::InvalidFrame);
        }
        let mut cursor = 0;
        let opener = Self::decode_stream_opener(payload, &mut cursor)?;
        if payload.len() < cursor + STREAM_ID_BYTES + 8 + 4 {
            return Err(StreamError::InvalidFrame);
        }
        let stream_id = u16::from_be_bytes(
            payload[cursor..cursor + STREAM_ID_BYTES]
                .try_into()
                .expect("stream_id bytes"),
        );
        cursor += STREAM_ID_BYTES;
        let seq = u64::from_be_bytes(payload[cursor..cursor + 8].try_into().expect("seq bytes"));
        cursor += 8;
        let len =
            u32::from_be_bytes(payload[cursor..cursor + 4].try_into().expect("len bytes")) as usize;
        cursor += 4;
        if len == 0 || cursor + len != payload.len() {
            return Err(StreamError::InvalidFrame);
        }
        Ok((opener, stream_id, seq, &payload[cursor..cursor + len]))
    }

    pub(crate) fn encode_stream_open_frame(
        opener_peer_id: &str,
        stream_id: u16,
        service: &str,
    ) -> Result<Vec<u8>, StreamError> {
        if service.is_empty() || service.len() > MAX_SERVICE_BYTES {
            return Err(StreamError::InvalidArgument);
        }
        let mut out = Vec::with_capacity(
            STREAM_GENERIC_OPEN_HEADER_BYTES + opener_peer_id.len() + service.len(),
        );
        Self::append_stream_opener(&mut out, opener_peer_id)?;
        out.extend_from_slice(&stream_id.to_be_bytes());
        out.extend_from_slice(&(service.len() as u16).to_be_bytes());
        out.extend_from_slice(service.as_bytes());
        Ok(out)
    }

    pub(crate) fn decode_stream_open_frame(
        payload: &[u8],
    ) -> Result<(String, u16, String), StreamError> {
        if payload.len() < STREAM_GENERIC_OPEN_HEADER_BYTES {
            return Err(StreamError::InvalidFrame);
        }
        let mut cursor = 0;
        let opener = Self::decode_stream_opener(payload, &mut cursor)?;
        if payload.len() < cursor + STREAM_ID_BYTES + 2 {
            return Err(StreamError::InvalidFrame);
        }
        let stream_id = u16::from_be_bytes(
            payload[cursor..cursor + STREAM_ID_BYTES]
                .try_into()
                .expect("stream_id bytes"),
        );
        cursor += STREAM_ID_BYTES;
        let service_len = u16::from_be_bytes(
            payload[cursor..cursor + 2]
                .try_into()
                .expect("service_len bytes"),
        ) as usize;
        cursor += 2;
        if service_len == 0
            || service_len > MAX_SERVICE_BYTES
            || cursor + service_len != payload.len()
        {
            return Err(StreamError::InvalidFrame);
        }
        let service = std::str::from_utf8(&payload[cursor..cursor + service_len])
            .map_err(|_| StreamError::InvalidFrame)?
            .to_string();
        Ok((opener, stream_id, service))
    }

    pub(crate) fn encode_stream_close_frame(
        opener_peer_id: &str,
        stream_id: u16,
    ) -> Result<Vec<u8>, StreamError> {
        let mut out = Vec::with_capacity(STREAM_GENERIC_CLOSE_HEADER_BYTES + opener_peer_id.len());
        Self::append_stream_opener(&mut out, opener_peer_id)?;
        out.extend_from_slice(&stream_id.to_be_bytes());
        Ok(out)
    }

    pub(crate) fn decode_stream_close_frame(payload: &[u8]) -> Result<(String, u16), StreamError> {
        if payload.len() < STREAM_GENERIC_CLOSE_HEADER_BYTES {
            return Err(StreamError::InvalidFrame);
        }
        let mut cursor = 0;
        let opener = Self::decode_stream_opener(payload, &mut cursor)?;
        if payload.len() != cursor + STREAM_ID_BYTES {
            return Err(StreamError::InvalidFrame);
        }
        let stream_id = u16::from_be_bytes(
            payload[cursor..cursor + STREAM_ID_BYTES]
                .try_into()
                .expect("close stream_id bytes"),
        );
        Ok((opener, stream_id))
    }

    /// Extracts the stable `(opener_peer_id, stream_id)` identity from any stream
    /// frame. Relay uses the same identity to validate its opaque token before
    /// dispatching the frame to the stream manager.
    pub(crate) fn decode_stream_frame_identity(
        kind: GenericFrameKind,
        payload: &[u8],
    ) -> Result<(String, u16), StreamError> {
        match kind {
            GenericFrameKind::StreamOpen => {
                let (opener, stream_id, _) = Self::decode_stream_open_frame(payload)?;
                Ok((opener, stream_id))
            }
            GenericFrameKind::StreamBytes => {
                let (opener, stream_id, _, _) = Self::decode_stream_bytes_frame(payload)?;
                Ok((opener, stream_id))
            }
            GenericFrameKind::StreamClose => Self::decode_stream_close_frame(payload),
            _ => Err(StreamError::InvalidFrame),
        }
    }

    pub(crate) fn encode_quic_stream_preamble(
        stream_id: u16,
        service: &str,
    ) -> Result<Vec<u8>, StreamError> {
        if service.is_empty() || service.len() > MAX_SERVICE_BYTES {
            return Err(StreamError::InvalidArgument);
        }
        let mut out = Vec::with_capacity(8 + service.len());
        out.extend_from_slice(&STREAM_QUIC_PREAMBLE_MAGIC);
        out.extend_from_slice(&stream_id.to_be_bytes());
        out.extend_from_slice(&(service.len() as u16).to_be_bytes());
        out.extend_from_slice(service.as_bytes());
        Ok(out)
    }

    /// Reads the remainder of a QUIC bidi preamble after the four magic bytes have
    /// already been consumed by the bidi dispatcher.
    pub(crate) async fn read_quic_stream_preamble_after_magic(
        receive: &mut quinn::RecvStream,
    ) -> Result<(u16, String), StreamError> {
        let stream_id = receive
            .read_u16()
            .await
            .map_err(|_| StreamError::InvalidFrame)?;
        let service_len = receive
            .read_u16()
            .await
            .map_err(|_| StreamError::InvalidFrame)? as usize;
        if service_len == 0 || service_len > MAX_SERVICE_BYTES {
            return Err(StreamError::InvalidFrame);
        }
        let mut service = vec![0u8; service_len];
        receive
            .read_exact(&mut service)
            .await
            .map_err(|_| StreamError::InvalidFrame)?;
        let service = String::from_utf8(service).map_err(|_| StreamError::InvalidFrame)?;
        Ok((stream_id, service))
    }

    /// Relay 路由的流令牌：稳定绑定 opener peer 与 stream_id，避免两个方向
    /// 同时使用同一逻辑 id 时共享数据面 token。
    pub(crate) fn stream_relay_token(opener_peer_id: &str, stream_id: u16) -> String {
        format!("stream:{opener_peer_id}:{stream_id}")
    }
}

pub(crate) fn encode_stream_bytes_frame(
    opener_peer_id: &str,
    stream_id: u16,
    seq: u64,
    data: &[u8],
) -> Result<Vec<u8>, StreamError> {
    StreamFrameCodec::encode_stream_bytes_frame(opener_peer_id, stream_id, seq, data)
}

pub(crate) fn decode_stream_bytes_frame(
    payload: &[u8],
) -> Result<(String, u16, u64, &[u8]), StreamError> {
    StreamFrameCodec::decode_stream_bytes_frame(payload)
}

pub(crate) fn encode_stream_open_frame(
    opener_peer_id: &str,
    stream_id: u16,
    service: &str,
) -> Result<Vec<u8>, StreamError> {
    StreamFrameCodec::encode_stream_open_frame(opener_peer_id, stream_id, service)
}

pub(crate) fn decode_stream_open_frame(
    payload: &[u8],
) -> Result<(String, u16, String), StreamError> {
    StreamFrameCodec::decode_stream_open_frame(payload)
}

pub(crate) fn encode_stream_close_frame(
    opener_peer_id: &str,
    stream_id: u16,
) -> Result<Vec<u8>, StreamError> {
    StreamFrameCodec::encode_stream_close_frame(opener_peer_id, stream_id)
}

pub(crate) fn decode_stream_close_frame(payload: &[u8]) -> Result<(String, u16), StreamError> {
    StreamFrameCodec::decode_stream_close_frame(payload)
}

pub(crate) fn decode_stream_frame_identity(
    kind: GenericFrameKind,
    payload: &[u8],
) -> Result<(String, u16), StreamError> {
    StreamFrameCodec::decode_stream_frame_identity(kind, payload)
}

pub(crate) fn encode_quic_stream_preamble(
    stream_id: u16,
    service: &str,
) -> Result<Vec<u8>, StreamError> {
    StreamFrameCodec::encode_quic_stream_preamble(stream_id, service)
}

pub(crate) async fn read_quic_stream_preamble_after_magic(
    receive: &mut quinn::RecvStream,
) -> Result<(u16, String), StreamError> {
    StreamFrameCodec::read_quic_stream_preamble_after_magic(receive).await
}

pub(crate) fn stream_relay_token(opener_peer_id: &str, stream_id: u16) -> String {
    StreamFrameCodec::stream_relay_token(opener_peer_id, stream_id)
}
