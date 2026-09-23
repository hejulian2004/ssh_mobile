//! 跨 Connection 的应用层投递状态。
//!
//! 这一层只保存可重新编码的业务 payload 和投递元数据，不持有 Quinn/Relay
//! handle。Connection 恢复后由上层取出 `RecoverySnapshot`，在当前 transport
//! 上重新发送；因此 ACK、去重和重试不会绑定到某一条已失效的 Connection。
//!
//! transport-network v2（§19/§20）：跨连接稳定的是业务身份 **PeerId +
//! MessageId + ChannelId**，**不是** Transport Connection 或
//! ConnectionSession。Step 8 之后 Session 与 connection 一一对应且可销毁：
//! 新连接 = 新 SessionId + 新 Noise root。因此本 manager 的 pending / dedup /
//! ordered 状态全部按 **Peer 业务作用域** 保存，绝不用每个连接的 SessionId
//! 作 key；`DeliveryIdentity`（PeerId + MessageId）是发送端 ACK 的稳定键。
//! 连接丢失时本 manager 不会清空
//! 这些状态，未 ACK 的消息会在新连接上以**同一个 MessageId** 重新发送，
//! 由接收端按 MessageId 去重（§20）。

mod incoming;
mod ordered;
mod recovery;
mod send;
mod store;

use std::collections::HashSet;
use std::time::{Duration, Instant};
use thiserror::Error;
use tokio::sync::{Mutex, RwLock};

#[cfg(test)]
#[allow(unused_imports)]
use ordered::OrderedChannelState;
#[allow(unused_imports)]
use recovery::{
    is_expired, next_message_id, prune_processed_dedup, record_terminal, remember_processed,
    remove_pending, resolve_pending_identity,
};
#[allow(unused_imports)]
use store::{
    assert_delivery_invariants, dedup_key, ActiveIncomingRecord, ActiveIncomingState, DedupKey,
    DeliveryStore, ProcessedDedupRecord,
};
const MAX_SCOPE_ID_BYTES: usize = 128;
const MESSAGE_ID_BYTES: usize = 16;
const MAX_TERMINAL_OUTCOMES: usize = 4096;

/// Stable business recovery categories shared by Delivery, Transfer, and
/// ReliableStream.  These names deliberately do not depend on a transport or
/// protocol implementation so callers can retain business meaning across a
/// fresh ConnectionSession.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Error)]
pub(crate) enum BusinessRecoveryError {
    #[error("RecoverableTransportLoss")]
    RecoverableTransportLoss,
    #[error("OperationExpired")]
    OperationExpired,
    #[error("ResumeRejected")]
    ResumeRejected,
}

pub(crate) fn is_valid_peer_id(peer_id: &str) -> bool {
    is_valid_scope_id(peer_id)
}

fn is_valid_scope_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_SCOPE_ID_BYTES
}

/// 应用 handler 的 ACK 超时是独立的生命周期策略，不能复用 processed dedup
/// 的 TTL。超时由 Delivery owner 显式扫描；严格有序通道会进入 Failed，不能
/// 通过跳过 Sequence 来伪造顺序恢复。
const MAX_ACTIVE_INCOMING_RECORDS: usize = 4096;

/// 应用层消息的稳定标识；跨 Connection 重试时保持不变。
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct MessageId([u8; MESSAGE_ID_BYTES]);

impl MessageId {
    pub fn from_bytes(bytes: [u8; MESSAGE_ID_BYTES]) -> Self {
        Self(bytes)
    }

    pub fn to_bytes(self) -> [u8; MESSAGE_ID_BYTES] {
        self.0
    }
}

/// Frozen Delivery identity. A transport/session or path is deliberately not
/// part of this key; each send attempt may acquire and release its own path
/// lease while the ACK wait remains peer-scoped.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct DeliveryIdentity {
    pub peer_id: String,
    pub message_id: MessageId,
}

impl DeliveryIdentity {
    pub fn new(peer_id: impl Into<String>, message_id: MessageId) -> Result<Self, DeliveryError> {
        let peer_id = peer_id.into();
        if !is_valid_peer_id(&peer_id) {
            return Err(DeliveryError::InvalidScope);
        }
        Ok(Self {
            peer_id,
            message_id,
        })
    }
}

/// 业务对消息的可靠性要求。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeliveryPolicy {
    BestEffort,
    LatestState,
    Acked,
    AckedDeduplicated,
    SessionBoundOrdered,
    ResumableTransfer,
}

/// 消息在应用层投递机中的状态。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeliveryState {
    Queued,
    Sending,
    SentUnacked,
    Acked,
    Expired,
    Cancelled,
    Failed,
}

