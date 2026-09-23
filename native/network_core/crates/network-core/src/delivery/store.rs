use std::collections::{HashMap, HashSet};
use std::time::Instant;

use super::ordered::OrderedChannelState;
use super::{DeliveryIdentity, DeliveryTerminalOutcome, MessageId, PendingMessage};
/// 接收端去重 key：Peer 业务作用域 + Channel + MessageId。
///
/// SessionId 被刻意排除——每条 Connection 都有新 SessionId，而 MessageId 在
/// 新连接重放时保持不变，去重必须跨越 Session 换代（§20）。
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub(super) struct DedupKey {
    pub(super) peer_id: String,
    pub(super) channel_id: String,
    pub(super) message_id: MessageId,
}

/// 接收端仍在等待应用 ACK 的状态；两种状态都不受 processed history 淘汰。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ActiveIncomingState {
    InFlight,
    OrderedBuffered,
}

/// Active receive record。`recovery_epoch` 只记录最后一次观测到的 wire 连接
/// 代数（用于 ACK 回显），deadline 不是 dedup TTL；不存在 epoch 门控。
#[derive(Clone, Copy, Debug)]
pub(super) struct ActiveIncomingRecord {
    pub(super) ack_deadline: Option<Instant>,
    pub(super) recovery_epoch: u64,
    pub(super) state: ActiveIncomingState,
}

/// 已完成消息的有限历史，只承担重复判断，不承担 ACK gate。
#[derive(Clone, Copy, Debug)]
pub(super) struct ProcessedDedupRecord {
    pub(super) expires_at: Instant,
    pub(super) last_seen_at: Instant,
    pub(super) recovery_epoch: u64,
}

pub(super) struct DeliveryStore {
    pub(super) pending: HashMap<DeliveryIdentity, PendingMessage>,
    pub(super) pending_bytes: usize,
    pub(super) terminal_outcomes: HashMap<DeliveryIdentity, DeliveryTerminalOutcome>,
    pub(super) next_sequences: HashMap<(String, String), u64>,
    /// Peer 作用域连接代数（每次 Connection Ready 递增一次）。只用于 wire。
    pub(super) recovery_epochs: HashMap<String, u64>,
    /// 未完成的应用处理状态。这里的记录不受 dedup TTL/LRU 影响。
    pub(super) incoming_active: HashMap<DedupKey, ActiveIncomingRecord>,
    /// 已完成消息的有限去重历史；只有这里允许 TTL 和容量淘汰。
    pub(super) processed_dedup: HashMap<DedupKey, ProcessedDedupRecord>,
    pub(super) ordered: HashMap<(String, String), OrderedChannelState>,
    pub(super) failed_ordered: HashSet<(String, String)>,
}

impl DeliveryStore {
    pub(super) fn new() -> Self {
        Self {
            pending: HashMap::new(),
            pending_bytes: 0,
            terminal_outcomes: HashMap::new(),
            next_sequences: HashMap::new(),
            recovery_epochs: HashMap::new(),
            incoming_active: HashMap::new(),
            processed_dedup: HashMap::new(),
            ordered: HashMap::new(),
            failed_ordered: HashSet::new(),
        }
    }
}

pub(super) fn dedup_key(peer_id: &str, channel_id: &str, message_id: MessageId) -> DedupKey {
    DedupKey {
        peer_id: peer_id.to_string(),
        channel_id: channel_id.to_string(),
        message_id,
    }
}

#[cfg(debug_assertions)]
pub(super) fn assert_delivery_invariants(store: &DeliveryStore) {
    for (key, record) in &store.incoming_active {
        assert!(
            !store.processed_dedup.contains_key(key),
            "active incoming record also exists in processed history"
        );
        match record.state {
            ActiveIncomingState::InFlight => {
                assert!(
                    record.ack_deadline.is_some(),
                    "in-flight record is missing its application ACK deadline"
                );
            }
            ActiveIncomingState::OrderedBuffered => {
                assert!(
                    record.ack_deadline.is_none(),
                    "ordered buffered record must not have an application ACK deadline"
                );
                let ordered = store
                    .ordered
                    .get(&(key.peer_id.clone(), key.channel_id.clone()))
                    .expect("ordered buffered record lost its channel state");
                assert!(
                    ordered
                        .reorder_buffer
                        .values()
                        .any(|message| message.message_id == key.message_id),
                    "ordered buffered record is missing from reorder_buffer"
                );
            }
        }
    }
    for (scope, ordered) in &store.ordered {
        if let Some(message_id) = ordered.in_flight {
            let key = dedup_key(&scope.0, &scope.1, message_id);
            assert!(
                store
                    .incoming_active
                    .get(&key)
                    .is_some_and(|record| { record.state == ActiveIncomingState::InFlight }),
                "ordered in-flight message is missing its active record"
            );
        }
        for message in ordered.reorder_buffer.values() {
            let key = dedup_key(&message.peer_id, &message.channel_id, message.message_id);
            assert!(
                store
                    .incoming_active
                    .get(&key)
                    .is_some_and(|record| { record.state == ActiveIncomingState::OrderedBuffered }),
                "reorder_buffer message is missing its active record"
            );
        }
    }
}

#[cfg(not(debug_assertions))]
pub(super) fn assert_delivery_invariants(_store: &DeliveryStore) {}
