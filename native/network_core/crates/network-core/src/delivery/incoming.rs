use super::*;

impl DeliveryManager {
    /// 接收端在业务 handler 前登记 MessageId（§20）。重复消息只需再次 ACK。
    ///
    /// 去重完全由 `DedupKey{ peer_id, channel_id, message_id }` 驱动；SessionId
    /// 被排除——同一 MessageId 在新 Connection（新 SessionId）上重放时必须命中
    /// 同一个记录。`recovery_epoch` 只记录最后一次观测到的 wire 连接代数，
    /// **不做任何门控**。
    pub async fn begin_incoming(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
        recovery_epoch: u64,
        now: Instant,
    ) -> DedupDecision {
        let mut store = self.store.lock().await;
        // Application timeout 是独立且显式的生命周期决策；它可以清理超时
        // handler，但下面的普通 dedup TTL 只能淘汰已完成的历史。
        let _ = expire_incoming_locked(&mut store, now, Some(peer_id));
        prune_processed_dedup(&mut store, now);
        let key = dedup_key(peer_id, channel_id, message_id);
        let scope = (peer_id.to_string(), channel_id.to_string());
        if store.failed_ordered.contains(&scope) {
            return DedupDecision::ChannelFailed;
        }
        if let Some(record) = store.incoming_active.get_mut(&key) {
            // 同一 MessageId 的重放：只更新 ACK 回显绑定的连接代数，保留业务
            // 处理状态（绝不能把尚未完成 ACK 的 handler 当成已处理消息）。
            record.recovery_epoch = recovery_epoch;
            return DedupDecision::DuplicateInFlight;
        }
        if let Some(record) = store.processed_dedup.get_mut(&key) {
            // 已完成消息的重复帧：更新回显代数并续期 processed history，但不再
            // 重新进入应用 handler。
            record.recovery_epoch = recovery_epoch;
            record.last_seen_at = now;
            record.expires_at = now + self.config.dedup_ttl;
            return DedupDecision::DuplicateProcessed;
        }
        if store.incoming_active.len() >= MAX_ACTIVE_INCOMING_RECORDS {
            // Active records are never removed to satisfy the processed-history
            // bound. Rejecting new work preserves the ACK contract and gives
            // existing handlers a chance to finish or time out explicitly.
            return DedupDecision::CapacityExceeded;
        }
        store.incoming_active.insert(
            key,
            ActiveIncomingRecord {
                ack_deadline: Some(now + self.config.application_ack_timeout),
                recovery_epoch,
                state: ActiveIncomingState::InFlight,
            },
        );
        assert_delivery_invariants(&store);
        DedupDecision::New
    }

    pub(crate) async fn begin_incoming_checked(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
        recovery_epoch: u64,
        now: Instant,
    ) -> Result<DedupDecision, DeliveryError> {
        if !is_valid_peer_id(peer_id) || !is_valid_scope_id(channel_id) {
            return Err(DeliveryError::InvalidScope);
        }
        Ok(self
            .begin_incoming(peer_id, channel_id, message_id, recovery_epoch, now)
            .await)
    }

    /// Insert a newly deduplicated message into its SessionBoundOrdered state.
    ///
    /// Only the message at `expected_sequence` becomes application-visible;
    /// later messages stay in a bounded buffer until the current in-flight
    /// message is acknowledged.
    pub(crate) async fn accept_ordered(&self, message: OrderedMessage) -> OrderedInsertResult {
        self.accept_ordered_at(message, Instant::now()).await
    }

    pub(super) async fn accept_ordered_at(
        &self,
        message: OrderedMessage,
        now: Instant,
    ) -> OrderedInsertResult {
        if !is_valid_peer_id(&message.peer_id) || !is_valid_scope_id(&message.channel_id) {
            return OrderedInsertResult::Rejected;
        }
        let mut store = self.store.lock().await;
        let key = (message.peer_id.clone(), message.channel_id.clone());
        if store.failed_ordered.contains(&key) {
            return OrderedInsertResult::Rejected;
        }
        let active_key = dedup_key(&message.peer_id, &message.channel_id, message.message_id);
        if !store.incoming_active.contains_key(&active_key) {
            debug_assert!(
                false,
                "ordered message must have an active dedup record before insertion"
            );
            return OrderedInsertResult::Rejected;
        }
        let result = store.ordered.entry(key).or_default().insert(
            message,
            self.config.max_reorder_messages,
            self.config.max_reorder_bytes,
            self.config.max_sequence_gap,
        );
        match result {
            OrderedInsertResult::Ready => {
                if let Some(record) = store.incoming_active.get_mut(&active_key) {
                    record.state = ActiveIncomingState::InFlight;
                    record.ack_deadline = Some(now + self.config.application_ack_timeout);
                }
            }
            OrderedInsertResult::Buffered => {
                if let Some(record) = store.incoming_active.get_mut(&active_key) {
                    record.state = ActiveIncomingState::OrderedBuffered;
                    record.ack_deadline = None;
                }
            }
            OrderedInsertResult::Duplicate | OrderedInsertResult::Rejected => {}
        }
        assert_delivery_invariants(&store);
        result
    }

