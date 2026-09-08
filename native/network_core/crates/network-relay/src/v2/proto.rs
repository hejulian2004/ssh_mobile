//! Relay Protocol V2 wire contract — self-contained Rust codec.
//!
//! This module mirrors the FROZEN `protocol/proto/relay/v2/relay_v2.proto`
//! (transport-network v2). Field tags and semantics below MUST NOT change:
//! the golden fixtures in `protocol/relay_v2_testdata/` and the Go codec in
//! `relay/internal/relay/v2` are locked to this file.
//!
//! Because the frozen `network-relay-proto` crate is not yet a workspace
//! member, the messages are declared here with `prost` derives and hand-wired
//! frame codecs implement the 4-byte big-endian length-prefix envelope:
//!
//!   WS Binary payload == [u32 BE length][protobuf RelayFrame]
//!                      == [u32 BE length][protobuf RelayDataFrame]
//!
//! Exactly ONE message per WS frame; length MUST equal frame.len() - 4.

use prost::Message;
use std::fmt;

use crate::RelayError;

/// Centralized v2 constants (locked to the contract header comment).
pub const RELAY_V2_VERSION: u32 = 2;
pub const FRAME_LENGTH_PREFIX_BYTES: usize = 4;
pub const MAX_RELAY_FRAME_BYTES: usize = 4 + 512 * 1024;
pub const MAX_RELAY_DATA_FRAME_BYTES: usize = 4 + 512 * 1024;
pub const MAX_DEVICE_ID_BYTES: usize = 128;
pub const MAX_ATTEMPT_ID_BYTES: usize = 128;
pub const MAX_REALTIME_ID_BYTES: usize = 128;
pub const MAX_REALTIME_SIGNAL_PAYLOAD_BYTES: usize = 256 * 1024;
pub const MAX_DISCOVERY_CANDIDATES: usize = 64;
pub const MAX_DISCOVERY_CANDIDATE_BYTES: usize = 4096;
pub const MAX_DISCOVERY_CAPABILITIES: usize = 64;
pub const RESERVATION_ID_BYTES: usize = 16;
pub const RESERVATION_ID_HEX_CHARS: usize = 32;
pub const RESERVATION_TOKEN_BYTES: usize = 32;
pub const HEARTBEAT_INTERVAL_S: u32 = 20;
pub const PRESENCE_TTL_S: u32 = 60;
pub const SERVER_HEARTBEAT_MISSES_BEFORE_CLOSE: u32 = 2;
pub const RESERVATION_LIFETIME_S_DEFAULT: u32 = 60;
pub const RESERVATION_EXPIRY_GRACE_S: u32 = 5;
pub const RESOLVE_RETRY_HINT_NOT_READY_MS: u32 = 2000;
pub const RESOLVE_RETRY_HINT_UNKNOWN_MS: u32 = 5000;
pub const DIRECT_CONNECT_WINDOW_MS: u32 = 4000;

