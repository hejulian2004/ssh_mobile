//! Provisional screen-share bindings and their expiry worker.
use super::*;
use crate::runtime::RuntimeState;
use std::time::Duration;

impl ProvisionalScreenShareBinding {
    pub(crate) fn is_expired(&self, now_ms: u64) -> bool {
        now_ms >= self.binding_expires_at_ms || now_ms >= self.effective_expires_at_ms
    }

    pub(crate) fn push_ice(
        &mut self,
        revision: u64,
        payload: Vec<u8>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if revision != self.offer_revision {
            return Err(boxed_message("stale provisional ICE revision"));
        }
        if payload.len() > MAX_PROVISIONAL_ICE_CANDIDATE_BYTES {
            return Err(boxed_message("provisional ICE candidate is outside bounds"));
        }
        if self.ice_candidates.len() >= MAX_PROVISIONAL_ICE_CANDIDATES
            || self.ice_total_bytes.saturating_add(payload.len()) > MAX_PROVISIONAL_ICE_TOTAL_BYTES
        {
            return Err(boxed_message("provisional ICE queue is outside bounds"));
        }
        if self
            .ice_candidates
            .iter()
            .any(|candidate| candidate.revision == revision && candidate.payload == payload)
        {
            return Err(boxed_message("replayed provisional ICE candidate"));
        }
        self.ice_total_bytes = self.ice_total_bytes.saturating_add(payload.len());
        self.ice_candidates
            .push_back(ProvisionalIceCandidate { revision, payload });
        Ok(())
    }
}

impl RealtimeManager {
    pub(crate) fn next_provisional_epoch(&mut self) -> u64 {
        self.next_provisional_epoch = self.next_provisional_epoch.wrapping_add(1);
        if self.next_provisional_epoch == 0 {
            self.next_provisional_epoch = 1;
        }
        self.next_provisional_epoch
    }

    pub(crate) fn provisional_slot_count(&self) -> usize {
        self.provisional
            .keys()
            .chain(self.provisional_requests.keys())
            .collect::<HashSet<_>>()
            .len()
    }

    pub(crate) fn wake_provisional_expiry(&self) {
        // There is exactly one supervised provisional-expiry worker. Keep a
        // permit when a deadline changes while the worker is between creating
        // the waiter and reading the manager, so an earlier entry cannot lose
        // its wake-up.
        self.provisional_expiry_wake.notify_one();
    }

    fn next_provisional_expiry(&self) -> Option<(String, u64, Instant)> {
        self.provisional
            .iter()
            .map(|(realtime_id, binding)| {
                (
                    realtime_id.clone(),
                    binding.provisional_epoch,
                    binding.expiry_deadline,
                )
            })
            .chain(
                self.provisional_requests
                    .iter()
                    .map(|(realtime_id, request)| {
                        (
                            realtime_id.clone(),
                            request.provisional_epoch,
                            request.expiry_deadline,
                        )
                    }),
            )
            .min_by_key(|(_, _, deadline)| *deadline)
    }

    fn current_provisional_epoch(&self, realtime_id: &str) -> Option<u64> {
        self.provisional
            .get(realtime_id)
            .map(|binding| binding.provisional_epoch)
            .or_else(|| {
                self.provisional_requests
                    .get(realtime_id)
                    .map(|request| request.provisional_epoch)
            })
    }

    fn prune_replay_cache(&mut self, now_ms: u64) {
        self.provisional_replay_cache.retain(|_, entries| {
            entries.retain(|entry| entry.expires_at_ms > now_ms);
            !entries.is_empty()
        });
    }

    pub(crate) fn remember_provisional_action(
        &mut self,
        key: ProvisionalReplayKey,
        now_ms: u64,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.prune_replay_cache(now_ms);
        let peer_entries = self
            .provisional_replay_cache
            .entry(key.sender_peer_id.clone())
            .or_default();
        if peer_entries.iter().any(|entry| entry.key == key) {
            return Err(boxed_message("replayed provisional screen-share action"));
        }
        if peer_entries.len() >= MAX_PROVISIONAL_REPLAY_KEYS_PER_PEER {
            return Err(boxed_message("provisional replay cache is full"));
        }
        peer_entries.push_back(ProvisionalReplayEntry {
            key,
            expires_at_ms: now_ms.saturating_add(PROVISIONAL_REPLAY_TTL_MS),
        });
        Ok(())
    }

