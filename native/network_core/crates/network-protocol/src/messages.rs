//! Shared Network Protocol V2 error and delivery message envelopes.

use super::*;
use prost::Message;

#[derive(Clone, PartialEq, Message)]
pub struct NetworkError {
    #[prost(enumeration = "NetworkErrorCode", tag = "1")]
    pub code: i32,
    #[prost(string, tag = "2")]
    pub message: String,
    #[prost(string, tag = "3")]
    pub operation: String,
    #[prost(string, tag = "4")]
    pub peer_id: String,
    /// 服务端建议的重试策略；默认 Unspecified 表示未指定。
    #[prost(enumeration = "RetryDisposition", tag = "5")]
    pub retry_disposition: i32,
    /// 服务端建议的 `RetryAfter` 秒数；0 表示未指定。
    #[prost(uint32, tag = "6")]
    pub retry_after_seconds: u32,
}

/// 跨 QUIC Connection 或 Relay 重传的应用消息信封。
#[derive(Clone, PartialEq, Message)]
pub struct DataMessage {
    #[prost(string, tag = "1")]
    pub session_id: String,
    #[prost(string, tag = "2")]
    pub channel_id: String,
    #[prost(bytes = "vec", tag = "3")]
    pub message_id: Vec<u8>,
    #[prost(uint64, tag = "4")]
    pub sequence: u64,
    #[prost(uint64, tag = "5")]
    pub recovery_epoch: u64,
    #[prost(enumeration = "DeliveryPolicyCode", tag = "6")]
    pub policy: i32,
    #[prost(bytes = "vec", tag = "7")]
    pub payload: Vec<u8>,
}

/// 不携带业务正文的应用层 Delivery ACK。
#[derive(Clone, PartialEq, Message)]
pub struct DeliveryAck {
    #[prost(string, tag = "1")]
    pub session_id: String,
    #[prost(bytes = "vec", tag = "2")]
    pub message_id: Vec<u8>,
    #[prost(uint64, tag = "3")]
    pub recovery_epoch: u64,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkErrorEnvelope {
    #[prost(message, optional, tag = "1")]
    pub error: Option<NetworkError>,
}

/// Current screen-share consent metadata carried by the dedicated realtime
/// consent signal. This message never contains media, SDP, ICE or secrets.
#[derive(Clone, PartialEq, Message)]
pub struct ScreenShareConsentV2 {
    #[prost(uint32, tag = "1")]
    pub schema_version: u32,
    #[prost(string, tag = "2")]
    pub operation_id: String,
    #[prost(string, tag = "3")]
    pub realtime_id: String,
    #[prost(uint64, tag = "4")]
    pub issued_at_ms: u64,
    #[prost(uint64, tag = "5")]
    pub expires_at_ms: u64,
    #[prost(enumeration = "ScreenShareConsentDecision", tag = "6")]
    pub decision: i32,
    #[prost(string, tag = "7")]
    pub sender_peer_id: String,
    #[prost(enumeration = "ScreenShareConsentPurpose", tag = "8")]
    pub purpose: i32,
    #[prost(enumeration = "ScreenShareMediaKind", tag = "9")]
    pub media: i32,
    #[prost(bool, tag = "10")]
    pub requires_acceptance: bool,
    #[prost(uint64, tag = "11")]
    pub action_revision: u64,
}
