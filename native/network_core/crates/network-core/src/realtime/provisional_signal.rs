//! Provisional Offer, ICE, and screen-share consent pairing.
use super::*;
use crate::runtime::RuntimeState;
use network_protocol::ScreenShareConsentDecision;
use network_webrtc::{DescriptionType, SessionDescription};

/// Handles signals for a realtime ID that has not yet been accepted locally.
///
/// This path is deliberately native-only. An Offer and its trickled ICE are
/// retained in a bounded provisional binding, while the typed REQUEST is held
/// separately until both halves can be paired. No responder PeerConnection,
/// Answer, formal SDK session, or media resource is created here.
pub(crate) async fn handle_provisional_realtime_signal(
    state: &Arc<RuntimeState>,
    kind: RealtimeSignalKind,
    realtime_id: &str,
    authenticated_peer_id: &str,
    revision: u64,
    shared_session_instance_id: String,
    payload: Vec<u8>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    validate_realtime_id(realtime_id).map_err(boxed_protocol_error)?;
    validate_shared_session_instance_id(&shared_session_instance_id)?;
    validate_peer(state, authenticated_peer_id)
        .await
        .map_err(boxed_protocol_error)?;
    validate_signal(kind, revision, &payload).map_err(boxed_protocol_error)?;
    ensure_provisional_expiry_worker(state).await?;
    let local_device_id = state
        .lifecycle
        .identity
        .read()
        .await
        .as_ref()
        .map(|identity| identity.device_id.clone())
        .ok_or_else(|| boxed_message("local realtime identity is unavailable"))?;

    // The v2 dispatcher chooses the provisional path from an initial registry
    // lookup. A responder claim can register the exact session after that
    // lookup but before this handler acquires the manager lock. Re-check the
    // formal binding here so a concurrently arriving ICE/close/consent signal
    // cannot fall through the claim transition and be rejected or stranded.
    let formal_binding = {
        let manager = state.realtime.lock().await;
        manager.sessions.get(realtime_id).map(|session| {
            (
                session.peer_id.clone(),
                session.shared_session_instance_id.clone(),
            )
        })
    };
    if let Some((formal_peer_id, formal_shared_session_instance_id)) = formal_binding {
        if formal_peer_id != authenticated_peer_id
            || formal_shared_session_instance_id != shared_session_instance_id
        {
            return Err(boxed_message(
                "provisional signal conflicts with formal realtime binding",
            ));
        }
        return handle_realtime_signal(
            state,
            kind,
            realtime_id,
            authenticated_peer_id,
            revision,
            shared_session_instance_id,
            payload,
        )
        .await;
    }

    let now_ms = crate::events::unix_timestamp_ms().max(0) as u64;
    let mut publish: Option<(
        String,
        String,
        String,
        String,
        String,
        u64,
        ScreenShareConsentV2,
    )> = None;
    let mut manager = state.realtime.lock().await;
    prune_provisional_bindings(&mut manager, now_ms);

    match kind {
        RealtimeSignalKind::WebRtcOffer => {
            let sdp = String::from_utf8(payload.clone())
                .map_err(|error| boxed_message(error.to_string()))?;
            SessionDescription::new(DescriptionType::Offer, sdp)
                .map_err(|error| boxed_message(error.to_string()))?;
            if let Some(existing) = manager.provisional.get(realtime_id) {
                if existing.authenticated_peer_id == authenticated_peer_id
                    && existing.shared_session_instance_id == shared_session_instance_id
                    && existing.offer_revision == revision
                    && existing.offer_payload == payload
                {
                    return Ok(());
                }
                return Err(boxed_message("conflicting provisional realtime Offer"));
            }
            if let Some(existing) = manager.provisional_requests.get(realtime_id) {
                if existing.authenticated_peer_id != authenticated_peer_id
                    || existing.shared_session_instance_id != shared_session_instance_id
                {
                    return Err(boxed_message(
                        "provisional Offer conflicts with authenticated REQUEST",
                    ));
                }
            }
            if manager.provisional_slot_count() >= MAX_PROVISIONAL_OPERATIONS
                && !manager.provisional_requests.contains_key(realtime_id)
            {
                return Err(boxed_message("too many provisional realtime operations"));
            }
            let binding_expires_at_ms = now_ms.saturating_add(MAX_PROVISIONAL_BINDING_LIFETIME_MS);
            let provisional_epoch = manager
                .provisional_requests
                .get(realtime_id)
                .map(|pending| pending.provisional_epoch)
                .unwrap_or_else(|| manager.next_provisional_epoch());
            let mut binding = ProvisionalScreenShareBinding {
                provisional_epoch,
                offer_id: new_shared_session_instance_id(),
                claim_token: new_shared_session_instance_id(),
                authenticated_peer_id: authenticated_peer_id.to_owned(),
                realtime_id: realtime_id.to_owned(),
                shared_session_instance_id: shared_session_instance_id.clone(),
                offer_revision: revision,
                offer_payload: payload,
                ice_candidates: VecDeque::new(),
                ice_total_bytes: 0,
                request: None,
                binding_expires_at_ms,
                effective_expires_at_ms: binding_expires_at_ms,
                expiry_deadline: provisional_deadline(now_ms, binding_expires_at_ms),
                published_to_app: false,
                state: ProvisionalBindingState::Pending,
            };
            if let Some(pending) = manager.provisional_requests.remove(realtime_id) {
                binding.provisional_epoch = pending.provisional_epoch;
                binding.effective_expires_at_ms = binding_expires_at_ms.min(pending.expires_at_ms);
                binding.expiry_deadline =
                    provisional_deadline(now_ms, binding.effective_expires_at_ms);
                binding.request = Some(pending.request);
            }
            let should_publish = binding.request.is_some();
            if let Some(request) = binding.request.as_ref() {
                publish = Some((
                    binding.offer_id.clone(),
                    binding.claim_token.clone(),
                    binding.realtime_id.clone(),
                    binding.authenticated_peer_id.clone(),
                    binding.shared_session_instance_id.clone(),
                    binding.effective_expires_at_ms,
                    request.clone(),
                ));
            }
            binding.published_to_app = should_publish;
            manager.provisional.insert(realtime_id.to_owned(), binding);
            manager.wake_provisional_expiry();
        }
        RealtimeSignalKind::IceCandidate => {
            let Some(binding) = manager.provisional.get_mut(realtime_id) else {
                return Err(boxed_message("provisional realtime Offer is missing"));
            };
            if binding.authenticated_peer_id != authenticated_peer_id
                || binding.shared_session_instance_id != shared_session_instance_id
                || matches!(
                    binding.state,
                    ProvisionalBindingState::Claimed | ProvisionalBindingState::Terminal
                )
            {
                return Err(boxed_message("provisional ICE binding mismatch"));
            }
            binding.push_ice(revision, payload)?;
        }
        RealtimeSignalKind::ScreenShareConsent => {
            let existing_binding = manager.provisional.get(realtime_id);
            let expected_shared = existing_binding
                .map(|binding| binding.shared_session_instance_id.as_str())
                .unwrap_or(shared_session_instance_id.as_str());
            let consent = validate_screen_share_consent(
                &payload,
                realtime_id,
                Some(authenticated_peer_id),
                Some(expected_shared),
            )?;
            match ScreenShareConsentDecision::try_from(consent.decision)
                .map_err(|_| boxed_message("unknown screen-share consent decision"))?
            {
                ScreenShareConsentDecision::Request => {
                    if consent.action_revision != 1 {
                        return Err(boxed_message(
                            "initial screen-share REQUEST revision is invalid",
                        ));
                    }
                    let replay_key = ProvisionalReplayKey {
                        sender_peer_id: authenticated_peer_id.to_owned(),
                        target_device_id: local_device_id.clone(),
                        realtime_id: realtime_id.to_owned(),
                        operation_id: consent.operation_id.clone(),
                        decision: consent.decision,
                        action_revision: consent.action_revision,
                    };
                    if manager.provisional.contains_key(realtime_id) {
                        let binding = manager
                            .provisional
                            .get(realtime_id)
                            .expect("provisional binding exists");
                        if binding.authenticated_peer_id != authenticated_peer_id
                            || binding.shared_session_instance_id
                                != consent.shared_session_instance_id
                            || matches!(
                                binding.state,
                                ProvisionalBindingState::Claimed
                                    | ProvisionalBindingState::Terminal
                            )
                        {
                            return Err(boxed_message("screen-share REQUEST binding mismatch"));
                        }
                        if let Some(existing) = binding.request.as_ref() {
                            if existing.operation_id != consent.operation_id
                                || existing.action_revision != consent.action_revision
                            {
                                return Err(boxed_message("conflicting provisional REQUEST"));
                            }
                            return Err(boxed_message("replayed provisional screen-share REQUEST"));
                        }
                        manager.remember_provisional_action(replay_key, now_ms)?;
                        let binding = manager
                            .provisional
                            .get_mut(realtime_id)
                            .expect("provisional binding exists");
                        binding.effective_expires_at_ms =
                            binding.effective_expires_at_ms.min(consent.expires_at_ms);
                        binding.expiry_deadline =
                            provisional_deadline(now_ms, binding.effective_expires_at_ms);
                        binding.request = Some(consent.clone());
                        if !binding.published_to_app {
                            binding.published_to_app = true;
                            publish = Some((
                                binding.offer_id.clone(),
                                binding.claim_token.clone(),
                                binding.realtime_id.clone(),
                                binding.authenticated_peer_id.clone(),
                                binding.shared_session_instance_id.clone(),
                                binding.effective_expires_at_ms,
                                consent,
                            ));
                        }
                    } else {
                        if manager.provisional_slot_count() >= MAX_PROVISIONAL_OPERATIONS
                            && !manager.provisional_requests.contains_key(realtime_id)
                        {
                            return Err(boxed_message("too many provisional realtime operations"));
                        }
                        if let Some(existing) = manager.provisional_requests.get(realtime_id) {
                            if existing.authenticated_peer_id != authenticated_peer_id
                                || existing.shared_session_instance_id
                                    != consent.shared_session_instance_id
                                || existing.request.operation_id != consent.operation_id
                            {
                                return Err(boxed_message("conflicting provisional REQUEST"));
                            }
                            return Err(boxed_message("replayed provisional screen-share REQUEST"));
                        }
                        manager.remember_provisional_action(replay_key, now_ms)?;
                        let provisional_epoch = manager.next_provisional_epoch();
                        manager.provisional_requests.insert(
                            realtime_id.to_owned(),
                            ProvisionalPendingRequest {
                                provisional_epoch,
                                authenticated_peer_id: authenticated_peer_id.to_owned(),
                                shared_session_instance_id: consent
                                    .shared_session_instance_id
                                    .clone(),
                                expires_at_ms: consent.expires_at_ms,
                                expiry_deadline: provisional_deadline(
                                    now_ms,
                                    consent.expires_at_ms,
                                ),
                                request: consent,
                            },
                        );
                    }
                    manager.wake_provisional_expiry();
                }
                ScreenShareConsentDecision::Cancel => {
                    let matches_binding =
                        manager.provisional.get(realtime_id).is_some_and(|binding| {
                            binding.authenticated_peer_id == authenticated_peer_id
                                && binding.shared_session_instance_id
                                    == consent.shared_session_instance_id
                                && binding.request.as_ref().is_none_or(|request| {
                                    request.operation_id == consent.operation_id
                                })
                        });
                    let matches_request = manager
                        .provisional_requests
                        .get(realtime_id)
                        .is_some_and(|request| {
                            request.authenticated_peer_id == authenticated_peer_id
                                && request.shared_session_instance_id
                                    == consent.shared_session_instance_id
                                && request.request.operation_id == consent.operation_id
                        });
                    if !matches_binding && !matches_request {
                        return Err(boxed_message("screen-share CANCEL binding does not match"));
                    }
                    let expected_revision = manager
                        .latest_provisional_action_revision(
                            authenticated_peer_id,
                            realtime_id,
                            &consent.operation_id,
                        )
                        .ok_or_else(|| {
                            boxed_message("screen-share CANCEL REQUEST lane is missing")
                        })?
                        .saturating_add(1);
                    if consent.action_revision != expected_revision || expected_revision != 2 {
                        return Err(boxed_message(
                            "screen-share CANCEL action revision is not contiguous",
                        ));
                    }
                    manager.remember_provisional_action(
                        ProvisionalReplayKey {
                            sender_peer_id: authenticated_peer_id.to_owned(),
                            target_device_id: local_device_id.clone(),
                            realtime_id: realtime_id.to_owned(),
                            operation_id: consent.operation_id.clone(),
                            decision: consent.decision,
                            action_revision: consent.action_revision,
                        },
                        now_ms,
                    )?;
                    if matches_binding {
                        if let Some(mut binding) = manager.provisional.remove(realtime_id) {
                            binding.state = ProvisionalBindingState::Terminal;
                        }
                    } else {
                        manager.provisional_requests.remove(realtime_id);
                    }
                    manager.wake_provisional_expiry();
                }
                ScreenShareConsentDecision::Accept
                | ScreenShareConsentDecision::Reject
                | ScreenShareConsentDecision::Unspecified => {
                    return Err(boxed_message(
                        "only screen-share REQUEST/CANCEL is valid before claim",
                    ));
                }
            }
        }
        RealtimeSignalKind::WebRtcClose => {
            let mut removed = false;
            if manager.provisional.get(realtime_id).is_some_and(|binding| {
                binding.authenticated_peer_id == authenticated_peer_id
                    && binding.shared_session_instance_id == shared_session_instance_id
            }) {
                if let Some(mut binding) = manager.provisional.remove(realtime_id) {
                    binding.state = ProvisionalBindingState::Terminal;
                    removed = true;
                }
            }
            if manager
                .provisional_requests
                .get(realtime_id)
                .is_some_and(|request| {
                    request.authenticated_peer_id == authenticated_peer_id
                        && request.shared_session_instance_id == shared_session_instance_id
                })
            {
                manager.provisional_requests.remove(realtime_id);
                removed = true;
            }
            if removed {
                manager.wake_provisional_expiry();
            }
        }
        RealtimeSignalKind::WebRtcAnswer | RealtimeSignalKind::IceRestart => {
            return Err(boxed_message(
                "Answer or ICE restart is not valid before incoming claim",
            ));
        }
        RealtimeSignalKind::Unspecified => {
            return Err(boxed_message(
                "unsupported provisional realtime signal kind",
            ));
        }
    }
    drop(manager);
    if let Some((offer_id, claim_token, realtime_id, peer_id, shared_id, expires, request)) =
        publish
    {
        crate::events::emit_realtime_incoming_session_offer(
            &state.event_tx,
            crate::events::RealtimeIncomingSessionOfferMetadata {
                offer_id: &offer_id,
                claim_token: &claim_token,
                realtime_id: &realtime_id,
                authenticated_peer_id: &peer_id,
                shared_session_instance_id: &shared_id,
                binding_expires_at_ms: expires,
                request: &request,
            },
        );
    }
    Ok(())
}
