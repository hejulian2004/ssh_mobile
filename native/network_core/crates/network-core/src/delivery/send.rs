use super::*;

impl DeliveryManager {
    /// 入队逻辑 payload，并分配永不随 Connection 重置的 Channel Sequence。
    ///
    /// `peer_id` 是业务作用域（对端设备标识），不是任何 Connection 的
    /// SessionId；它跨 Connection 稳定，保证未 ACK 消息在新连接上恢复。
    pub async fn enqueue(
        &self,
        peer_id: &str,
        channel_id: &str,
        payload: Vec<u8>,
        policy: DeliveryPolicy,
        retry_policy: RetryPolicy,
    ) -> Result<PendingMessage, DeliveryError> {
        self.enqueue_at_inner(
            peer_id,
            channel_id,
            payload,
            policy,
            retry_policy,
            Instant::now(),
        )
        .await
    }

    #[cfg(test)]
    pub(super) async fn enqueue_at(
        &self,
        peer_id: &str,
        channel_id: &str,
        payload: Vec<u8>,
        policy: DeliveryPolicy,
        retry_policy: RetryPolicy,
        now: Instant,
    ) -> Result<PendingMessage, DeliveryError> {
        self.enqueue_at_inner(peer_id, channel_id, payload, policy, retry_policy, now)
            .await
    }

    async fn enqueue_at_inner(
        &self,
        peer_id: &str,
        channel_id: &str,
        payload: Vec<u8>,
        policy: DeliveryPolicy,
        retry_policy: RetryPolicy,
        now: Instant,
    ) -> Result<PendingMessage, DeliveryError> {
        if !is_valid_scope_id(peer_id) || !is_valid_scope_id(channel_id) {
            return Err(DeliveryError::InvalidScope);
        }
        if payload.len() > self.config.max_payload_bytes {
            return Err(DeliveryError::PayloadTooLarge);
        }
        if !retry_policy.is_valid() {
            return Err(DeliveryError::InvalidRetryPolicy);
        }

        let mut store = self.store.lock().await;
        if policy == DeliveryPolicy::LatestState {
            let obsolete = store
                .pending
                .iter()
                .filter(|(_, message)| {
                    message.peer_id == peer_id
                        && message.channel_id == channel_id
                        && message.policy == DeliveryPolicy::LatestState
                })
                .map(|(identity, _)| identity.clone())
                .collect::<Vec<_>>();
            for identity in obsolete {
                if remove_pending(&mut store, &identity).is_some() {
                    record_terminal(&mut store, identity, DeliveryTerminalOutcome::Cancelled);
                }
            }
        }
        if policy != DeliveryPolicy::BestEffort
            && (store.pending.len() >= self.config.max_pending_messages
                || store.pending_bytes.saturating_add(payload.len())
                    > self.config.max_pending_bytes)
        {
            return Err(DeliveryError::QueueFull);
        }

        let sequence_key = (peer_id.to_string(), channel_id.to_string());
        let sequence = store.next_sequences.entry(sequence_key).or_insert(0);
        let message_sequence = *sequence;
        *sequence = sequence.saturating_add(1);
        let recovery_epoch = store
            .recovery_epochs
            .get(peer_id)
            .copied()
            .unwrap_or_default();
        let message_id = next_message_id(peer_id, &store.pending, &store.terminal_outcomes);
        let message = PendingMessage {
            message_id,
            peer_id: peer_id.to_string(),
            channel_id: channel_id.to_string(),
            sequence: message_sequence,
            payload,
            policy,
            state: DeliveryState::Queued,
            attempts: 0,
            created_at: now,
            expires_at: retry_policy.ttl.map(|ttl| now + ttl),
            recovery_epoch,
            retry_policy,
            next_retry_at: now,
            retry_bytes: 0,
        };
        if policy != DeliveryPolicy::BestEffort {
            store.pending_bytes += message.payload.len();
            store.pending.insert(
                DeliveryIdentity {
                    peer_id: peer_id.to_string(),
                    message_id,
                },
                message.clone(),
            );
        }
        Ok(message)
    }

    /// 取出一个可发送消息并消耗一次 retry attempt。
    pub async fn begin_send(
        &self,
        message_id: MessageId,
        now: Instant,
    ) -> Result<Option<PendingMessage>, DeliveryError> {
        self.begin_send_inner(None, message_id, now).await
    }

