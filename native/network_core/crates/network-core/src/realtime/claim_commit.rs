//! Commit an incoming screen-share offer into a responder session.
use super::*;
use crate::events::{emit_realtime_signal, emit_realtime_state, RealtimeSessionIdentity};
use crate::runtime::RuntimeState;
use network_protocol::ClaimIncomingRealtimeOfferCommand;

/// Atomically promotes one metadata-paired provisional binding into the exact
/// responder generation registered by the SDK. The binding remains `Claiming`
/// while the Answer is sent. ICE arriving before the exact responder owns the
/// realtime ID stays in the protected provisional queue; after registration,
/// matching ICE is routed directly to that exact claiming generation. The
/// binding is externally committed only after the Answer is sent successfully.
pub(crate) async fn claim_incoming_offer(
    state: Arc<RuntimeState>,
    command: ClaimIncomingRealtimeOfferCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    validate_peer(&state, &command.peer_id).await?;
    let now_ms = crate::events::unix_timestamp_ms().max(0) as u64;
    let (offer, offer_revision, queued_ice, shared_session_instance_id, provisional_epoch) = {
        let mut manager = state.realtime.lock().await;
        prune_provisional_bindings(&mut manager, now_ms);
        let Some(binding) = manager.provisional.get_mut(&command.realtime_id) else {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "incoming realtime offer does not exist",
                "claim_incoming_realtime_offer",
                &command.peer_id,
            ));
        };
        if binding.claim_token != command.claim_token
            || binding.authenticated_peer_id != command.peer_id
            || !matches!(binding.state, ProvisionalBindingState::Pending)
            || binding.request.is_none()
            || binding.is_expired(now_ms)
        {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "incoming realtime offer claim is stale or incomplete",
                "claim_incoming_realtime_offer",
                &command.peer_id,
            ));
        }
        binding.state = ProvisionalBindingState::Claiming;
        let queued_ice = binding.ice_candidates.drain(..).collect::<Vec<_>>();
        binding.ice_total_bytes = 0;
        (
            binding.offer_payload.clone(),
            binding.offer_revision,
            queued_ice,
            binding.shared_session_instance_id.clone(),
            binding.provisional_epoch,
        )
    };
    let driver = match create_io_driver(&state, runtime_webrtc_config()).await {
        Ok(driver) => driver.into_handle(),
        Err(error) => {
            let mut manager = state.realtime.lock().await;
            take_provisional_claim(
                &mut manager,
                &command.realtime_id,
                &command.claim_token,
                provisional_epoch,
            );
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::IoError,
                error.to_string(),
                "claim_incoming_realtime_offer",
                &command.peer_id,
            ));
        }
    };
    let connection_session_id = state
        .connection_sessions
        .current_session_id(&command.peer_id)
        .await;
    let outcome = {
        let mut manager = state.realtime.lock().await;
        let binding_valid = exact_claiming_binding(
            &manager,
            &command.realtime_id,
            &command.peer_id,
            &shared_session_instance_id,
            &command.claim_token,
            provisional_epoch,
            crate::events::unix_timestamp_ms().max(0) as u64,
        );
        if !binding_valid {
            if let Ok(mut driver) = driver.lock() {
                let _ = driver.close();
            }
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::StaleOperation,
                "incoming realtime offer claim was superseded",
                "claim_incoming_realtime_offer",
                &command.peer_id,
            ));
        }
        let outcome = apply_signal_with_driver(
            &mut manager,
            &command.realtime_id,
            &command.peer_id,
            InboundSignal {
                shared_session_instance_id: shared_session_instance_id.clone(),
                kind: RealtimeSignalKind::WebRtcOffer,
                revision: offer_revision,
                payload: offer,
            },
            Some(driver.clone()),
            connection_session_id,
        );
        let outcome = match outcome {
            Ok(outcome) => outcome,
            Err(error) => {
                let generation = manager.session_generation(&command.realtime_id);
                drop(manager);
                rollback_incoming_claim(
                    &state,
                    &command,
                    &shared_session_instance_id,
                    provisional_epoch,
                    generation,
                    &driver,
                )
                .await;
                return Err(realtime_error(
                    network_protocol::NetworkErrorCode::IoError,
                    error.to_string(),
                    "claim_incoming_realtime_offer",
                    &command.peer_id,
                ));
            }
        };
        let responder = IncomingClaimResponder {
            provisional_epoch,
            generation: outcome.generation,
            driver: driver.clone(),
        };
        for candidate in queued_ice {
            if let Err(error) = apply_signal_with_driver(
                &mut manager,
                &command.realtime_id,
                &command.peer_id,
                InboundSignal {
                    shared_session_instance_id: shared_session_instance_id.clone(),
                    kind: RealtimeSignalKind::IceCandidate,
                    revision: candidate.revision,
                    payload: candidate.payload,
                },
                None,
                None,
            ) {
                drop(manager);
                rollback_incoming_claim(
                    &state,
                    &command,
                    &shared_session_instance_id,
                    provisional_epoch,
                    Some(responder.generation),
                    &driver,
                )
                .await;
                return Err(realtime_error(
                    network_protocol::NetworkErrorCode::IoError,
                    error.to_string(),
                    "claim_incoming_realtime_offer",
                    &command.peer_id,
                ));
            }
        }
        (outcome, responder)
    };
    let (outcome, responder) = outcome;

    let cleanup_driver = Arc::clone(&responder.driver);
    if state
        .task_supervisor
        .spawn_session(
            realtime_task_key(&command.realtime_id),
            "realtime-io",
            run_realtime_session_io(
                Arc::clone(&state),
                command.realtime_id.clone(),
                command.peer_id.clone(),
                responder.driver.clone(),
            ),
        )
        .is_none()
    {
        rollback_incoming_claim(
            &state,
            &command,
            &shared_session_instance_id,
            provisional_epoch,
            Some(responder.generation),
            &cleanup_driver,
        )
        .await;
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::Cancelled,
            "runtime task supervisor is stopping",
            "claim_incoming_realtime_offer",
            &command.peer_id,
        ));
    }
    let Some(answer) = outcome.outbound else {
        state
            .task_supervisor
            .cancel_session(&realtime_task_key(&command.realtime_id))
            .await;
        rollback_incoming_claim(
            &state,
            &command,
            &shared_session_instance_id,
            provisional_epoch,
            Some(responder.generation),
            &cleanup_driver,
        )
        .await;
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::IoError,
            "incoming realtime claim produced no Answer",
            "claim_incoming_realtime_offer",
            &command.peer_id,
        ));
    };
    if let Err(error) = send_signal(&state, &answer).await {
        state
            .task_supervisor
            .cancel_session(&realtime_task_key(&command.realtime_id))
            .await;
        rollback_incoming_claim(
            &state,
            &command,
            &shared_session_instance_id,
            provisional_epoch,
            Some(responder.generation),
            &cleanup_driver,
        )
        .await;
        return Err(error);
    }

    let (commit_result, close_signal) = {
        let mut manager = state.realtime.lock().await;
        let result = commit_incoming_claim(
            &mut manager,
            &command.realtime_id,
            &command.peer_id,
            &shared_session_instance_id,
            &command.claim_token,
            &responder,
        );
        let close_signal = if result.is_err() {
            next_claim_close_signal(
                &mut manager,
                &command.realtime_id,
                &command.peer_id,
                &shared_session_instance_id,
                answer.revision,
                &responder,
            )
        } else {
            None
        };
        (result, close_signal)
    };
    if let Err(error) = commit_result {
        if let Some(close_signal) = close_signal {
            if send_signal(&state, &close_signal).await.is_ok() {
                emit_realtime_signal(
                    &state.event_tx,
                    &close_signal.realtime_id,
                    &close_signal.peer_id,
                    close_signal.kind as i32,
                    close_signal.revision,
                    close_signal.payload.clone(),
                );
            }
        }
        state
            .task_supervisor
            .cancel_session(&realtime_task_key(&command.realtime_id))
            .await;
        rollback_incoming_claim(
            &state,
            &command,
            &shared_session_instance_id,
            provisional_epoch,
            Some(responder.generation),
            &cleanup_driver,
        )
        .await;
        return Err(error);
    }
    emit_realtime_signal(
        &state.event_tx,
        &answer.realtime_id,
        &answer.peer_id,
        answer.kind as i32,
        answer.revision,
        answer.payload,
    );
    emit_realtime_state(
        &state.event_tx,
        &command.realtime_id,
        &command.peer_id,
        RealtimeSessionState::Negotiating as i32,
        outcome.revision,
        RealtimeSessionIdentity::new(outcome.generation, &outcome.shared_session_instance_id),
        None,
    );
    Ok(())
}

