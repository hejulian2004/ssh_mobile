//! Network Protocol V2 event messages and their oneof envelope.

use super::*;
use prost::{Enumeration, Message};

#[derive(Clone, PartialEq, Message)]
pub struct PeerStateChangedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(enumeration = "PeerConnectionState", tag = "2")]
    pub state: i32,
    #[prost(enumeration = "RouteType", tag = "3")]
    /// Route metadata at the time of the Peer event; this is observational
    /// and never a global connectivity authority.
    pub route_type: i32,
    #[prost(message, optional, tag = "4")]
    pub error: Option<NetworkError>,
    #[prost(enumeration = "RouteTopology", tag = "5")]
    pub route_topology: i32,
    #[prost(enumeration = "RouteTransport", tag = "6")]
    pub route_transport: i32,
}

#[derive(Clone, PartialEq, Message)]
pub struct TransferProgressEvent {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(uint64, tag = "2")]
    pub bytes_transferred: u64,
    #[prost(uint64, tag = "3")]
    pub total_bytes: u64,
    /// Peer scope is mandatory for V2 business consumers. Empty is retained
    /// only for legacy relay progress producers during the cutover.
    #[prost(string, tag = "4")]
    pub peer_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct CommandResultEvent {
    #[prost(string, tag = "1")]
    pub command_id: String,
    #[prost(bool, tag = "2")]
    pub accepted: bool,
    #[prost(message, optional, tag = "3")]
    pub error: Option<NetworkError>,
}

#[derive(Clone, PartialEq, Message)]
pub struct CommandResult {
    #[prost(string, tag = "1")]
    pub command_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(enumeration = "CommandResultState", tag = "3")]
    pub state: i32,
    #[prost(message, optional, tag = "4")]
    pub error: Option<NetworkError>,
}

#[derive(Clone, PartialEq, Message)]
pub struct PeerLifecycleEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(enumeration = "PeerState", tag = "2")]
    pub state: i32,
    #[prost(enumeration = "E2eePolicy", tag = "3")]
    pub e2ee_policy: i32,
    #[prost(message, optional, tag = "4")]
    pub error: Option<NetworkError>,
}

#[derive(Clone, PartialEq, Message)]
pub struct PeerDiagnostics {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(enumeration = "PeerState", tag = "2")]
    pub state: i32,
    #[prost(enumeration = "E2eePolicy", tag = "3")]
    pub e2ee_policy: i32,
    #[prost(uint32, tag = "4")]
    pub ready_path_count: u32,
    #[prost(uint32, tag = "5")]
    pub queued_command_count: u32,
    #[prost(uint32, tag = "6")]
    pub active_stream_count: u32,
    #[prost(uint32, tag = "7")]
    pub active_transfer_count: u32,
    #[prost(message, optional, tag = "8")]
    pub last_error: Option<NetworkError>,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkEnvironmentChangedEvent {
    #[prost(uint64, tag = "1")]
    pub generation: u64,
    #[prost(bool, tag = "2")]
    pub has_connectivity: bool,
    #[prost(bool, tag = "3")]
    pub is_foreground: bool,
    #[prost(bool, tag = "4")]
    pub is_metered: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct PeerTransferProgressEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub transfer_id: String,
    #[prost(uint64, tag = "3")]
    pub confirmed_offset: u64,
    #[prost(uint64, tag = "4")]
    pub total_bytes: u64,
    #[prost(bool, tag = "5")]
    pub paused: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct IncomingTransferOfferEvent {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(string, tag = "3")]
    pub file_name: String,
    #[prost(uint64, tag = "4")]
    pub file_size: u64,
    /// Optional route metadata carried by the Network Protocol V2 event.
    #[prost(enumeration = "RouteType", optional, tag = "5")]
    pub route_type: Option<i32>,
}

