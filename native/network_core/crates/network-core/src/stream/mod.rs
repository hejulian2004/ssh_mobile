//! ReliableStream byte-stream carrier (design §17 ReliableStream / §21 SSH).
//!
//! A ConnectionSession carries multiple logical byte streams multiplexed over
//! one framed carrier:
//! - Generic routes (TCP / Relay): `StreamOpen`/`StreamBytes`/`StreamClose`
//!   frames (`connection.rs` `GenericFrameKind`).
//! - QUIC direct: one real bidirectional QUIC stream per logical stream, so
//!   SSH bytes ride on a genuine QUIC stream without re-framing.
//!
//! The peer that receives a stream whose service hint is `ssh` bridges the
//! stream bytes to a local TCP sshd socket (option B of the SSH design): a
//! native gateway task pumps bytes between the native stream and the local
//! socket. There is zero SSH protocol code in the native runtime.
//!
//! Backpressure: the generic writer already blocks on the bounded route
//! channel (`GENERIC_ROUTE_CHANNEL_CAPACITY`); a stream send therefore awaits
//! the bounded native send and never drops. The receive path buffers per
//! stream (bounded at `MAX_PER_STREAM_BUFFER_CAPACITY`) and blocks the writer
//! while a consumer drains, for every consumer mode: Bridge/Poll consumers
//! drain through `receive_stream`, and Event-mode streams drain through a
//! per-stream emitter task that turns the buffered bytes into
//! `SshStreamDataReceived` events. An SSH burst therefore cannot grow memory
//! without bound or be silently discarded.

#[cfg(test)]
use network_protocol::{network_event, NetworkEvent};
#[cfg(test)]
use network_protocol::{
    CommunicationClass, SshStreamCloseCommand, SshStreamDataCommand, SshStreamOpenCommand,
    StreamHandle,
};
use network_protocol::{NetworkError as ProtocolError, NetworkErrorCode};
#[cfg(test)]
use std::sync::Arc;

#[cfg(test)]
use crate::connect::CAPABILITY_RELIABLE_STREAM;
#[cfg(test)]
use crate::connection::GenericFrameKind;
use crate::events::protocol_error_with_peer;
#[cfg(test)]
use crate::runtime::RuntimeState;

// ---------------------------------------------------------------------------
// Centralized constants (design §39: no magic numbers)
// ---------------------------------------------------------------------------

/// Service hint for the SSH gateway (design §21 option B: bridge to sshd).
pub(crate) const STREAM_SERVICE_SSH: &str = "ssh";
/// Local host the SSH gateway connects to.
pub(crate) const STREAM_LOCAL_HOST: &str = "127.0.0.1";
/// Local OS sshd port the SSH gateway bridges to (desktop sshd).
pub(crate) const STREAM_LOCAL_SSH_PORT: u16 = 22;
/// Maximum data bytes carried by one generic StreamBytes frame.
pub(crate) const MAX_STREAM_FRAME_BYTES: usize = 64 * 1024;
/// Per-stream receive buffer cap; the reader blocks while a consumer drains.
pub(crate) const MAX_PER_STREAM_BUFFER_CAPACITY: usize = 256 * 1024;
/// Maximum concurrent byte streams per peer.
pub(crate) const MAX_CONCURRENT_STREAMS: usize = 32;
/// Maximum service-hint length in bytes.
pub(crate) const MAX_SERVICE_BYTES: usize = 128;

/// Frozen ReliableStream identity. The opener device is part of the key so a
/// numeric stream ID can safely be reused by the two peers.
#[allow(dead_code)]
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct ReliableStreamIdentity {
    pub peer_id: String,
    pub opener_device_id: String,
    pub stream_id: u16,
}

impl ReliableStreamIdentity {
    #[allow(dead_code)]
    pub(crate) fn new(
        peer_id: impl Into<String>,
        opener_device_id: impl Into<String>,
        stream_id: u16,
    ) -> Result<Self, StreamError> {
        let identity = Self {
            peer_id: peer_id.into(),
            opener_device_id: opener_device_id.into(),
            stream_id,
        };
        if identity.peer_id.is_empty()
            || identity.opener_device_id.is_empty()
            || identity.stream_id == 0
        {
            return Err(StreamError::InvalidArgument);
        }
        Ok(identity)
    }
}

/// Chunk size for the gateway socket pump.
pub(crate) const STREAM_SOCKET_CHUNK_BYTES: usize = 16 * 1024;
/// QUIC bidi preamble magic; distinguishes reliable streams from file offers
/// (file offers use `SMFT`) on the shared `accept_bi` loop.
pub(crate) const STREAM_QUIC_PREAMBLE_MAGIC: [u8; 4] = *b"SMSS";
/// File offer magic mirrored from `network_quic::file_stream` for dispatch.
pub(crate) const FILE_OFFER_MAGIC: [u8; 4] = *b"SMFT";

// ---------------------------------------------------------------------------
// Stream errors
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub(crate) enum StreamError {
    #[error("stream is not open")]
    NotFound,
    #[error("stream is already open")]
    AlreadyOpen,
    #[error("stream is closed")]
    Closed,
    #[error("stream frame is invalid")]
    InvalidFrame,
    #[error("stream argument is invalid")]
    InvalidArgument,
    #[error("stream capacity exceeded")]
    CapacityExceeded,
    #[error("peer is not connected")]
    NotConnected,
    #[error("current route does not support byte streams")]
    #[allow(dead_code)] // retained for the public stream error taxonomy
    UnsupportedTransport,
    #[error("route send failed: {0}")]
    Send(String),
}

impl StreamError {
    fn into_protocol(self, peer_id: &str, operation: &str) -> ProtocolError {
        let code = if matches!(self, StreamError::InvalidArgument) {
            NetworkErrorCode::InvalidArgument
        } else {
            NetworkErrorCode::IoError
        };
        protocol_error_with_peer(code, self.to_string(), operation, peer_id)
    }
}

mod codec;
mod entry;
mod inbound;
mod session;
mod ssh_gateway;

#[allow(unused_imports)]
pub(crate) use codec::{
    decode_stream_bytes_frame, decode_stream_close_frame, decode_stream_frame_identity,
    decode_stream_open_frame, encode_quic_stream_preamble, encode_stream_bytes_frame,
    encode_stream_close_frame, encode_stream_open_frame, read_quic_stream_preamble_after_magic,
    stream_relay_token,
};
#[allow(unused_imports)]
pub(crate) use entry::{validate_peer, ReliableStreamManager, StreamConsumer, StreamOpener};
#[allow(unused_imports)]
pub(crate) use inbound::{
    handle_inbound_open, handle_inbound_stream_frame, handle_incoming_quic_stream,
    spawn_quic_stream_reader, InboundPath,
};
#[allow(unused_imports)]
pub(crate) use session::{
    close_stream, close_stream_after_path_loss, open_stream, receive_stream, send_stream,
};
#[allow(unused_imports)]
pub(crate) use ssh_gateway::{
    handle_ssh_stream_close, handle_ssh_stream_data, handle_ssh_stream_open, spawn_ssh_gateway,
    SshGatewayAdapter,
};

#[cfg(test)]
#[path = "../tests/stream.rs"]
mod tests;