async fn rollback_incoming_claim(
    state: &RuntimeState,
    command: &ClaimIncomingRealtimeOfferCommand,
    shared_session_instance_id: &str,
    provisional_epoch: u64,
    responder_generation: Option<u64>,
    driver: &RealtimeIoDriverHandle,
) {
    let removed = {
        let mut manager = state.realtime.lock().await;
        let mut provisional_removed = false;
        if manager
            .provisional
            .get(&command.realtime_id)
            .is_some_and(|binding| {
                binding.claim_token == command.claim_token
                    && binding.provisional_epoch == provisional_epoch
                    && binding.state == ProvisionalBindingState::Claiming
            })
        {
            if let Some(mut binding) = manager.provisional.remove(&command.realtime_id) {
                binding.state = ProvisionalBindingState::Terminal;
                provisional_removed = true;
            }
        }
        if provisional_removed {
            manager.wake_provisional_expiry();
        }
        let removed = responder_generation
            .filter(|generation| {
                exact_claim_responder(
                    &manager,
                    &command.realtime_id,
                    &command.peer_id,
                    shared_session_instance_id,
                    *generation,
                    driver,
                )
            })
            .and_then(|_| {
                take_realtime_session_if_owned(
                    &mut manager,
                    &command.realtime_id,
                    &command.peer_id,
                    driver,
                )
            });
        if removed.is_some() {
            crate::realtime_media::invalidate_realtime(state, &command.realtime_id);
        }
        removed
    };
    if let Some(mut session) = removed {
        let _ = with_session_peer(&mut session, WebRtcPeer::close);
    } else if let Ok(mut driver) = driver.lock() {
        let _ = driver.close();
    }
}