/// 受界的重试预算和退避策略。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetryPolicy {
    pub max_attempts: u32,
    pub initial_backoff: Duration,
    pub max_backoff: Duration,
    pub ttl: Option<Duration>,
    pub max_total_retry_bytes: Option<u64>,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 5,
            initial_backoff: Duration::from_millis(250),
            max_backoff: Duration::from_secs(5),
            ttl: Some(Duration::from_secs(10 * 60)),
            max_total_retry_bytes: Some(64 * 1024 * 1024),
        }
    }
}

impl RetryPolicy {
    fn is_valid(self) -> bool {
        self.max_attempts > 0 && self.initial_backoff <= self.max_backoff
    }

    fn delay_for_attempt(self, attempt: u32) -> Duration {
        let shift = attempt.saturating_sub(1).min(31);
        let multiplier = 1u32.checked_shl(shift).unwrap_or(u32::MAX);
        self.initial_backoff
            .saturating_mul(multiplier)
            .min(self.max_backoff)
    }
}

/// 等待 ACK 的逻辑消息。payload 保持为可在新 Connection 上重新编码的内容。
///
/// 稳定标识是 `message_id`；`peer_id` 是消息所属的**业务作用域**（对端
/// 设备标识），`session_id` 已被移除——每条 Connection 都有新的 SessionId，
/// 因此不在此保存会过期的 per-connection 标识。发送时由传输层传入当前
/// `SessionId` 作为 wire 信封与加密上下文。
#[derive(Clone, Debug)]
pub struct PendingMessage {
    pub message_id: MessageId,
    pub peer_id: String,
    pub channel_id: String,
    pub sequence: u64,
    pub payload: Vec<u8>,
    pub policy: DeliveryPolicy,
    pub state: DeliveryState,
    pub attempts: u32,
    pub created_at: Instant,
    pub expires_at: Option<Instant>,
    /// Peer 作用域的连接代数（每次 Connection Ready 递增一次）。只用于 wire
    /// 信封 / AAD 与诊断，**不再作为 ACK 或去重的门控**。
    pub recovery_epoch: u64,
    retry_policy: RetryPolicy,
    next_retry_at: Instant,
    retry_bytes: u64,
}

