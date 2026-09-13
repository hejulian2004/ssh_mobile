//! Network Protocol V2 command messages and their oneof envelope.

use super::*;
use prost::Message;

#[derive(Clone, PartialEq, Message)]
pub struct ConnectPeerCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(uint32, tag = "2")]
    pub intent: u32,
    /// 本次连接请求的 CommunicationClass；Unspecified(0) 视为默认 ReliableMessage。
    #[prost(enumeration = "CommunicationClass", tag = "3")]
    pub communication_class: i32,
}

#[derive(Clone, PartialEq, Message)]
pub struct DisconnectPeerCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct SendFileCommand {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(string, tag = "3")]
    pub file_path: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct CancelTransferCommand {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct ConfigureRuntimeCommand {
    #[prost(string, tag = "1")]
    pub device_id: String,
    #[prost(bytes = "vec", tag = "2")]
    pub identity_private_key: Vec<u8>,
    #[prost(bytes = "vec", tag = "3")]
    pub e2e_private_key: Vec<u8>,
    #[prost(string, tag = "4")]
    pub listen_address: String,
    #[prost(string, tag = "5")]
    pub receive_directory: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct UpsertPeerCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub endpoint_address: String,
    #[prost(bytes = "vec", tag = "3")]
    pub identity_public_key: Vec<u8>,
    #[prost(bytes = "vec", tag = "4")]
    pub e2e_public_key: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub struct RespondIncomingTransferCommand {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(bool, tag = "2")]
    pub accept: bool,
}

/// Stable peer configuration owned by the Network V2 peer supervisor.
#[derive(Clone, PartialEq, Message)]
pub struct PeerConfig {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub endpoint_address: String,
    #[prost(bytes = "vec", tag = "3")]
    pub identity_public_key: Vec<u8>,
    #[prost(bytes = "vec", tag = "4")]
    pub e2e_public_key: Vec<u8>,
    #[prost(enumeration = "E2eePolicy", tag = "5")]
    pub e2ee_policy: i32,
    #[prost(bool, tag = "6")]
    pub allow_direct: bool,
    #[prost(bool, tag = "7")]
    pub allow_relay: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct UpsertPeerV2Command {
    #[prost(message, optional, tag = "1")]
    pub config: Option<PeerConfig>,
}

#[derive(Clone, PartialEq, Message)]
pub struct RemovePeerCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
}

/// V2 message command whose identity is explicitly `(peer_id, message_id)`.
#[derive(Clone, PartialEq, Message)]
pub struct SendMessageV2Command {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub message_id: String,
    #[prost(string, tag = "3")]
    pub channel_id: String,
    #[prost(bytes = "vec", tag = "4")]
    pub payload: Vec<u8>,
    #[prost(enumeration = "DeliveryPolicyCode", tag = "5")]
    pub policy: i32,
    #[prost(enumeration = "E2eePolicy", tag = "6")]
    pub e2ee_policy: i32,
}

#[derive(Clone, PartialEq, Message)]
pub struct TransferCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub transfer_id: String,
    #[prost(string, tag = "3")]
    pub file_path: String,
    #[prost(uint64, tag = "4")]
    pub confirmed_offset: u64,
    #[prost(bool, tag = "5")]
    pub resume: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct PeerDiagnosticsCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkEnvironmentChangedCommand {
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
pub struct SendMessageCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub channel_id: String,
    #[prost(bytes = "vec", tag = "3")]
    pub payload: Vec<u8>,
    #[prost(enumeration = "DeliveryPolicyCode", tag = "4")]
    pub policy: i32,
}

#[derive(Clone, PartialEq, Message)]
pub struct AcknowledgeMessageCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub session_id: String,
    #[prost(string, tag = "3")]
    pub channel_id: String,
    #[prost(bytes = "vec", tag = "4")]
    pub message_id: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub struct ConfigureRelayCommand {
    #[prost(string, tag = "1")]
    pub relay_url: String,
    #[prost(string, tag = "2")]
    pub relay_credential: String,
    #[prost(bytes = "vec", tag = "3")]
    pub relay_signing_seed: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub struct DisconnectRelayCommand {}

#[derive(Clone, PartialEq, Message)]
pub struct StartRealtimeSessionCommand {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct StopRealtimeSessionCommand {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct SendRealtimeSignalCommand {
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

#[derive(Clone, PartialEq, Message)]
pub struct ClaimIncomingRealtimeOfferCommand {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(string, tag = "3")]
    pub claim_token: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct RejectIncomingRealtimeOfferCommand {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(string, tag = "3")]
    pub claim_token: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct DiscardIncomingRealtimeOfferCommand {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(string, tag = "3")]
    pub claim_token: String,
}

/// 逻辑 ReliableStream 的稳定业务身份。
///
/// `stream_id` 只在同一个 opener 的命名空间内唯一；opener 必须贯穿
/// Wire、native、FFI 与 App，不能再从本地/远端流的存在性推断。
#[derive(Clone, PartialEq, Message)]
pub struct StreamHandle {
    #[prost(string, tag = "1")]
    pub opener_device_id: String,
    #[prost(uint32, tag = "2")]
    pub stream_id: u32,
}

/// 打开一条到对端的 ReliableStream 字节流（设计 §17/§21）。`handle` 由调用方
/// 分配，native 侧校验 `stream_id ≤ u16::MAX`，`service` 是对端网关的服务提示
/// （如 "ssh"）。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamOpenCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(message, optional, tag = "2")]
    pub handle: Option<StreamHandle>,
    #[prost(string, tag = "3")]
    pub service: String,
}

/// 向一条已打开的 ReliableStream 追加字节（SSH/SFTP 协议数据作为不透明负载）。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamDataCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(message, optional, tag = "2")]
    pub handle: Option<StreamHandle>,
    #[prost(bytes = "vec", tag = "3")]
    pub data: Vec<u8>,
}

/// 关闭一条 ReliableStream。对端会观察到 StreamClosed。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamCloseCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(message, optional, tag = "2")]
    pub handle: Option<StreamHandle>,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkCommand {
    #[prost(string, tag = "1")]
    pub command_id: String,
    #[prost(uint32, tag = "2")]
    pub protocol_version: u32,
    #[prost(
        oneof = "network_command::Payload",
        tags = "10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36"
    )]
    pub payload: Option<network_command::Payload>,
}

