use super::*;

/// A Ready frame is the authority for the candidate-cache freshness window.
/// When a control reconnect reports a different server-confirmed TTL, entries
/// learned under the previous control lease must not remain eligible for Stage
/// A. They are rebuilt by the next authoritative Resolve/Answer snapshot.
pub(crate) async fn clear_remote_candidate_cache_if_ready_ttl_changed(
    state: &RuntimeState,
    previous_ttl: Option<Duration>,
    current_ttl: Option<Duration>,
) {
    if previous_ttl == current_ttl {
        return;
    }
    let mut cache = state.remote_candidate_cache.write().await;
    if !cache.is_empty() {
        tracing::debug!(
            ?previous_ttl,
            ?current_ttl,
            entries = cache.len(),
            "clearing remote candidate cache after Relay Ready TTL change"
        );
        cache.clear();
    }
}

/// Apply the server-advertised runtime epoch to the real per-peer candidate
/// cache. Presence remains UI-only; the epoch carried by the v2 hint is the
/// explicit invalidation signal for the old remote discovery snapshot.
pub(crate) async fn invalidate_remote_candidate_cache_for_epoch(
    state: &RuntimeState,
    peer_id: &str,
    epoch: &RuntimeEpoch,
) {
    if epoch.high == 0 && epoch.low == 0 {
        tracing::debug!(
            peer_id = %peer_id,
            "ignored available hint with zero runtime_epoch for candidate invalidation"
        );
        return;
    }
    let remote_epoch = NatRuntimeEpoch {
        high: epoch.high,
        low: epoch.low,
    };
    let mut cache = state.remote_candidate_cache.write().await;
    let Some(entry) = cache.get_mut(peer_id) else {
        return;
    };
    if entry.invalidate_for_remote_epoch(remote_epoch, Instant::now()) {
        tracing::debug!(
            peer_id = %peer_id,
            runtime_epoch_high = epoch.high,
            runtime_epoch_low = epoch.low,
            "invalidated remote candidate cache for new runtime epoch"
        );
    }
}

/// Starts the responder half of a one-shot connectivity attempt. The
/// initiator's snapshot is copied into an attempt-scoped candidate set; no
/// candidate is written to PathManager or reused by a later attempt.
pub(crate) fn spawn_responder_connectivity_checks(
    state: Arc<RuntimeState>,
    offer: ConnectivityOffer,
) {
    let supervisor = Arc::clone(&state.task_supervisor);
    let _ = supervisor.spawn_runtime("connectivity-responder-checks", async move {
        let peer_id = offer.initiator_device_id.clone();
        let peer = state.peers.read().await.get(&peer_id).cloned();
        let Some(peer) = peer else {
            tracing::debug!(peer_id = %peer_id, attempt_id = %offer.attempt_id, "ignored offer for unconfigured peer");
            return;
        };
        if !state
            .route_is_authorized(&peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            tracing::debug!(
                peer_id = %peer_id,
                attempt_id = %offer.attempt_id,
                "ignored connectivity offer without Direct route authorization"
            );
            return;
        }
        let endpoint = state.lifecycle.endpoint.read().await.clone();
        let Some(endpoint) = endpoint else {
            tracing::debug!(peer_id = %peer_id, attempt_id = %offer.attempt_id, "cannot run responder checks without endpoint");
            return;
        };
        let identity = state.lifecycle.identity.read().await.clone();
        let Some(identity) = identity else {
            return;
        };
        let mut candidates = connectivity_offer_candidates(&offer);
        if let Some(configured_endpoint) = peer.endpoint {
            if !candidates
                .iter()
                .any(|candidate| candidate.endpoint == configured_endpoint)
            {
                candidates.push(Candidate::new(
                    configured_endpoint,
                    crate::peer::candidate_kind_for(configured_endpoint),
                    "peer-configured".into(),
                ));
            }
        }
        let local_epoch = state
            .local_discovery
            .read()
            .await
            .as_ref()
            .map(|manager| {
                let epoch = manager.runtime_epoch();
                NatRuntimeEpoch {
                    high: epoch.high,
                    low: epoch.low,
                }
            })
            .unwrap_or(NatRuntimeEpoch { high: 0, low: 0 });
        let mut attempt = ConnectivityAttempt::with_connect_window(
            offer.attempt_id.clone(),
            peer_id.clone(),
            local_epoch,
            SystemTime::now(),
            crate::connect::DIRECT_CONNECT_WINDOW,
        );
        let _ = attempt.apply_remote_candidates(
            offer
                .initiator_runtime_epoch
                .as_ref()
                .map(|epoch| NatRuntimeEpoch {
                    high: epoch.high,
                    low: epoch.low,
                }),
            u64::from(offer.initiator_revision),
            candidates.clone(),
        );
        let _ = attempt.set_state(ConnectivityAttemptState::Resolved);
        let _ = attempt.set_state(ConnectivityAttemptState::Coordinating);
        let _ = attempt.set_state(ConnectivityAttemptState::Connecting);
        let digest = Sha256::digest(offer.attempt_id.as_bytes());
        let session_binding = hex::encode(&digest[..16]);
        let result = crate::peer::connect_responder_direct(
            endpoint,
            candidates,
            identity,
            peer.identity_public_key,
            peer_id.clone(),
            offer.attempt_id.clone(),
            session_binding,
            Arc::clone(&state),
            crate::connect::DIRECT_CONNECT_WINDOW,
        )
        .await;
        match result {
            Ok(route) => {
                let _ = attempt.set_state(ConnectivityAttemptState::Succeeded);
                let attempt_coordinator =
                    crate::connect::ConnectivityAttemptCoordinator::new(state);
                if let Err(error) = attempt_coordinator
                    .attach_direct_route(&peer_id, route)
                    .await
                {
                    tracing::debug!(peer_id = %peer_id, attempt_id = %offer.attempt_id, error = %error.message, "responder direct route was not attached");
                }
            }
            Err(error) => {
                let _ = attempt.set_state(if error.code == network_protocol::NetworkErrorCode::Timeout as i32 {
                    ConnectivityAttemptState::Expired
                } else {
                    ConnectivityAttemptState::Failed
                });
                tracing::debug!(peer_id = %peer_id, attempt_id = %offer.attempt_id, error = %error.message, "responder direct checks failed");
            }
        }
    });
}

pub(crate) fn connectivity_offer_candidates(offer: &ConnectivityOffer) -> Vec<Candidate> {
    offer
        .initiator_snapshot
        .as_ref()
        .and_then(|snapshot| snapshot.candidate_bundle.as_ref())
        .into_iter()
        .flat_map(|bundle| bundle.candidates.iter())
        .filter_map(|bytes| serde_json::from_slice::<CandidateAdvertisement>(bytes).ok())
        .filter_map(|advertisement| Candidate::from_advertisement(advertisement).ok())
        .collect()
}

/// 读取本地 Discovery 三元组（epoch / revision / snapshot），供 offer/answer 附带。
pub(crate) async fn local_discovery_tuple(
    state: &RuntimeState,
) -> (RuntimeEpoch, u32, Option<DiscoverySnapshot>) {
    let Some(manager) = state.local_discovery.read().await.clone() else {
        return (RuntimeEpoch { high: 0, low: 0 }, 1, None);
    };
    (
        manager.runtime_epoch(),
        manager.revision(),
        Some(manager.snapshot()),
    )
}