#[derive(Clone, PartialEq, Message)]
pub struct TransferCompletedEvent {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(string, tag = "2")]
    pub local_path: String,
    #[prost(string, tag = "3")]
    pub peer_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct TransferFailedEvent {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(message, optional, tag = "2")]
    pub error: Option<NetworkError>,
    #[prost(string, tag = "3")]
    pub peer_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct RouteChangedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(enumeration = "RouteType", tag = "2")]
    pub route_type: i32,
    #[prost(string, tag = "3")]
    pub endpoint: String,
    #[prost(uint64, tag = "4")]
    pub rtt_ms: u64,
    #[prost(uint32, tag = "5")]
    pub loss_per_mille: u32,
    #[prost(enumeration = "RouteTopology", tag = "6")]
    pub topology: i32,
    #[prost(enumeration = "RouteTransport", tag = "7")]
    pub transport: i32,
}

#[derive(Clone, PartialEq, Message)]
pub struct RouteAttemptChangedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub attempt_id: String,
    #[prost(enumeration = "RouteAttemptPhase", tag = "3")]
    pub phase: i32,
    #[prost(enumeration = "RouteType", tag = "4")]
    pub route_type: i32,
    #[prost(message, optional, tag = "5")]
    pub error: Option<NetworkError>,
    #[prost(string, tag = "6")]
    pub command_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct RelayStateChangedEvent {
    #[prost(enumeration = "RelayConnectionState", tag = "1")]
    pub state: i32,
    #[prost(message, optional, tag = "2")]
    pub error: Option<NetworkError>,
}

/// Relay Presence 控制面推送给客户端的对端在线状态。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum PeerPresenceState {
    Unspecified = 0,
    Online = 1,
    Updated = 2,
    Offline = 3,
}

/// 单个对端的 Presence 变化。
#[derive(Clone, PartialEq, Message)]
pub struct PeerPresenceChangedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(uint64, tag = "2")]
    pub generation: u64,
    #[prost(enumeration = "PeerPresenceState", tag = "3")]
    pub state: i32,
}

/// Relay 认证连接后推送的完整在线设备快照。
#[derive(Clone, PartialEq, Message)]
pub struct PeerPresenceSnapshotEvent {
    #[prost(message, repeated, tag = "1")]
    pub peers: Vec<PeerPresenceChangedEvent>,
}

#[derive(Clone, PartialEq, Message)]
pub struct RealtimeStateChangedEvent {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(enumeration = "RealtimeSessionState", tag = "3")]
    pub state: i32,
    #[prost(uint64, tag = "4")]
    pub revision: u64,
    #[prost(message, optional, tag = "5")]
    pub error: Option<NetworkError>,
    #[prost(uint64, tag = "6")]
    pub generation: u64,
    #[prost(string, tag = "7")]
    pub shared_session_instance_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct RealtimeSignalEvent {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(enumeration = "RealtimeSignalKind", tag = "3")]
    pub kind: i32,
    #[prost(uint64, tag = "4")]
    pub revision: u64,
    #[prost(bytes = "vec", tag = "5")]
    pub payload: Vec<u8>,
}

/// Realtime Session 稳定后发布的完整状态快照；携带当前 revision、native
/// generation 与最近错误。
#[derive(Clone, PartialEq, Message)]
pub struct RealtimeSnapshotEvent {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(enumeration = "RealtimeSessionState", tag = "3")]
    pub state: i32,
    #[prost(uint64, tag = "4")]
    pub revision: u64,
    #[prost(message, optional, tag = "5")]
    pub error: Option<NetworkError>,
    #[prost(uint64, tag = "6")]
    pub generation: u64,
    #[prost(string, tag = "7")]
    pub shared_session_instance_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct RealtimeIncomingSessionOfferEvent {
    #[prost(string, tag = "1")]
    pub offer_id: String,
    #[prost(string, tag = "2")]
    pub claim_token: String,
    #[prost(string, tag = "3")]
    pub realtime_id: String,
    #[prost(string, tag = "4")]
    pub authenticated_peer_id: String,
    #[prost(string, tag = "5")]
    pub shared_session_instance_id: String,
    #[prost(uint64, tag = "6")]
    pub binding_expires_at_ms: u64,
    #[prost(bytes = "vec", tag = "7")]
    pub request: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub struct ChannelMessageEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub session_id: String,
    #[prost(string, tag = "3")]
    pub channel_id: String,
    #[prost(bytes = "vec", tag = "4")]
    pub message_id: Vec<u8>,
    #[prost(uint64, tag = "5")]
    pub sequence: u64,
    #[prost(enumeration = "DeliveryPolicyCode", tag = "6")]
    pub policy: i32,
    #[prost(bytes = "vec", tag = "7")]
    pub payload: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub struct DeliveryAckedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub session_id: String,
    #[prost(bytes = "vec", tag = "3")]
    pub message_id: Vec<u8>,
    #[prost(uint64, tag = "4")]
    pub recovery_epoch: u64,
}