// ---------------------------------------------------------------------------
// Enums (frozen values)
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
#[repr(i32)]
pub enum TransportCapability {
    Unspecified = 0,
    Quic = 1,
    Tcp = 2,
    UdpDatagram = 3,
    Websocket = 4,
    Webrtc = 5,
    RelayData = 6,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
#[repr(i32)]
pub enum ResolveStatus {
    Unspecified = 0,
    Ready = 1,
    Offline = 2,
    NotReady = 3,
    Unknown = 4,
}

impl ResolveStatus {
    /// Returns `true` when the resolved peer can be connected now.
    pub fn is_ready(self) -> bool {
        matches!(self, ResolveStatus::Ready)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
#[repr(i32)]
pub enum RealtimeSignalKind {
    Unspecified = 0,
    Offer = 1,
    Answer = 2,
    IceCandidate = 3,
    IceRestart = 4,
    Close = 5,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
#[repr(i32)]
pub enum ErrorCode {
    Unspecified = 0,
    ControlUnavailable = 1,
    AuthenticationFailed = 2,
    PeerOffline = 3,
    PeerNotReady = 4,
    ResolveTimeout = 5,
    Protocol = 6,
    EpochConflict = 7,
    RevisionStale = 8,
    ReservationFailed = 9,
    ReservationExpired = 10,
    RelayUnavailable = 11,
    RateLimited = 12,
    MalformedFrame = 13,
    FrameTooLarge = 14,
}

// ---------------------------------------------------------------------------
// Common messages
// ---------------------------------------------------------------------------

/// 128-bit random runtime identity, big-endian (high, low).
#[derive(Clone, PartialEq, Eq, Message)]
pub struct RuntimeEpoch {
    #[prost(fixed64, tag = "1")]
    pub high: u64,
    #[prost(fixed64, tag = "2")]
    pub low: u64,
}

/// Opaque native-encoded candidate blobs; the relay NEVER parses them.
#[derive(Clone, PartialEq, Eq, Message)]
pub struct CandidateBundle {
    #[prost(bytes = "vec", repeated, tag = "1")]
    pub candidates: Vec<Vec<u8>>,
}

/// A peer's published discovery.
#[derive(Clone, PartialEq, Eq, Message)]
pub struct DiscoverySnapshot {
    #[prost(message, optional, tag = "1")]
    pub runtime_epoch: Option<RuntimeEpoch>,
    #[prost(uint32, tag = "2")]
    pub revision: u32,
    #[prost(enumeration = "TransportCapability", repeated, tag = "3")]
    pub transport_capabilities: Vec<i32>,
    #[prost(message, optional, tag = "4")]
    pub candidate_bundle: Option<CandidateBundle>,
    #[prost(int64, tag = "5")]
    pub published_at_ms: i64,
}

// ---------------------------------------------------------------------------
// Control messages (ONLY on /v2/control)
// ---------------------------------------------------------------------------

#[derive(Clone, PartialEq, Eq, Message)]
pub struct Ready {
    #[prost(uint32, tag = "1")]
    pub protocol_version: u32,
    #[prost(string, tag = "2")]
    pub device_id: String,
    #[prost(int64, tag = "3")]
    pub server_time_ms: i64,
    #[prost(uint32, tag = "4")]
    pub heartbeat_interval_s: u32,
    #[prost(uint32, tag = "5")]
    pub presence_ttl_s: u32,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct Heartbeat {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(int64, tag = "2")]
    pub sent_at_ms: i64,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct HeartbeatAck {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(int64, tag = "2")]
    pub server_time_ms: i64,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct DiscoveryPublish {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(message, optional, tag = "2")]
    pub snapshot: Option<DiscoverySnapshot>,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct DiscoveryAck {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(message, optional, tag = "2")]
    pub runtime_epoch: Option<RuntimeEpoch>,
    #[prost(uint32, tag = "3")]
    pub revision: u32,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct ResolvePeerRequest {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(string, tag = "2")]
    pub target_device_id: String,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct ResolvePeerResponse {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(enumeration = "ResolveStatus", tag = "2")]
    pub status: i32,
    #[prost(message, optional, tag = "3")]
    pub discovery: Option<DiscoverySnapshot>,
    #[prost(uint32, tag = "4")]
    pub retry_after_ms: u32,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct ConnectivityOffer {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(string, tag = "2")]
    pub attempt_id: String,
    #[prost(string, tag = "3")]
    pub initiator_device_id: String,
    #[prost(message, optional, tag = "4")]
    pub initiator_runtime_epoch: Option<RuntimeEpoch>,
    #[prost(uint32, tag = "5")]
    pub initiator_revision: u32,
    #[prost(message, optional, tag = "6")]
    pub initiator_snapshot: Option<DiscoverySnapshot>,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct ConnectivityAnswer {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(string, tag = "2")]
    pub attempt_id: String,
    #[prost(bool, tag = "3")]
    pub accepted: bool,
    #[prost(string, tag = "4")]
    pub responder_device_id: String,
    #[prost(message, optional, tag = "5")]
    pub responder_runtime_epoch: Option<RuntimeEpoch>,
    #[prost(uint32, tag = "6")]
    pub responder_revision: u32,
    #[prost(message, optional, tag = "7")]
    pub responder_snapshot: Option<DiscoverySnapshot>,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct PresenceHintSnapshot {
    #[prost(message, repeated, tag = "1")]
    pub peers: Vec<PeerPresenceHint>,
    #[prost(int64, tag = "2")]
    pub published_at_ms: i64,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct PeerPresenceHint {
    #[prost(string, tag = "1")]
    pub device_id: String,
    #[prost(bool, tag = "2")]
    pub online: bool,
    #[prost(message, optional, tag = "3")]
    pub runtime_epoch: Option<RuntimeEpoch>,
    #[prost(uint32, tag = "4")]
    pub revision: u32,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct PeerAvailableHint {
    #[prost(string, tag = "1")]
    pub device_id: String,
    #[prost(message, optional, tag = "2")]
    pub runtime_epoch: Option<RuntimeEpoch>,
    #[prost(uint32, tag = "3")]
    pub revision: u32,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct PeerUnavailableHint {
    #[prost(string, tag = "1")]
    pub device_id: String,
    #[prost(string, tag = "2")]
    pub reason: String,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct RelayReserveRequest {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(string, tag = "2")]
    pub attempt_id: String,
    #[prost(string, tag = "3")]
    pub target_device_id: String,
    #[prost(uint32, tag = "4")]
    pub desired_lifetime_s: u32,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct RelayReserveResponse {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(string, tag = "2")]
    pub attempt_id: String,
    #[prost(string, tag = "3")]
    pub reservation_id: String,
    #[prost(string, tag = "4")]
    pub relay_data_endpoint: String,
    #[prost(int64, tag = "5")]
    pub expires_at_ms: i64,
    #[prost(bytes = "vec", tag = "6")]
    pub local_token: Vec<u8>,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct IncomingRelayReservation {
    #[prost(string, tag = "1")]
    pub attempt_id: String,
    #[prost(string, tag = "2")]
    pub reservation_id: String,
    #[prost(string, tag = "3")]
    pub initiator_device_id: String,
    #[prost(string, tag = "4")]
    pub relay_data_endpoint: String,
    #[prost(int64, tag = "5")]
    pub expires_at_ms: i64,
    #[prost(bytes = "vec", tag = "6")]
    pub local_token: Vec<u8>,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct RealtimeSignal {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(string, tag = "2")]
    pub realtime_id: String,
    #[prost(string, tag = "3")]
    pub target_device_id: String,
    #[prost(enumeration = "RealtimeSignalKind", tag = "4")]
    pub kind: i32,
    #[prost(uint64, tag = "5")]
    pub revision: u64,
    #[prost(bytes = "vec", tag = "6")]
    pub payload: Vec<u8>,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct ProtocolError {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(string, tag = "2")]
    pub attempt_id: String,
    #[prost(enumeration = "ErrorCode", tag = "3")]
    pub code: i32,
    #[prost(string, tag = "4")]
    pub message: String,
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "relay v2 protocol error (code {}{}): {}",
            self.code,
            if self.attempt_id.is_empty() {
                String::new()
            } else {
                format!(", attempt {}", self.attempt_id)
            },
            self.message
        )
    }
}

// ---------------------------------------------------------------------------
// Envelope: control
// ---------------------------------------------------------------------------

#[derive(Clone, PartialEq, Eq, Message)]
pub struct RelayFrame {
    #[prost(uint32, tag = "1")]
    pub version: u32,
    #[prost(
        oneof = "relay_frame::Kind",
        tags = "10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26"
    )]
    pub kind: Option<relay_frame::Kind>,
}

pub mod relay_frame {
    use super::*;

    #[derive(Clone, PartialEq, Eq, prost::Oneof)]
    pub enum Kind {
        #[prost(message, tag = "10")]
        Ready(Ready),
        #[prost(message, tag = "11")]
        Heartbeat(Heartbeat),
        #[prost(message, tag = "12")]
        HeartbeatAck(HeartbeatAck),
        #[prost(message, tag = "13")]
        DiscoveryPublish(DiscoveryPublish),
        #[prost(message, tag = "14")]
        DiscoveryAck(DiscoveryAck),
        #[prost(message, tag = "15")]
        ResolvePeerRequest(ResolvePeerRequest),
        #[prost(message, tag = "16")]
        ResolvePeerResponse(ResolvePeerResponse),
        #[prost(message, tag = "17")]
        ConnectivityOffer(ConnectivityOffer),
        #[prost(message, tag = "18")]
        ConnectivityAnswer(ConnectivityAnswer),
        #[prost(message, tag = "19")]
        PresenceHintSnapshot(PresenceHintSnapshot),
        #[prost(message, tag = "20")]
        PeerAvailableHint(PeerAvailableHint),
        #[prost(message, tag = "21")]
        PeerUnavailableHint(PeerUnavailableHint),
        #[prost(message, tag = "22")]
        RelayReserveRequest(RelayReserveRequest),
        #[prost(message, tag = "23")]
        RelayReserveResponse(RelayReserveResponse),
        #[prost(message, tag = "24")]
        IncomingRelayReservation(IncomingRelayReservation),
        #[prost(message, tag = "25")]
        RealtimeSignal(RealtimeSignal),
        #[prost(message, tag = "26")]
        ProtocolError(ProtocolError),
    }
}

// ---------------------------------------------------------------------------
// Relay-data messages (ONLY on /v2/relay/{reservation_id})
// ---------------------------------------------------------------------------

#[derive(Clone, PartialEq, Eq, Message)]
pub struct RelayDataFrame {
    #[prost(uint32, tag = "1")]
    pub version: u32,
    #[prost(oneof = "relay_data_frame::Kind", tags = "10, 11, 12, 13")]
    pub kind: Option<relay_data_frame::Kind>,
}

pub mod relay_data_frame {
    use super::*;

    #[derive(Clone, PartialEq, Eq, prost::Oneof)]
    pub enum Kind {
        #[prost(message, tag = "10")]
        Connect(RelayDataConnect),
        #[prost(message, tag = "11")]
        Payload(RelayDataPayload),
        #[prost(message, tag = "12")]
        Ack(RelayDataAck),
        #[prost(message, tag = "13")]
        Close(RelayDataClose),
    }
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct RelayDataConnect {
    #[prost(string, tag = "1")]
    pub reservation_id: String,
    #[prost(bytes = "vec", tag = "2")]
    pub local_token: Vec<u8>,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct RelayDataPayload {
    #[prost(uint64, tag = "1")]
    pub sequence: u64,
    #[prost(bytes = "vec", tag = "2")]
    pub encrypted_payload: Vec<u8>,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct RelayDataAck {
    #[prost(uint64, tag = "1")]
    pub sequence: u64,
}

#[derive(Clone, PartialEq, Eq, Message)]
pub struct RelayDataClose {
    #[prost(uint32, tag = "1")]
    pub reason: u32,
    #[prost(string, tag = "2")]
    pub detail: String,
}

// ---------------------------------------------------------------------------
// Frame codecs: [u32 BE length][protobuf]
// ---------------------------------------------------------------------------

/// Encodes a control frame with the 4-byte big-endian length prefix.
pub fn encode_control_frame(frame: &RelayFrame) -> Result<Vec<u8>, RelayError> {
    if frame.version != RELAY_V2_VERSION {
        return Err(RelayError::Protocol(format!(
            "unsupported Relay v2 frame version {}",
            frame.version
        )));
    }
    encode_frame(frame, MAX_RELAY_FRAME_BYTES)
}

/// Decodes and validates a control frame (length prefix + version check).
pub fn decode_control_frame(bytes: &[u8]) -> Result<RelayFrame, RelayError> {
    decode_frame(bytes, MAX_RELAY_FRAME_BYTES)
}

/// Encodes a relay-data frame with the 4-byte big-endian length prefix.
pub fn encode_data_frame(frame: &RelayDataFrame) -> Result<Vec<u8>, RelayError> {
    if frame.version != RELAY_V2_VERSION {
        return Err(RelayError::Protocol(format!(
            "unsupported Relay v2 data frame version {}",
            frame.version
        )));
    }
    encode_frame(frame, MAX_RELAY_DATA_FRAME_BYTES)
}

/// Decodes and validates a relay-data frame (length prefix + version check).
pub fn decode_data_frame(bytes: &[u8]) -> Result<RelayDataFrame, RelayError> {
    decode_frame(bytes, MAX_RELAY_DATA_FRAME_BYTES)
}

fn encode_frame<M: Message>(frame: &M, max_bytes: usize) -> Result<Vec<u8>, RelayError> {
    let mut payload = Vec::with_capacity(64);
    frame
        .encode(&mut payload)
        .map_err(|error| RelayError::Protocol(format!("v2 frame encode failed: {error}")))?;
    let total = FRAME_LENGTH_PREFIX_BYTES + payload.len();
    if total > max_bytes {
        return Err(RelayError::InvalidConfiguration(format!(
            "v2 frame is too large: {total} bytes exceeds {max_bytes}"
        )));
    }
    let mut out = Vec::with_capacity(total);
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(&payload);
    Ok(out)
}

fn decode_frame<M: Message + Default>(bytes: &[u8], max_bytes: usize) -> Result<M, RelayError> {
    if bytes.len() > max_bytes {
        return Err(RelayError::Protocol(format!(
            "v2 frame is too large: {} bytes exceeds {max_bytes}",
            bytes.len()
        )));
    }
    if bytes.len() < FRAME_LENGTH_PREFIX_BYTES {
        return Err(RelayError::Protocol(
            "v2 frame is shorter than its length prefix".into(),
        ));
    }
    let length = u32::from_be_bytes(
        bytes[..FRAME_LENGTH_PREFIX_BYTES]
            .try_into()
            .map_err(|_| RelayError::Protocol("v2 frame length prefix is invalid".into()))?,
    ) as usize;
    if length != bytes.len() - FRAME_LENGTH_PREFIX_BYTES {
        return Err(RelayError::Protocol(format!(
            "v2 frame length prefix {length} does not match payload {}",
            bytes.len() - FRAME_LENGTH_PREFIX_BYTES
        )));
    }
    let frame = M::decode(&bytes[FRAME_LENGTH_PREFIX_BYTES..])
        .map_err(|error| RelayError::Protocol(format!("v2 frame decode failed: {error}")))?;
    Ok(frame)
}

/// Returns the request_id carried by a client-bound RelayFrame, if any.
pub(crate) fn frame_request_id(frame: &RelayFrame) -> Option<u64> {
    let kind = frame.kind.as_ref()?;
    match kind {
        relay_frame::Kind::Heartbeat(message) => Some(message.request_id),
        relay_frame::Kind::HeartbeatAck(message) => Some(message.request_id),
        relay_frame::Kind::DiscoveryPublish(message) => Some(message.request_id),
        relay_frame::Kind::DiscoveryAck(message) => Some(message.request_id),
        relay_frame::Kind::ResolvePeerRequest(message) => Some(message.request_id),
        relay_frame::Kind::ResolvePeerResponse(message) => Some(message.request_id),
        relay_frame::Kind::ConnectivityOffer(message) => Some(message.request_id),
        relay_frame::Kind::ConnectivityAnswer(message) => Some(message.request_id),
        relay_frame::Kind::RelayReserveRequest(message) => Some(message.request_id),
        relay_frame::Kind::RelayReserveResponse(message) => Some(message.request_id),
        relay_frame::Kind::RealtimeSignal(message) => Some(message.request_id),
        relay_frame::Kind::ProtocolError(message) if message.request_id != 0 => {
            Some(message.request_id)
        }
        _ => None,
    }
}
