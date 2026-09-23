use rand::RngCore;
use std::collections::HashMap;
use std::time::Instant;

use super::{
    assert_delivery_invariants, is_valid_peer_id, DedupKey, DeliveryError, DeliveryIdentity,
    DeliveryManager, DeliveryState, DeliveryStore, DeliveryTerminalOutcome, MessageId,
    PendingMessage, ProcessedDedupRecord, RecoverySnapshot, MAX_TERMINAL_OUTCOMES,
    MESSAGE_ID_BYTES,
};

impl DeliveryManager {
    /// 新 Connection Ready 后，重置 Peer 作用域的 in-flight 状态并返回恢复批次。
    ///
    /// `peer_id` 是业务作用域；所有该 Peer 未 ACK 的 pending 消息（无论它们在
    /// 哪一条旧 Connection 上入队）都会以**同一个 MessageId** 返回，由上层在
    /// 当前 transport 上重发。
    pub async fn recover_peer(&self, peer_id: &str) -> RecoverySnapshot {
        self.recover_peer_at(peer_id, Instant::now()).await
    }

    pub(crate) async fn recover_peer_checked(
        &self,
        peer_id: &str,
    ) -> Result<RecoverySnapshot, DeliveryError> {
        if !is_valid_peer_id(peer_id) {
            return Err(DeliveryError::InvalidScope);
        }
        Ok(self.recover_peer(peer_id).await)
    }

    pub(super) async fn recover_peer_at(&self, peer_id: &str, now: Instant) -> RecoverySnapshot {
        let mut store = self.store.lock().await;
        let epoch = store
            .recovery_epochs
            .entry(peer_id.to_string())
            .and_modify(|epoch| *epoch = epoch.saturating_add(1))
            .or_insert(1);
        let recovery_epoch = *epoch;
        let message_ids = store
            .pending
            .iter()
            .filter(|(_, message)| message.peer_id == peer_id)
            .map(|(identity, _)| identity.clone())
            .collect::<Vec<_>>();
        let mut messages = Vec::new();
        let mut expired = Vec::new();
        for identity in message_ids {
            let Some(message) = store.pending.get_mut(&identity) else {
                continue;
            };
            if is_expired(message, now) {
                expired.push(identity.clone());
                continue;
            }
            message.state = DeliveryState::Queued;
            message.next_retry_at = now;
            message.recovery_epoch = recovery_epoch;
            messages.push(message.clone());
        }
        for identity in expired {
            remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Expired);
        }
        messages.sort_by_key(|message| message.sequence);
        RecoverySnapshot {
            recovery_epoch,
            messages,
        }
    }

    /// 到达 ACK 超时点的消息重新进入可发送队列。
    pub async fn retryable_messages(&self, peer_id: &str, now: Instant) -> Vec<PendingMessage> {
        let mut store = self.store.lock().await;
        let message_ids = store
            .pending
            .iter()
            .filter(|(_, message)| message.peer_id == peer_id)
            .map(|(identity, _)| identity.clone())
            .collect::<Vec<_>>();
        let mut retryable = Vec::new();
        let mut expired = Vec::new();
        for identity in message_ids {
            let Some(message) = store.pending.get_mut(&identity) else {
                continue;
            };
            if is_expired(message, now) {
                expired.push(identity.clone());
            } else if message.state == DeliveryState::SentUnacked && now >= message.next_retry_at {
                message.state = DeliveryState::Queued;
                message.next_retry_at = now;
                retryable.push(message.clone());
            } else if message.state == DeliveryState::Queued && now >= message.next_retry_at {
                retryable.push(message.clone());
            }
        }
        for identity in expired {
            remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Expired);
        }
        retryable.sort_by_key(|message| message.sequence);
        retryable
    }

    pub(crate) async fn retryable_messages_checked(
        &self,
        peer_id: &str,
        now: Instant,
    ) -> Result<Vec<PendingMessage>, DeliveryError> {
        if !is_valid_peer_id(peer_id) {
            return Err(DeliveryError::InvalidScope);
        }
        Ok(self.retryable_messages(peer_id, now).await)
    }

    pub async fn cancel(&self, message_id: MessageId) -> bool {
        let mut store = self.store.lock().await;
        let Some(identity) = resolve_pending_identity(&store, None, message_id) else {
            return false;
        };
        let Some(message) = store.pending.get_mut(&identity) else {
            return false;
        };
        message.state = DeliveryState::Cancelled;
        let removed = remove_pending(&mut store, &identity).is_some();
        if removed {
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Cancelled);
        }
        removed
    }

    /// 当前 Peer 作用域的连接代数（每次 Connection Ready 递增一次）。
    ///
    /// 集成测试用：观察发送端在重连/显式 recovery 后递增了连接代数。仅测试
    /// 构建暴露；生产代码不使用该只读访问器。
    #[cfg(test)]
    pub(crate) async fn current_peer_recovery_epoch(&self, peer_id: &str) -> u64 {
        let store = self.store.lock().await;
        store
            .recovery_epochs
            .get(peer_id)
            .copied()
            .unwrap_or_default()
    }

    /// Explicitly closes a Peer's receive-side state (用户显式断开/清理)。
    ///
    /// 仅显式断开时调用；transport 丢失（Session 被销毁）**不会**调用它——接收端
    /// 的 dedup/ordered 状态必须跨 Connection 存活，新连接才能按 MessageId 去重、
    /// 并在有序通道上从上次断点继续。Outgoing pending 消息保持独立，不在此清理。
    ///
    /// 显式断开会放弃在途 dedup 记录（incoming_active）、已完成消息历史
    /// （processed_dedup）与 Failed 通道标记（failed_ordered），但**保留**有序通道
    /// 的健康断点（expected_sequence）——与发送端保留 `next_sequences` 计数器对称：
    /// 两端在显式断开并重连后都从各自断点继续，有序投递无缝恢复，不会出现接收端
    /// 从 0 重新计数而发送端继续 5、6、7 造成的永久空洞。仍待重发的 pending 消息会
    /// 在重连后重建 dedup 记录并重新插入保留的 ordered 状态；已 ACK 消息不在发送端
    /// pending 中，不会被重发。
    pub(crate) async fn close_peer(&self, peer_id: &str) {
        let mut store = self.store.lock().await;
        store
            .incoming_active
            .retain(|key, _| key.peer_id != peer_id);
        store
            .processed_dedup
            .retain(|key, _| key.peer_id != peer_id);
        // 保留有序断点：只丢弃尚未释放的 in-flight / reorder 消息（重连后由 pending
        // 重放重建 dedup 记录），绝不重置 expected_sequence。
        for (scope, ordered) in &mut store.ordered {
            if scope.0 == peer_id {
                ordered.in_flight = None;
                ordered.reorder_buffer.clear();
                ordered.reorder_bytes = 0;
            }
        }
        store.failed_ordered.retain(|(peer, _)| peer != peer_id);
        assert_delivery_invariants(&store);
    }
}

