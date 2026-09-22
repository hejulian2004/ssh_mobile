//! Exact-match helpers for promoting or rolling back an incoming claim.
use super::*;

pub(crate) fn exact_claiming_binding(
    manager: &RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    shared_session_instance_id: &str,
    claim_token: &str,
    provisional_epoch: u64,
    now_ms: u64,
) -> bool {
    manager.provisional.get(realtime_id).is_some_and(|binding| {
        binding.claim_token == claim_token
            && binding.provisional_epoch == provisional_epoch
            && binding.authenticated_peer_id == peer_id
            && binding.shared_session_instance_id == shared_session_instance_id
            && binding.state == ProvisionalBindingState::Claiming
            && !binding.is_expired(now_ms)
    })
}

pub(crate) fn exact_claim_responder(
    manager: &RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    shared_session_instance_id: &str,
    generation: u64,
    driver: &RealtimeIoDriverHandle,
) -> bool {
    manager.session_generation(realtime_id) == Some(generation)
        && manager.sessions.get(realtime_id).is_some_and(|session| {
            session.peer_id == peer_id
                && session.shared_session_instance_id == shared_session_instance_id
                && session
                    .driver
                    .as_ref()
                    .is_some_and(|candidate| Arc::ptr_eq(candidate, driver))
        })
}

pub(crate) fn take_provisional_claim(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    claim_token: &str,
    provisional_epoch: u64,
) -> bool {
    if !manager.provisional.get(realtime_id).is_some_and(|binding| {
        binding.claim_token == claim_token
            && binding.provisional_epoch == provisional_epoch
            && binding.state == ProvisionalBindingState::Claiming
    }) {
        return false;
    }
    if let Some(mut binding) = manager.provisional.remove(realtime_id) {
        binding.state = ProvisionalBindingState::Terminal;
        manager.wake_provisional_expiry();
        return true;
    }
    false
}

pub(crate) fn next_claim_close_signal(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    shared_session_instance_id: &str,
    answer_revision: u64,
    responder: &IncomingClaimResponder,
) -> Option<OutboundSignal> {
    if !exact_claim_responder(
        manager,
        realtime_id,
        peer_id,
        shared_session_instance_id,
        responder.generation,
        &responder.driver,
    ) {
        return None;
    }
    let session = manager.sessions.get_mut(realtime_id)?;
    let close_revision = session.revision.max(answer_revision).checked_add(1)?;
    session.revision = close_revision;
    Some(OutboundSignal {
        realtime_id: realtime_id.to_owned(),
        peer_id: peer_id.to_owned(),
        shared_session_instance_id: shared_session_instance_id.to_owned(),
        kind: RealtimeSignalKind::WebRtcClose,
        revision: close_revision,
        payload: b"close".to_vec(),
    })
}

pub(crate) fn commit_incoming_claim(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    shared_session_instance_id: &str,
    claim_token: &str,
    responder: &IncomingClaimResponder,
) -> Result<(), network_protocol::NetworkError> {
    let now_ms = crate::events::unix_timestamp_ms().max(0) as u64;
    if !exact_claiming_binding(
        manager,
        realtime_id,
        peer_id,
        shared_session_instance_id,
        claim_token,
        responder.provisional_epoch,
        now_ms,
    ) || !exact_claim_responder(
        manager,
        realtime_id,
        peer_id,
        shared_session_instance_id,
        responder.generation,
        &responder.driver,
    ) {
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::StaleOperation,
            "incoming realtime offer claim was superseded or expired",
            "claim_incoming_realtime_offer",
            peer_id,
        ));
    }

    loop {
        let queued = {
            let Some(binding) = manager.provisional.get_mut(realtime_id) else {
                return Err(realtime_error(
                    network_protocol::NetworkErrorCode::StaleOperation,
                    "incoming realtime offer claim was superseded",
                    "claim_incoming_realtime_offer",
                    peer_id,
                ));
            };
            if binding.claim_token != claim_token
                || binding.provisional_epoch != responder.provisional_epoch
                || binding.state != ProvisionalBindingState::Claiming
            {
                return Err(realtime_error(
                    network_protocol::NetworkErrorCode::StaleOperation,
                    "incoming realtime offer claim was superseded",
                    "claim_incoming_realtime_offer",
                    peer_id,
                ));
            }
            let queued = binding.ice_candidates.drain(..).collect::<Vec<_>>();
            binding.ice_total_bytes = 0;
            queued
        };
        if queued.is_empty() {
            break;
        }
        for candidate in queued {
            apply_signal_with_driver(
                manager,
                realtime_id,
                peer_id,
                InboundSignal {
                    shared_session_instance_id: shared_session_instance_id.to_owned(),
                    kind: RealtimeSignalKind::IceCandidate,
                    revision: candidate.revision,
                    payload: candidate.payload,
                },
                None,
                None,
            )
            .map_err(|error| {
                realtime_error(
                    network_protocol::NetworkErrorCode::IoError,
                    error.to_string(),
                    "claim_incoming_realtime_offer",
                    peer_id,
                )
            })?;
        }
    }

    let now_ms = crate::events::unix_timestamp_ms().max(0) as u64;
    if !exact_claiming_binding(
        manager,
        realtime_id,
        peer_id,
        shared_session_instance_id,
        claim_token,
        responder.provisional_epoch,
        now_ms,
    ) || !exact_claim_responder(
        manager,
        realtime_id,
        peer_id,
        shared_session_instance_id,
        responder.generation,
        &responder.driver,
    ) {
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::StaleOperation,
            "incoming realtime offer claim expired during commit",
            "claim_incoming_realtime_offer",
            peer_id,
        ));
    }
    if let Some(binding) = manager.provisional.get_mut(realtime_id) {
        binding.state = ProvisionalBindingState::Claimed;
    }
    manager.provisional.remove(realtime_id);
    manager.wake_provisional_expiry();
    Ok(())
}