/// 一次 Connection Ready 后交给传输层的恢复批次。
///
/// `recovery_epoch` 是该 Peer 作用域当前连接代数，仅用于 wire 信封；
/// 恢复去重完全由 `MessageId` 驱动。
#[derive(Clone, Debug)]
pub struct RecoverySnapshot {
    pub recovery_epoch: u64,
    pub messages: Vec<PendingMessage>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AckResult {
    /// 该 MessageId 正在 pending 中，已从投递队列移除。
    Acknowledged,
    /// 该 MessageId 未知（已完成、未入队或属于其它 Peer）；ACK 是无害的 no-op。
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DedupDecision {
    New,
    DuplicateInFlight,
    DuplicateProcessed,
    /// Active 记录不能为了满足 history 上限而淘汰；调用方必须拒绝新消息，
    /// 等待现有应用 ACK 或显式 timeout。
    CapacityExceeded,
    /// 严格有序通道因显式 abandon 或 ACK timeout 进入失败态。
    ChannelFailed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryDecision {
    RetryAt(Instant),
    Failed,
    Expired,
    NotFound,
}

impl RetryDecision {
    pub(crate) fn recovery_error(self) -> Option<BusinessRecoveryError> {
        match self {
            Self::RetryAt(_) => Some(BusinessRecoveryError::RecoverableTransportLoss),
            Self::Failed | Self::Expired => Some(BusinessRecoveryError::OperationExpired),
            Self::NotFound => None,
        }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum DeliveryError {
    #[error("peer and channel identifiers are required")]
    InvalidScope,
    #[error("message payload exceeds the delivery limit")]
    PayloadTooLarge,
    #[error("retry policy is invalid")]
    InvalidRetryPolicy,
    #[error("delivery queue is full")]
    QueueFull,
    #[error("message is not pending")]
    NotFound,
    #[error("message expired")]
    Expired,
    #[error("message retry budget exhausted")]
    RetryExhausted,
}

impl DeliveryError {
    pub(crate) fn recovery_error(&self) -> Option<BusinessRecoveryError> {
        match self {
            Self::Expired | Self::RetryExhausted => Some(BusinessRecoveryError::OperationExpired),
            _ => None,
        }
    }
}

/// The single terminal transition an acknowledged reliable message may make.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DeliveryTerminalOutcome {
    Acknowledged,
    Expired,
    Cancelled,
    Failed,
}

/// A peer-scoped lease for one transport send attempt.  The attempt number is
/// checked on completion so a late result from an older attempt cannot settle
/// a newer one.
#[derive(Clone, Debug)]
pub(crate) struct DeliverySendAttempt {
    pub(crate) peer_id: String,
    pub(crate) message_id: MessageId,
    pub(crate) attempt: u32,
    pub(crate) message: PendingMessage,
}

/// Delivery 队列和去重窗口的边界。
#[derive(Clone, Copy, Debug)]
pub struct DeliveryConfig {
    pub max_pending_messages: usize,
    pub max_pending_bytes: usize,
    pub max_payload_bytes: usize,
    /// 仅限制已完成消息的 processed dedup history；InFlight 与
    /// OrderedBuffered 不参与淘汰。
    pub dedup_max_entries: usize,
    /// 仅用于 processed dedup history。Active handler 使用
    /// `application_ack_timeout`，避免两个生命周期语义混用。
    pub dedup_ttl: Duration,
    /// 应用真正收到消息后等待 ACK 的时间。OrderedBuffered 不使用该计时器，
    /// 只有晋升为 InFlight 时才会生成 deadline。
    pub application_ack_timeout: Duration,
    pub max_reorder_messages: usize,
    pub max_reorder_bytes: usize,
    pub max_sequence_gap: u64,
}

impl Default for DeliveryConfig {
    fn default() -> Self {
        Self {
            max_pending_messages: 1024,
            max_pending_bytes: 16 * 1024 * 1024,
            max_payload_bytes: 1024 * 1024,
            dedup_max_entries: 4096,
            dedup_ttl: Duration::from_secs(10 * 60),
            application_ack_timeout: Duration::from_secs(5 * 60),
            max_reorder_messages: 64,
            max_reorder_bytes: 4 * 1024 * 1024,
            max_sequence_gap: 1024,
        }
    }
}

/// A message waiting for an application-ordered channel to release it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct OrderedMessage {
    pub(crate) peer_id: String,
    pub(crate) session_id: String,
    pub(crate) channel_id: String,
    pub(crate) message_id: MessageId,
    pub(crate) sequence: u64,
    pub(crate) policy: DeliveryPolicy,
    pub(crate) payload: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum OrderedInsertResult {
    Ready,
    Buffered,
    Duplicate,
    Rejected,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct IncomingCompletion {
    pub(crate) recovery_epoch: u64,
    pub(crate) next_ordered: Option<OrderedMessage>,
}

/// Application ACK 超时后的可观测摘要。
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct IncomingTimeout {
    pub(crate) peer_id: String,
    pub(crate) channel_id: String,
    pub(crate) message_id: MessageId,
    pub(crate) ordered_channel_failed: bool,
}

/// App Scope 内唯一的应用层投递状态 owner。
///
/// `retry_workers` 记录每个 Peer 是否已有重试任务在运行。重试任务本身由连接
/// 层注入发送回调后运行（它需要 transport），但**所有权/注册表属于本业务
/// manager**：key 是 Peer 业务作用域，绝不是 ConnectionSession 的 SessionId，
/// 因此能跨越 transport 丢失继续存活（无连接时暂停、新连接到来后恢复）。
pub struct DeliveryManager {
    config: DeliveryConfig,
    store: Mutex<DeliveryStore>,
    retry_workers: RwLock<HashSet<String>>,
}

impl Default for DeliveryManager {
    fn default() -> Self {
        Self::new()
    }
}

impl DeliveryManager {
    pub fn new() -> Self {
        Self::with_config(DeliveryConfig::default())
    }

    pub fn with_config(config: DeliveryConfig) -> Self {
        Self {
            config,
            store: Mutex::new(DeliveryStore::new()),
            retry_workers: RwLock::new(HashSet::new()),
        }
    }

    /// 尝试为 Peer 认领一个重试 worker。返回 `true` 表示调用方应当启动该
    /// Peer 的循环（本调用首次认领）；返回 `false` 表示已有一个 worker 在跑。
    ///
    /// key 是 Peer 业务作用域；worker 在无连接时暂停、在新 ConnectionSession
    /// 出现后恢复，因此一次认领即可覆盖后续所有重连。
    pub async fn try_start_retry_worker(&self, peer_id: &str) -> bool {
        self.retry_workers.write().await.insert(peer_id.to_string())
    }

    /// 释放 Peer 的重试 worker 注册。仅在 worker 启动失败（supervisor 已
    /// stopping）时调用，允许下一次连接重新认领。
    pub async fn stop_retry_worker(&self, peer_id: &str) {
        self.retry_workers.write().await.remove(peer_id);
    }
}

#[cfg(test)]
#[path = "../tests/delivery.rs"]
mod tests;
