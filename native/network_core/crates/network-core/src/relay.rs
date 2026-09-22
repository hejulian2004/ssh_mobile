//! Relay v2 控制面 + reservation 数据面（transport-network v2 §24/§25/§31/§32）。
//!
//! V2 单一 `RelayClient`（`/V2/connect` JSON 控制 + 0x10 二进制数据）已在 Step 11
//! 删除。Relay 控制面（`/v2/control`）与数据面（`/v2/relay/{reservation_id}`）物理
//! 隔离：
//!
//! - 控制面：`RelayControlClient`。Resolve / Discovery / Connectivity / Presence /
//!   Realtime / Reservation 均经它路由（§31 `reserveRelay`）。
//! - 数据面：`RelayDataClient`（§25）。Direct 失败后由 `ConnectivityAttemptCoordinator` 经
//!   `reserve_relay` 获取 reservation，双方连接 `/v2/relay/{reservation_id}`；文件、
//!   流与可靠消息数据以不透明信封在数据面上转发（服务器不解密业务数据）。

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use network_protocol::{
    ConfigureRelayCommand, DataMessage, DeliveryAck, NetworkError as ProtocolError,
    NetworkErrorCode, PeerPresenceChangedEvent, PeerPresenceState, RouteType,
};
use network_relay::v2::{
    ConnectivityOffer, ControlEvent, DataEvent, DiscoverySnapshot, RuntimeEpoch,
};
use network_relay::{RelayControlClient, RelayDataClient, RelayError};
use network_transfer::{
    build_file_manifest, existing_completed_file, existing_partial_offset, FileManifest,
    ResumableTransfer, TransferFailureReason, DEFAULT_TRANSFER_BUFFER,
};
use prost::Message;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt, SeekFrom};
use tokio::sync::{mpsc, oneshot};

use crate::connection::{decode_generic_frame, GenericFrameKind};
use crate::crypto::{self, APPLICATION_CRYPTO_SUITE};
use crate::crypto_handshake::SessionCryptoMaterial;
use crate::events::{
    emit_incoming_offer, emit_peer_presence_changed, emit_peer_presence_snapshot,
    emit_transfer_completed, emit_transfer_error, emit_transfer_progress, protocol_error,
    protocol_error_with_context, protocol_error_with_retry,
};
use crate::runtime::{
    ConnectionAdmissionLease, PeerConfig, RelayTransferPort, RuntimeState, TransferRelayPort,
    INCOMING_APPROVAL_TIMEOUT, MAX_PENDING_INCOMING_TRANSFERS, MAX_PENDING_RELAY_CRYPTO_HANDSHAKES,
};
use network_nat::{
    Candidate, CandidateAdvertisement, ConnectivityAttempt, ConnectivityAttemptState,
    RuntimeEpoch as NatRuntimeEpoch,
};
use network_protocol::RetryDisposition;
use std::time::{Duration, Instant, SystemTime};

/// Relay 配置只存在 native runtime 内存中，用于控制面 socket 意外断开后的指数退避重连。
#[derive(Clone)]
pub(crate) struct RelayReconnectConfig {
    pub(crate) relay_url: String,
    pub(crate) credential: String,
    pub(crate) signing_seed: [u8; 32],
}

/// 发送方等待接收方返回的恢复确认。
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub(crate) struct RelayAcceptance {
    pub(crate) v: u32,
    pub(crate) transfer_id: String,
    pub(crate) manifest_hash: String,
    pub(crate) file_hash: String,
    pub(crate) offset: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct RelayAcceptancePayload {
    v: u32,
    transfer_id: String,
    manifest_hash: String,
    file_hash: String,
    offset: u64,
}

/// Relay 文件分块信封的固定开销：数据面 kind 标签(1) + session_id(32) +
/// sequence u64(8) + 应用 crypto 信封头(26，= crypto.rs ENVELOPE_HEADER_BYTES =
/// magic 4 + version 1 + suite 1 + epoch u64 8 + nonce 12) + GCM 认证标签(16，=
/// crypto.rs GCM_TAG_BYTES)。整块加密后包上 DATA_ENV_FILE_CHUNK 信封仍必须落在
/// 数据面 MAX_DATA_PAYLOAD_BYTES(512 KiB) 之内，否则 RelayDataClient::send 会以
/// InvalidConfiguration 拒绝，导致整份文件发送失败。
const RELAY_FILE_CHUNK_ENVELOPE_OVERHEAD_BYTES: usize = 1 + 32 + 8 + 26 + 16;

/// Relay 文件每个分块固定边界，确保断线时的 offset 能无歧义映射到 nonce 序号。
/// 明文分块比 DEFAULT_TRANSFER_BUFFER 小一个信封开销，加密后的整封不超数据面上限。
const RELAY_FILE_CHUNK_BYTES: u64 =
    (DEFAULT_TRANSFER_BUFFER - RELAY_FILE_CHUNK_ENVELOPE_OVERHEAD_BYTES) as u64;

/// 等待 UI 审批的待处理 Relay 申请。
#[derive(Clone)]
pub(crate) struct PendingRelayIncoming {
    pub(crate) transfer_id: String,
    pub(crate) session_id: String,
    pub(crate) sender_id: String,
    pub(crate) manifest: FileManifest,
    pub(crate) manifest_hash: String,
    /// The sender's logical Session key. The Relay attempt token is separate
    /// and must never select the application crypto context.
    pub(crate) crypto_session_id: String,
}

/// 在校验文件提交前使用的活跃 Relay 接收状态。
pub(crate) struct ActiveRelayIncoming {
    pub(crate) offer: PendingRelayIncoming,
    pub(crate) file: Option<tokio::fs::File>,
    pub(crate) temporary_path: PathBuf,
    pub(crate) final_path: PathBuf,
    pub(crate) next_sequence: u64,
    pub(crate) received_bytes: u64,
    pub(crate) hasher: Sha256,
    pub(crate) already_completed: bool,
}

// ---------------------------------------------------------------------------
// 数据面不透明信封（§25：数据通道只做 Encrypted Payload Forwarding）。
// 信封第一字节是类型标签（对 Relay 透明，不属于业务数据），其余为业务负载。
// ---------------------------------------------------------------------------

const DATA_ENV_CRYPTO: u8 = 0x01;
const DATA_ENV_FILE_OFFER: u8 = 0x02;
const DATA_ENV_FILE_ACCEPT: u8 = 0x03;
const DATA_ENV_FILE_COMPLETE: u8 = 0x04;
const DATA_ENV_FILE_COMPLETE_ACK: u8 = 0x05;
const DATA_ENV_FILE_CANCEL: u8 = 0x06;
const DATA_ENV_FILE_CHUNK: u8 = 0x07;
const DATA_ENV_CHANNEL: u8 = 0x08;
const DATA_ENV_CHANNEL_ACK: u8 = 0x09;
const DATA_ENV_STREAM: u8 = 0x0A;

#[path = "relay_control/mod.rs"]
mod relay_control;
#[path = "relay_data/mod.rs"]
mod relay_data;
#[path = "relay_transfer/mod.rs"]
mod relay_transfer;

pub(super) use relay_control::*;
#[cfg(test)]
pub(crate) use relay_data::handle_relay_data_payload as test_handle_relay_data_payload;
pub(super) use relay_data::*;
pub(super) use relay_transfer::*;

#[cfg(test)]
#[path = "tests/relay.rs"]
mod tests;