    pub(crate) async fn complete_incoming(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> Option<IncomingCompletion> {
        self.complete_incoming_at(peer_id, channel_id, message_id, Instant::now())
            .await
    }

    pub(crate) async fn complete_incoming_checked(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> Result<Option<IncomingCompletion>, DeliveryError> {
        if !is_valid_peer_id(peer_id) || !is_valid_scope_id(channel_id) {
            return Err(DeliveryError::InvalidScope);
        }
        Ok(self
            .complete_incoming(peer_id, channel_id, message_id)
            .await)
    }

    pub(super) async fn complete_incoming_at(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
        now: Instant,
    ) -> Option<IncomingCompletion> {
        let mut store = self.store.lock().await;
        let key = dedup_key(peer_id, channel_id, message_id);
        let active = *store.incoming_active.get(&key)?;
        let scope = (peer_id.to_string(), channel_id.to_string());

        if let Some(ordered) = store.ordered.get(&scope) {
            match ordered.in_flight {
                Some(current) if current == message_id => {}
                Some(_) => return None,
                None if active.state == ActiveIncomingState::OrderedBuffered => return None,
                None => {}
            }
        } else if active.state == ActiveIncomingState::OrderedBuffered {
            debug_assert!(false, "buffered ordered record lost its channel state");
            return None;
        }

        // 先检查下一个 buffer 条目再修改 ordering gate，保证 active record
        // 与 reorder_buffer 的 invariant 在同一把 store 锁内保持原子一致。
        let next_key = store.ordered.get(&scope).and_then(|ordered| {
            (ordered.in_flight == Some(message_id))
                .then(|| ordered.expected_sequence.saturating_add(1))
                .and_then(|sequence| ordered.reorder_buffer.get(&sequence))
                .map(|next| dedup_key(&next.peer_id, &next.channel_id, next.message_id))
        });
        if let Some(next_key) = next_key.as_ref() {
            let next_active = store.incoming_active.get(next_key);
            if !matches!(
                next_active,
                Some(record) if record.state == ActiveIncomingState::OrderedBuffered
            ) {
                debug_assert!(false, "ordered buffer entry has no active dedup record");
                return None;
            }
        }

        let next_ordered = if let Some(ordered) = store.ordered.get_mut(&scope) {
            match ordered.in_flight {
                Some(current) if current == message_id => ordered.acknowledge(message_id),
                Some(_) => return None,
                None => None,
            }
        } else {
            None
        };
        store.incoming_active.remove(&key)?;
        if let Some(next) = next_ordered.as_ref() {
            let next_key = dedup_key(&next.peer_id, &next.channel_id, next.message_id);
            if let Some(record) = store.incoming_active.get_mut(&next_key) {
                record.state = ActiveIncomingState::InFlight;
                record.ack_deadline = Some(now + self.config.application_ack_timeout);
            } else {
                debug_assert!(false, "ordered next message lost its active record");
                return None;
            }
        }
        remember_processed(
            &mut store,
            key,
            ProcessedDedupRecord {
                expires_at: now + self.config.dedup_ttl,
                last_seen_at: now,
                recovery_epoch: active.recovery_epoch,
            },
            self.config.dedup_max_entries,
        );
        assert_delivery_invariants(&store);
        Some(IncomingCompletion {
            recovery_epoch: active.recovery_epoch,
            next_ordered,
        })
    }

    /// Return the last observed wire connection generation for a received message.
    ///
    /// Only used to echo the sender's generation inside a DeliveryAck; the
    /// ACK correlation itself is MessageId-based and never gates on it.
    pub async fn incoming_recovery_epoch(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> Option<u64> {
        let store = self.store.lock().await;
        let key = dedup_key(peer_id, channel_id, message_id);
        store
            .incoming_active
            .get(&key)
            .map(|record| record.recovery_epoch)
            .or_else(|| {
                store
                    .processed_dedup
                    .get(&key)
                    .map(|record| record.recovery_epoch)
            })
    }

    pub async fn abandon_incoming(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> bool {
        let mut store = self.store.lock().await;
        let key = dedup_key(peer_id, channel_id, message_id);
        if !store.incoming_active.contains_key(&key) {
            return false;
        }
        let scope = (peer_id.to_string(), channel_id.to_string());
        let ordered = store.ordered.get(&scope).is_some_and(|state| {
            state.in_flight == Some(message_id)
                || state
                    .reorder_buffer
                    .values()
                    .any(|message| message.message_id == message_id)
        });
        if ordered {
            let _ = fail_ordered_channel(&mut store, &scope);
        } else {
            store.incoming_active.remove(&key);
        }
        assert_delivery_invariants(&store);
        true
    }

    /// 拒绝尚未进入 ordered buffer 的消息。它与应用显式 abandon 分开，避免
    /// malformed/超限 packet 意外使健康的 ordered channel 进入 Failed。
    pub(crate) async fn reject_incoming(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> bool {
        let mut store = self.store.lock().await;
        let removed = store
            .incoming_active
            .remove(&dedup_key(peer_id, channel_id, message_id))
            .is_some();
        assert_delivery_invariants(&store);
        removed
    }

    /// 扫描应用 ACK 超时。非有序消息只释放 active 记录；严格有序通道会
    /// 整体进入 Failed 并清空缓冲，绝不自动跳过缺失的 Sequence。
    pub(crate) async fn expire_incoming(
        &self,
        peer_id: &str,
        now: Instant,
    ) -> Vec<IncomingTimeout> {
        let mut store = self.store.lock().await;
        let expired = expire_incoming_locked(&mut store, now, Some(peer_id));
        assert_delivery_invariants(&store);
        expired
    }

    #[cfg(test)]
    pub(crate) async fn incoming_state_counts(&self) -> (usize, usize, usize) {
        let store = self.store.lock().await;
        let reorder_messages = store
            .ordered
            .values()
            .map(|state| state.reorder_buffer.len())
            .sum();
        (
            store.incoming_active.len(),
            store.processed_dedup.len(),
            reorder_messages,
        )
    }

    #[cfg(test)]
    pub(super) async fn incoming_record_state(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> Option<(ActiveIncomingState, Option<Instant>)> {
        let store = self.store.lock().await;
        store
            .incoming_active
            .get(&dedup_key(peer_id, channel_id, message_id))
            .map(|record| (record.state, record.ack_deadline))
    }
}

fn fail_ordered_channel(store: &mut DeliveryStore, scope: &(String, String)) -> HashSet<DedupKey> {
    let mut affected = HashSet::new();
    if let Some(ordered) = store.ordered.remove(scope) {
        if let Some(message_id) = ordered.in_flight {
            affected.insert(dedup_key(&scope.0, &scope.1, message_id));
        }
        for message in ordered.reorder_buffer.into_values() {
            affected.insert(dedup_key(
                &message.peer_id,
                &message.channel_id,
                message.message_id,
            ));
        }
    }
    for key in store
        .incoming_active
        .keys()
        .filter(|key| key.peer_id == scope.0 && key.channel_id == scope.1)
        .cloned()
        .collect::<Vec<_>>()
    {
        affected.insert(key);
    }
    for key in &affected {
        store.incoming_active.remove(key);
    }
    store.failed_ordered.insert(scope.clone());
    affected
}

fn expire_incoming_locked(
    store: &mut DeliveryStore,
    now: Instant,
    peer_id: Option<&str>,
) -> Vec<IncomingTimeout> {
    let timed_out = store
        .incoming_active
        .iter()
        .filter_map(|(key, record)| {
            if !peer_id.is_none_or(|peer| key.peer_id == peer) {
                return None;
            }
            match record.state {
                ActiveIncomingState::InFlight => {
                    debug_assert!(
                        record.ack_deadline.is_some(),
                        "in-flight record is missing its application ACK deadline"
                    );
                    record
                        .ack_deadline
                        .filter(|deadline| now >= *deadline)
                        .map(|_| (key.clone(), *record))
                }
                ActiveIncomingState::OrderedBuffered => {
                    debug_assert!(
                        record.ack_deadline.is_none(),
                        "ordered buffered record must not have an application ACK deadline"
                    );
                    None
                }
            }
        })
        .collect::<Vec<_>>();
    let mut ordered_scopes = HashSet::new();
    let mut expired = Vec::new();
    for (key, record) in timed_out {
        let scope = (key.peer_id.clone(), key.channel_id.clone());
        let is_ordered = record.state == ActiveIncomingState::OrderedBuffered
            || store
                .ordered
                .get(&scope)
                .is_some_and(|ordered| ordered.in_flight == Some(key.message_id));
        if is_ordered {
            ordered_scopes.insert(scope);
        } else if store.incoming_active.remove(&key).is_some() {
            expired.push(IncomingTimeout {
                peer_id: key.peer_id,
                channel_id: key.channel_id,
                message_id: key.message_id,
                ordered_channel_failed: false,
            });
        }
    }
    for scope in ordered_scopes {
        let affected = fail_ordered_channel(store, &scope);
        for key in affected {
            expired.push(IncomingTimeout {
                peer_id: key.peer_id,
                channel_id: key.channel_id,
                message_id: key.message_id,
                ordered_channel_failed: true,
            });
        }
    }
    expired
}