    pub(crate) fn latest_provisional_action_revision(
        &self,
        sender_peer_id: &str,
        realtime_id: &str,
        operation_id: &str,
    ) -> Option<u64> {
        self.provisional_replay_cache
            .get(sender_peer_id)
            .and_then(|entries| {
                entries
                    .iter()
                    .filter(|entry| {
                        entry.key.realtime_id == realtime_id
                            && entry.key.operation_id == operation_id
                    })
                    .map(|entry| entry.key.action_revision)
                    .max()
            })
    }
}

pub(crate) fn provisional_deadline(now_ms: u64, expires_at_ms: u64) -> Instant {
    Instant::now() + Duration::from_millis(expires_at_ms.saturating_sub(now_ms))
}

/// The provisional registry has an independent runtime task namespace. It is
/// intentionally not a `realtime-io` session task: before claim there is no
/// formal RealtimeSession to own this resource, and expiry must remain alive
/// while the control plane is otherwise quiet.
pub(crate) async fn ensure_provisional_expiry_worker(
    state: &Arc<RuntimeState>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (wake, should_spawn) = {
        let mut manager = state.realtime.lock().await;
        if manager.provisional_expiry_worker_started {
            (Arc::clone(&manager.provisional_expiry_wake), false)
        } else {
            manager.provisional_expiry_worker_started = true;
            (Arc::clone(&manager.provisional_expiry_wake), true)
        }
    };
    if !should_spawn {
        return Ok(());
    }
    let worker_state = Arc::clone(state);
    if state
        .task_supervisor
        .spawn_runtime(
            "provisional-expiry",
            run_provisional_expiry_worker(worker_state, wake),
        )
        .is_none()
    {
        state
            .realtime
            .lock()
            .await
            .provisional_expiry_worker_started = false;
        return Err(boxed_message(
            "runtime task supervisor is stopping provisional expiry",
        ));
    }
    Ok(())
}

pub(crate) async fn run_provisional_expiry_worker(state: Arc<RuntimeState>, wake: Arc<Notify>) {
    loop {
        let notified = wake.notified();
        let expiry = state.realtime.lock().await.next_provisional_expiry();
        match expiry {
            Some((realtime_id, provisional_epoch, deadline)) => {
                tokio::select! {
                    _ = notified => {}
                    _ = tokio::time::sleep_until(deadline) => {
                        let now_ms = crate::events::unix_timestamp_ms().max(0) as u64;
                        let now = Instant::now();
                        let mut manager = state.realtime.lock().await;
                        if manager.current_provisional_epoch(&realtime_id)
                            == Some(provisional_epoch)
                            && manager
                                .provisional
                                .get(&realtime_id)
                                .map(|binding| binding.expiry_deadline <= now)
                                .or_else(|| {
                                    manager
                                        .provisional_requests
                                        .get(&realtime_id)
                                        .map(|request| request.expiry_deadline <= now)
                                })
                                == Some(true)
                        {
                            if let Some(mut binding) = manager.provisional.remove(&realtime_id) {
                                binding.state = ProvisionalBindingState::Terminal;
                            }
                            manager.provisional_requests.remove(&realtime_id);
                        }
                        manager.prune_replay_cache(now_ms);
                    }
                }
            }
            None => notified.await,
        }
    }
}

pub(crate) fn prune_provisional_bindings(manager: &mut RealtimeManager, now_ms: u64) {
    let expired = manager
        .provisional
        .iter()
        .filter(|(_, binding)| binding.is_expired(now_ms))
        .map(|(realtime_id, _)| realtime_id.clone())
        .collect::<Vec<_>>();
    let mut removed = !expired.is_empty();
    for realtime_id in expired {
        if let Some(mut binding) = manager.provisional.remove(&realtime_id) {
            binding.state = ProvisionalBindingState::Terminal;
        }
    }
    let before_requests = manager.provisional_requests.len();
    manager
        .provisional_requests
        .retain(|_, request| request.expires_at_ms > now_ms);
    removed |= before_requests != manager.provisional_requests.len();
    if removed {
        manager.wake_provisional_expiry();
    }
}