    /// Peer-scoped form of [`Self::begin_send`].  A caller that owns a
    /// business operation must provide the peer identity explicitly; a
    /// MessageId alone is not sufficient to claim a send lease.
    pub(crate) async fn begin_send_for_peer(
        &self,
        peer_id: &str,
        message_id: MessageId,
        now: Instant,
    ) -> Result<Option<DeliverySendAttempt>, DeliveryError> {
        if !is_valid_peer_id(peer_id) {
            return Err(DeliveryError::InvalidScope);
        }
        let message = self
            .begin_send_inner(Some(peer_id), message_id, now)
            .await?;
        Ok(message.map(|message| DeliverySendAttempt {
            peer_id: peer_id.to_string(),
            message_id,
            attempt: message.attempts,
            message,
        }))
    }

    async fn begin_send_inner(
        &self,
        expected_peer_id: Option<&str>,
        message_id: MessageId,
        now: Instant,
    ) -> Result<Option<PendingMessage>, DeliveryError> {
        let mut store = self.store.lock().await;
        if let Some(peer_id) = expected_peer_id {
            let scoped_identity = DeliveryIdentity {
                peer_id: peer_id.to_string(),
                message_id,
            };
            if !store.pending.contains_key(&scoped_identity)
                && store
                    .pending
                    .keys()
                    .any(|identity| identity.message_id == message_id)
            {
                return Err(DeliveryError::InvalidScope);
            }
        }
        let Some(identity) = resolve_pending_identity(&store, expected_peer_id, message_id) else {
            return Err(DeliveryError::NotFound);
        };
        let Some(existing) = store.pending.get(&identity) else {
            return Err(DeliveryError::NotFound);
        };
        if is_expired(existing, now) {
            remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Expired);
            return Err(DeliveryError::Expired);
        }
        let Some(message) = store.pending.get_mut(&identity) else {
            return Err(DeliveryError::NotFound);
        };
        if matches!(message.state, DeliveryState::Sending) {
            return Ok(None);
        }
        if message.state == DeliveryState::SentUnacked && now < message.next_retry_at {
            return Ok(None);
        }
        if message.state != DeliveryState::Queued && message.state != DeliveryState::SentUnacked {
            return Ok(None);
        }
        if now < message.next_retry_at {
            return Ok(None);
        }
        let next_attempt = message.attempts.saturating_add(1);
        if next_attempt > message.retry_policy.max_attempts {
            message.state = DeliveryState::Failed;
            let _ = remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Failed);
            return Err(DeliveryError::RetryExhausted);
        }
        let retry_bytes = message
            .retry_bytes
            .saturating_add(u64::from(next_attempt > 1) * message.payload.len() as u64);
        if message
            .retry_policy
            .max_total_retry_bytes
            .is_some_and(|limit| retry_bytes > limit)
        {
            message.state = DeliveryState::Failed;
            let _ = remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Failed);
            return Err(DeliveryError::RetryExhausted);
        }
        message.attempts = next_attempt;
        message.retry_bytes = retry_bytes;
        message.state = DeliveryState::Sending;
        Ok(Some(message.clone()))
    }

    /// 传输层成功写出消息后等待应用 ACK。
    pub async fn mark_sent(&self, message_id: MessageId, now: Instant) -> bool {
        self.mark_sent_inner(None, None, message_id, now).await
    }

    pub(crate) async fn mark_sent_for_attempt(
        &self,
        attempt: &DeliverySendAttempt,
        now: Instant,
    ) -> bool {
        self.mark_sent_inner(
            Some(&attempt.peer_id),
            Some(attempt.attempt),
            attempt.message_id,
            now,
        )
        .await
    }

    async fn mark_sent_inner(
        &self,
        expected_peer_id: Option<&str>,
        expected_attempt: Option<u32>,
        message_id: MessageId,
        now: Instant,
    ) -> bool {
        let mut store = self.store.lock().await;
        let Some(identity) = resolve_pending_identity(&store, expected_peer_id, message_id) else {
            return false;
        };
        let Some(message) = store.pending.get_mut(&identity) else {
            return false;
        };
        if message.state != DeliveryState::Sending
            || expected_attempt.is_some_and(|attempt| message.attempts != attempt)
        {
            return false;
        }
        message.state = DeliveryState::SentUnacked;
        message.next_retry_at = now + message.retry_policy.delay_for_attempt(message.attempts);
        true
    }

    /// 传输层写失败后回到 Pending，或耗尽预算进入 Failed。
    pub async fn mark_send_failed(&self, message_id: MessageId, now: Instant) -> RetryDecision {
        self.mark_send_failed_inner(None, None, message_id, now)
            .await
    }

    pub(crate) async fn mark_send_failed_for_attempt(
        &self,
        attempt: &DeliverySendAttempt,
        now: Instant,
    ) -> RetryDecision {
        self.mark_send_failed_inner(
            Some(&attempt.peer_id),
            Some(attempt.attempt),
            attempt.message_id,
            now,
        )
        .await
    }

    async fn mark_send_failed_inner(
        &self,
        expected_peer_id: Option<&str>,
        expected_attempt: Option<u32>,
        message_id: MessageId,
        now: Instant,
    ) -> RetryDecision {
        let mut store = self.store.lock().await;
        let Some(identity) = resolve_pending_identity(&store, expected_peer_id, message_id) else {
            return RetryDecision::NotFound;
        };
        let Some(existing) = store.pending.get(&identity) else {
            return RetryDecision::NotFound;
        };
        if is_expired(existing, now) {
            remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Expired);
            return RetryDecision::Expired;
        }
        let Some(message) = store.pending.get_mut(&identity) else {
            return RetryDecision::NotFound;
        };
        // A result may arrive after recovery invalidated its lease.  Do not let
        // that stale result requeue or fail a newer attempt.
        if expected_attempt.is_some()
            && (message.state != DeliveryState::Sending
                || expected_attempt.is_some_and(|attempt| message.attempts != attempt))
        {
            return RetryDecision::NotFound;
        }
        if message.attempts >= message.retry_policy.max_attempts
            || message
                .retry_policy
                .max_total_retry_bytes
                .is_some_and(|limit| {
                    message
                        .retry_bytes
                        .saturating_add(message.payload.len() as u64)
                        > limit
                })
        {
            message.state = DeliveryState::Failed;
            remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Failed);
            return RetryDecision::Failed;
        }
        message.state = DeliveryState::Queued;
        message.next_retry_at = now + message.retry_policy.delay_for_attempt(message.attempts);
        RetryDecision::RetryAt(message.next_retry_at)
    }

    /// 按 MessageId 关联 ACK（§20）。一个 ACK 只要是当前作用域中已知的
    /// in-flight MessageId 就有效；已完成 / 未知 MessageId 的 ACK 是 no-op。
    ///
    /// 不再携带 recovery_epoch 门控——连接换代后发送端以同一个 MessageId 重发，
    /// ACK 只需按 MessageId 匹配即可完成。
    pub async fn acknowledge(&self, peer_id: &str, message_id: MessageId) -> AckResult {
        if !is_valid_peer_id(peer_id) {
            return AckResult::Unknown;
        }
        let mut store = self.store.lock().await;
        let identity = DeliveryIdentity {
            peer_id: peer_id.to_string(),
            message_id,
        };
        if !store.pending.contains_key(&identity) {
            return AckResult::Unknown;
        }
        remove_pending(&mut store, &identity);
        record_terminal(&mut store, identity, DeliveryTerminalOutcome::Acknowledged);
        AckResult::Acknowledged
    }

    /// Return the terminal outcome only when the caller supplies the owning
    /// peer.  This keeps a MessageId from becoming a cross-peer capability.
    #[allow(dead_code)]
    pub(crate) async fn terminal_outcome(
        &self,
        peer_id: &str,
        message_id: MessageId,
    ) -> Option<DeliveryTerminalOutcome> {
        if !is_valid_peer_id(peer_id) {
            return None;
        }
        let store = self.store.lock().await;
        let identity = DeliveryIdentity {
            peer_id: peer_id.to_string(),
            message_id,
        };
        store.terminal_outcomes.get(&identity).copied()
    }

    #[cfg(test)]
    pub(super) async fn pending_len(&self) -> usize {
        self.store.lock().await.pending.len()
    }
}