pub(super) fn next_message_id(
    peer_id: &str,
    pending: &HashMap<DeliveryIdentity, PendingMessage>,
    terminal_outcomes: &HashMap<DeliveryIdentity, DeliveryTerminalOutcome>,
) -> MessageId {
    loop {
        let mut bytes = [0u8; MESSAGE_ID_BYTES];
        rand::thread_rng().fill_bytes(&mut bytes);
        let candidate = MessageId(bytes);
        let identity = DeliveryIdentity {
            peer_id: peer_id.to_string(),
            message_id: candidate,
        };
        if !pending.contains_key(&identity) && !terminal_outcomes.contains_key(&identity) {
            return candidate;
        }
    }
}

pub(super) fn resolve_pending_identity(
    store: &DeliveryStore,
    expected_peer_id: Option<&str>,
    message_id: MessageId,
) -> Option<DeliveryIdentity> {
    if let Some(peer_id) = expected_peer_id {
        let identity = DeliveryIdentity {
            peer_id: peer_id.to_string(),
            message_id,
        };
        return store.pending.contains_key(&identity).then_some(identity);
    }

    let mut matches = store
        .pending
        .keys()
        .filter(|identity| identity.message_id == message_id)
        .cloned();
    let identity = matches.next()?;
    matches.next().is_none().then_some(identity)
}

pub(super) fn record_terminal(
    store: &mut DeliveryStore,
    identity: DeliveryIdentity,
    outcome: DeliveryTerminalOutcome,
) {
    if !store.terminal_outcomes.contains_key(&identity)
        && store.terminal_outcomes.len() >= MAX_TERMINAL_OUTCOMES
    {
        if let Some(oldest) = store.terminal_outcomes.keys().next().cloned() {
            store.terminal_outcomes.remove(&oldest);
        }
    }
    store.terminal_outcomes.entry(identity).or_insert(outcome);
}

pub(super) fn is_expired(message: &PendingMessage, now: Instant) -> bool {
    message
        .expires_at
        .is_some_and(|expires_at| now >= expires_at)
}

pub(super) fn remove_pending(
    store: &mut DeliveryStore,
    identity: &DeliveryIdentity,
) -> Option<PendingMessage> {
    let message = store.pending.remove(identity)?;
    store.pending_bytes = store.pending_bytes.saturating_sub(message.payload.len());
    Some(message)
}

pub(super) fn prune_processed_dedup(store: &mut DeliveryStore, now: Instant) {
    store
        .processed_dedup
        .retain(|_, record| record.expires_at > now);
}

pub(super) fn remember_processed(
    store: &mut DeliveryStore,
    key: DedupKey,
    record: ProcessedDedupRecord,
    max_entries: usize,
) {
    if max_entries == 0 {
        // 零窗口仍会保留 active record 到当前 ACK，只是不保留 ACK 后的
        // duplicate history。
        return;
    }
    store
        .processed_dedup
        .retain(|_, existing| existing.expires_at > record.last_seen_at);
    while store.processed_dedup.len() >= max_entries {
        let oldest = store
            .processed_dedup
            .iter()
            .min_by_key(|(_, existing)| existing.last_seen_at)
            .map(|(key, _)| key.clone());
        let Some(oldest) = oldest else {
            break;
        };
        store.processed_dedup.remove(&oldest);
    }
    store.processed_dedup.insert(key, record);
}
