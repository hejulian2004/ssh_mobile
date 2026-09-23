//! Control signals that arrive while an incoming claim is in progress.
use super::*;
use crate::events::{emit_realtime_signal, emit_realtime_state, RealtimeSessionIdentity};
use crate::runtime::RuntimeState;
use network_protocol::ScreenShareConsentDecision;

pub(crate) async fn handle_claiming_control_signal(
    state: &Arc<RuntimeState>,
    signal: ClaimingControlSignal<'_>,
) -> Result<bool, Box<dyn std::error::Error + Send + Sync>> {
    validate_signal(signal.kind, signal.revision, signal.payload).map_err(boxed_protocol_error)?;
    let mut closed_session: Option<(RealtimeSession, u64)> = None;
    let handled = {
        let mut manager = state.realtime.lock().await;
        if let Some(binding) = manager.provisional.get(signal.realtime_id) {
            if binding.authenticated_peer_id != signal.authenticated_peer_id
                || binding.shared_session_instance_id != signal.shared_session_instance_id
                || binding.state != ProvisionalBindingState::Claiming
            {
                false
            } else {
                match signal.kind {
                    RealtimeSignalKind::ScreenShareConsent => {
                        let consent = validate_screen_share_consent(
                            signal.payload,
                            signal.realtime_id,
                            Some(signal.authenticated_peer_id),
                            Some(signal.shared_session_instance_id),
                        )?;
                        if ScreenShareConsentDecision::try_from(consent.decision)
                            .map_err(|_| boxed_message("unknown screen-share consent decision"))?
                            != ScreenShareConsentDecision::Cancel
                        {
                            return Err(boxed_message(
                                "only screen-share CANCEL is valid while claim is in progress",
                            ));
                        }
                        let binding = manager
                            .provisional
                            .get(signal.realtime_id)
                            .expect("claiming provisional binding exists");
                        if !binding.request.as_ref().is_some_and(|request| {
                            request.operation_id == consent.operation_id
                                && request.shared_session_instance_id
                                    == consent.shared_session_instance_id
                        }) {
                            return Err(boxed_message(
                                "screen-share CANCEL binding does not match claiming operation",
                            ));
                        }
                        let expected_revision = manager
                            .latest_provisional_action_revision(
                                signal.authenticated_peer_id,
                                signal.realtime_id,
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
                                sender_peer_id: signal.authenticated_peer_id.to_owned(),
                                target_device_id: signal.local_device_id.to_owned(),
                                realtime_id: signal.realtime_id.to_owned(),
                                operation_id: consent.operation_id,
                                decision: consent.decision,
                                action_revision: consent.action_revision,
                            },
                            crate::events::unix_timestamp_ms().max(0) as u64,
                        )?;
                        if let Some(mut binding) = manager.provisional.remove(signal.realtime_id) {
                            binding.state = ProvisionalBindingState::Terminal;
                        }
                        manager.wake_provisional_expiry();
                        true
                    }
                    RealtimeSignalKind::WebRtcClose => {
                        let exact_session =
                            manager
                                .sessions
                                .get(signal.realtime_id)
                                .is_some_and(|session| {
                                    session.peer_id == signal.authenticated_peer_id
                                        && session.shared_session_instance_id
                                            == signal.shared_session_instance_id
                                        && signal.revision > session.remote_revision
                                });
                        if manager.sessions.contains_key(signal.realtime_id) && !exact_session {
                            return Err(boxed_message(
                                "claiming WebRTC close does not match responder binding",
                            ));
                        }
                        let (claim_token, epoch) = manager
                            .provisional
                            .get(signal.realtime_id)
                            .map(|binding| (binding.claim_token.clone(), binding.provisional_epoch))
                            .expect("claiming provisional binding exists");
                        take_provisional_claim(
                            &mut manager,
                            signal.realtime_id,
                            &claim_token,
                            epoch,
                        );
                        if exact_session {
                            let generation =
                                manager.session_generation(signal.realtime_id).ok_or_else(
                                    || boxed_message("claiming responder generation missing"),
                                )?;
                            let session =
                                manager.remove_session(signal.realtime_id).ok_or_else(|| {
                                    boxed_message("claiming responder session missing")
                                })?;
                            crate::realtime_media::invalidate_realtime(state, signal.realtime_id);
                            closed_session = Some((session, generation));
                        }
                        true
                    }
                    _ => false,
                }
            }
        } else {
            false
        }
    };
    if !handled {
        return Ok(false);
    }
    if let Some((mut session, generation)) = closed_session {
        state
            .task_supervisor
            .cancel_session(&realtime_task_key(signal.realtime_id))
            .await;
        let _ = with_session_peer(&mut session, WebRtcPeer::close);
        emit_realtime_signal(
            &state.event_tx,
            signal.realtime_id,
            signal.authenticated_peer_id,
            signal.kind as i32,
            signal.revision,
            signal.payload.to_vec(),
        );
        emit_realtime_state(
            &state.event_tx,
            signal.realtime_id,
            signal.authenticated_peer_id,
            RealtimeSessionState::Closed as i32,
            signal.revision,
            RealtimeSessionIdentity::new(generation, signal.shared_session_instance_id),
            None,
        );
    }
    Ok(true)
}