/// ReliableStream 收到对端字节后发布的事件（设计 §17）。字节是不透明负载。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamDataReceivedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(message, optional, tag = "2")]
    pub handle: Option<StreamHandle>,
    #[prost(bytes = "vec", tag = "3")]
    pub data: Vec<u8>,
}

/// ReliableStream 关闭事件（本端 close_stream / 对端 StreamClose / transport 丢失）。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamClosedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(message, optional, tag = "2")]
    pub handle: Option<StreamHandle>,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkEvent {
    #[prost(string, tag = "1")]
    pub event_id: String,
    #[prost(int64, tag = "2")]
    pub timestamp_ms: i64,
    #[prost(uint32, tag = "3")]
    pub protocol_version: u32,
    #[prost(
        oneof = "network_event::Payload",
        tags = "10, 11, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33"
    )]
    pub payload: Option<network_event::Payload>,
}

pub mod network_event {
    use super::*;

    #[derive(Clone, PartialEq, prost::Oneof)]
    pub enum Payload {
        #[prost(message, tag = "10")]
        PeerState(PeerStateChangedEvent),
        #[prost(message, tag = "11")]
        TransferProgress(TransferProgressEvent),
        #[prost(message, tag = "13")]
        CommandResult(CommandResultEvent),
        #[prost(message, tag = "14")]
        IncomingTransferOffer(IncomingTransferOfferEvent),
        #[prost(message, tag = "15")]
        TransferCompleted(TransferCompletedEvent),
        #[prost(message, tag = "16")]
        TransferFailed(TransferFailedEvent),
        #[prost(message, tag = "17")]
        RouteChanged(RouteChangedEvent),
        #[prost(message, tag = "18")]
        RelayStateChanged(RelayStateChangedEvent),
        #[prost(message, tag = "19")]
        ChannelMessage(ChannelMessageEvent),
        #[prost(message, tag = "20")]
        DeliveryAcked(DeliveryAckedEvent),
        #[prost(message, tag = "21")]
        RealtimeState(RealtimeStateChangedEvent),
        #[prost(message, tag = "22")]
        RealtimeSignal(RealtimeSignalEvent),
        #[prost(message, tag = "23")]
        RealtimeSnapshot(RealtimeSnapshotEvent),
        #[prost(message, tag = "34")]
        RealtimeIncomingSessionOffer(RealtimeIncomingSessionOfferEvent),
        #[prost(message, tag = "24")]
        PeerPresenceChanged(PeerPresenceChangedEvent),
        #[prost(message, tag = "25")]
        PeerPresenceSnapshot(PeerPresenceSnapshotEvent),
        #[prost(message, tag = "26")]
        SshStreamDataReceived(SshStreamDataReceivedEvent),
        #[prost(message, tag = "27")]
        SshStreamClosed(SshStreamClosedEvent),
        #[prost(message, tag = "28")]
        PeerLifecycle(PeerLifecycleEvent),
        #[prost(message, tag = "29")]
        CommandResultV2(CommandResult),
        #[prost(message, tag = "30")]
        PeerDiagnostics(PeerDiagnostics),
        #[prost(message, tag = "31")]
        NetworkEnvironmentChanged(NetworkEnvironmentChangedEvent),
        #[prost(message, tag = "32")]
        PeerTransferProgress(PeerTransferProgressEvent),
        #[prost(message, tag = "33")]
        RouteAttemptChanged(RouteAttemptChangedEvent),
    }
}