pub mod network_command {
    use super::*;

    #[derive(Clone, PartialEq, prost::Oneof)]
    pub enum Payload {
        #[prost(message, tag = "10")]
        ConnectPeer(ConnectPeerCommand),
        #[prost(message, tag = "11")]
        SendFile(SendFileCommand),
        #[prost(message, tag = "12")]
        CancelTransfer(CancelTransferCommand),
        #[prost(message, tag = "13")]
        ConfigureRuntime(ConfigureRuntimeCommand),
        #[prost(message, tag = "14")]
        UpsertPeer(UpsertPeerCommand),
        #[prost(message, tag = "15")]
        RespondIncomingTransfer(RespondIncomingTransferCommand),
        #[prost(message, tag = "16")]
        ConfigureRelay(ConfigureRelayCommand),
        #[prost(message, tag = "17")]
        DisconnectPeer(DisconnectPeerCommand),
        #[prost(message, tag = "18")]
        DisconnectRelay(DisconnectRelayCommand),
        #[prost(message, tag = "19")]
        SendMessage(SendMessageCommand),
        #[prost(message, tag = "20")]
        AcknowledgeMessage(AcknowledgeMessageCommand),
        #[prost(message, tag = "21")]
        StartRealtimeSession(StartRealtimeSessionCommand),
        #[prost(message, tag = "22")]
        StopRealtimeSession(StopRealtimeSessionCommand),
        #[prost(message, tag = "23")]
        SendRealtimeSignal(SendRealtimeSignalCommand),
        #[prost(message, tag = "34")]
        ClaimIncomingRealtimeOffer(ClaimIncomingRealtimeOfferCommand),
        #[prost(message, tag = "35")]
        RejectIncomingRealtimeOffer(RejectIncomingRealtimeOfferCommand),
        #[prost(message, tag = "36")]
        DiscardIncomingRealtimeOffer(DiscardIncomingRealtimeOfferCommand),
        #[prost(message, tag = "25")]
        SshStreamOpen(SshStreamOpenCommand),
        #[prost(message, tag = "26")]
        SshStreamData(SshStreamDataCommand),
        #[prost(message, tag = "27")]
        SshStreamClose(SshStreamCloseCommand),
        #[prost(message, tag = "28")]
        UpsertPeerV2(UpsertPeerV2Command),
        #[prost(message, tag = "29")]
        RemovePeer(RemovePeerCommand),
        #[prost(message, tag = "30")]
        SendMessageV2(SendMessageV2Command),
        #[prost(message, tag = "31")]
        Transfer(TransferCommand),
        #[prost(message, tag = "32")]
        PeerDiagnostics(PeerDiagnosticsCommand),
        #[prost(message, tag = "33")]
        NetworkEnvironmentChanged(NetworkEnvironmentChangedCommand),
    }
}
