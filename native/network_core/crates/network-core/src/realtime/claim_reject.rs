//! Reject or discard a provisional incoming offer without creating a peer.
use super::*;
use crate::events::emit_realtime_signal;
use crate::runtime::RuntimeState;
use network_protocol::{
    DiscardIncomingRealtimeOfferCommand, RejectIncomingRealtimeOfferCommand,
    ScreenShareConsentDecision,
};
use prost::Message;

pub(crate) async fn reject_incoming_offer(
    state: &RuntimeState,
    command: RejectIncomingRealtimeOfferCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    validate_peer(state, &command.peer_id).await?;
    let (request, shared_session_instance_id, offer_revision) = {
        let mut manager = state.realtime.lock().await;
        prune_provisional_bindings(
            &mut manager,
            crate::events::unix_timestamp_ms().max(0) as u64,
        );
        let Some(binding) = manager.provisional.get(&command.realtime_id) else {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "incoming realtime offer does not exist",
                "reject_incoming_realtime_offer",
                &command.peer_id,
            ));
        };
        if binding.claim_token != command.claim_token
            || binding.authenticated_peer_id != command.peer_id
            || !matches!(binding.state, ProvisionalBindingState::Pending)
        {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "incoming realtime offer rejection is stale",
                "reject_incoming_realtime_offer",
                &command.peer_id,
            ));
        }
        let request = binding.request.clone().ok_or_else(|| {
            realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "incoming realtime request is incomplete",
                "reject_incoming_realtime_offer",
                &command.peer_id,
            )
        })?;
        let shared_session_instance_id = binding.shared_session_instance_id.clone();
        let offer_revision = binding.offer_revision;
        (request, shared_session_instance_id, offer_revision)
    };
    let identity = state
        .lifecycle
        .identity
        .read()
        .await
        .clone()
        .ok_or_else(|| {
            realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "local realtime identity is unavailable",
                "reject_incoming_realtime_offer",
                &command.peer_id,
            )
        })?;
    let now_ms = crate::events::unix_timestamp_ms().max(0) as u64;
    let mut reject = request;
    reject.issued_at_ms = now_ms;
    reject.expires_at_ms = reject
        .expires_at_ms
        .min(now_ms.saturating_add(SCREEN_SHARE_CONSENT_MAX_LIFETIME_MS));
    reject.decision = ScreenShareConsentDecision::Reject as i32;
    reject.sender_peer_id = identity.device_id.clone();
    reject.action_revision = 1;
    let payload = reject.encode_to_vec();
    validate_screen_share_consent(
        &payload,
        &command.realtime_id,
        None,
        Some(&shared_session_instance_id),
    )
    .map_err(|error| {
        realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            error.to_string(),
            "reject_incoming_realtime_offer",
            &command.peer_id,
        )
    })?;
    let outbound = OutboundSignal {
        realtime_id: command.realtime_id.clone(),
        peer_id: command.peer_id.clone(),
        shared_session_instance_id,
        kind: RealtimeSignalKind::ScreenShareConsent,
        revision: offer_revision.max(1),
        payload,
    };
    {
        let mut manager = state.realtime.lock().await;
        let exact_pending = manager
            .provisional
            .get(&command.realtime_id)
            .is_some_and(|binding| {
                binding.claim_token == command.claim_token
                    && binding.authenticated_peer_id == command.peer_id
                    && binding.state == ProvisionalBindingState::Pending
            });
        if !exact_pending {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::StaleOperation,
                "incoming realtime offer rejection was superseded",
                "reject_incoming_realtime_offer",
                &command.peer_id,
            ));
        }
        if let Some(binding) = manager.provisional.get_mut(&command.realtime_id) {
            binding.state = ProvisionalBindingState::Claiming;
        }
    }
    if let Err(error) = send_signal(state, &outbound).await {
        let mut manager = state.realtime.lock().await;
        if manager
            .provisional
            .get(&command.realtime_id)
            .is_some_and(|binding| {
                binding.claim_token == command.claim_token
                    && binding.state == ProvisionalBindingState::Claiming
            })
        {
            if let Some(mut binding) = manager.provisional.remove(&command.realtime_id) {
                binding.state = ProvisionalBindingState::Terminal;
                manager.wake_provisional_expiry();
            }
        }
        return Err(error);
    }
    emit_realtime_signal(
        &state.event_tx,
        &outbound.realtime_id,
        &outbound.peer_id,
        outbound.kind as i32,
        outbound.revision,
        outbound.payload,
    );
    let mut manager = state.realtime.lock().await;
    if manager
        .provisional
        .get(&command.realtime_id)
        .is_some_and(|binding| {
            binding.claim_token == command.claim_token
                && binding.state == ProvisionalBindingState::Claiming
        })
    {
        if let Some(mut binding) = manager.provisional.remove(&command.realtime_id) {
            binding.state = ProvisionalBindingState::Terminal;
            manager.wake_provisional_expiry();
        }
    }
    Ok(())
}

pub(crate) async fn discard_incoming_offer(
    state: &RuntimeState,
    command: DiscardIncomingRealtimeOfferCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    validate_peer(state, &command.peer_id).await?;
    let mut manager = state.realtime.lock().await;
    let Some(binding) = manager.provisional.get(&command.realtime_id) else {
        return Ok(());
    };
    if binding.claim_token != command.claim_token
        || binding.authenticated_peer_id != command.peer_id
    {
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "incoming realtime offer discard is stale",
            "discard_incoming_realtime_offer",
            &command.peer_id,
        ));
    }
    if let Some(mut binding) = manager.provisional.remove(&command.realtime_id) {
        binding.state = ProvisionalBindingState::Terminal;
        manager.wake_provisional_expiry();
    }
    Ok(())
}
