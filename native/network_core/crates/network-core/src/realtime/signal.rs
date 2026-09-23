//! Realtime signaling commands and v2 control-plane dispatch.
use super::*;
use crate::events::{emit_realtime_signal, emit_realtime_state, RealtimeSessionIdentity};
use crate::runtime::RuntimeState;
use network_protocol::SendRealtimeSignalCommand;
use network_relay::v2::RealtimeSignal as V2RealtimeSignal;

pub(crate) async fn send_signal_command(
    state: &RuntimeState,
    command: SendRealtimeSignalCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    validate_peer(state, &command.peer_id).await?;
    let kind = RealtimeSignalKind::try_from(command.kind).map_err(|_| {
        realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "invalid WebRTC signal kind",
            "send_realtime_signal",
            &command.peer_id,
        )
    })?;
    validate_signal(kind, command.revision, &command.payload)?;
    let (session_peer_id, session_shared_session_instance_id, session_revision, ice_revision) = {
        let sessions = state.realtime.lock().await;
        let Some(session) = sessions.sessions.get(&command.realtime_id) else {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "realtime session does not exist",
                "send_realtime_signal",
                &command.peer_id,
            ));
        };
        (
            session.peer_id.clone(),
            session.shared_session_instance_id.clone(),
            session.revision,
            session.ice_revision,
        )
    };
    if kind == RealtimeSignalKind::ScreenShareConsent {
        validate_screen_share_consent(
            &command.payload,
            &command.realtime_id,
            None,
            Some(&session_shared_session_instance_id),
        )
        .map_err(|error| {
            realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                error.to_string(),
                "send_realtime_signal",
                &command.peer_id,
            )
        })?;
    }
    let revision_is_valid = if kind == RealtimeSignalKind::ScreenShareConsent {
        // Consent has its own action_revision and shared-session freshness
        // checks. The outer realtime revision is only a positive relay
        // correlation value and must not be confused with signaling ordering.
        command.revision > 0
    } else if kind == RealtimeSignalKind::IceCandidate {
        command.revision == ice_revision
    } else {
        command.revision > session_revision
    };
    if session_peer_id != command.peer_id || !revision_is_valid {
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "stale or mismatched realtime signaling revision",
            "send_realtime_signal",
            &command.peer_id,
        ));
    }
    let outbound = OutboundSignal {
        realtime_id: command.realtime_id.clone(),
        peer_id: command.peer_id.clone(),
        shared_session_instance_id: session_shared_session_instance_id,
        kind,
        revision: command.revision,
        payload: command.payload,
    };
    send_signal(state, &outbound).await?;
    emit_realtime_signal(
        &state.event_tx,
        &outbound.realtime_id,
        &outbound.peer_id,
        outbound.kind as i32,
        outbound.revision,
        outbound.payload,
    );
    Ok(())
}

pub(crate) async fn handle_v2_realtime_signal(
    state: &Arc<RuntimeState>,
    signal: &V2RealtimeSignal,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let local_device_id = state
        .lifecycle
        .identity
        .read()
        .await
        .as_ref()
        .map(|identity| identity.device_id.clone())
        .ok_or_else(|| boxed_message("local realtime identity is unavailable"))?;
    if signal.target_device_id != local_device_id {
        return Err(boxed_message(
            "v2 WebRTC signal target does not match local authenticated identity",
        ));
    }
    let bound_peer_id = state
        .realtime
        .lock()
        .await
        .sessions
        .get(&signal.realtime_id)
        .map(|session| session.peer_id.clone());
    let source_peer_id = signal.source_device_id.trim();
    if !source_peer_id.is_empty() {
        validate_peer(state, source_peer_id)
            .await
            .map_err(boxed_protocol_error)?;
        if bound_peer_id
            .as_deref()
            .is_some_and(|bound| bound != source_peer_id)
        {
            return Err(boxed_message(
                "v2 WebRTC signal source does not match session binding",
            ));
        }
    }
    let peer_id = bound_peer_id
        .clone()
        .or_else(|| (!source_peer_id.is_empty()).then(|| source_peer_id.to_owned()))
        .ok_or_else(|| boxed_message("v2 WebRTC signal has no authenticated source"))?;
    if peer_id.is_empty() {
        return Err(boxed_message(
            "v2 WebRTC signal has an empty established peer binding",
        ));
    }
    let (shared_session_instance_id, payload) = decode_realtime_signal_payload(&signal.payload)
        .map_err(|error| boxed_message(error.to_string()))?;
    let kind = RealtimeSignalKind::try_from(signal.kind)
        .map_err(|_| boxed_message("invalid v2 WebRTC signal kind"))?;
    if matches!(
        kind,
        RealtimeSignalKind::ScreenShareConsent | RealtimeSignalKind::WebRtcClose
    ) && handle_claiming_control_signal(
        state,
        ClaimingControlSignal {
            local_device_id: &local_device_id,
            kind,
            realtime_id: &signal.realtime_id,
            authenticated_peer_id: &peer_id,
            revision: signal.revision,
            shared_session_instance_id: &shared_session_instance_id,
            payload: &payload,
        },
    )
    .await?
    {
        return Ok(());
    }
    if bound_peer_id.is_none() {
        return handle_provisional_realtime_signal(
            state,
            kind,
            &signal.realtime_id,
            &peer_id,
            signal.revision,
            shared_session_instance_id,
            payload,
        )
        .await;
    }
    handle_realtime_signal(
        state,
        kind,
        &signal.realtime_id,
        &peer_id,
        signal.revision,
        shared_session_instance_id,
        payload,
    )
    .await
}

/// WebRTC signaling 协商核心 for an already-bound RealtimeSession.
///
/// Unknown-session Offer/ICE never enters this function through the v2 ingress;
/// `handle_provisional_realtime_signal` retains it natively until an explicit
/// incoming claim creates the formal responder generation. `outcome.outbound`
/// (Answer / restart Offer / ICE) is sent back through the v2 control plane.
pub(crate) async fn handle_realtime_signal(
    state: &Arc<RuntimeState>,
    kind: RealtimeSignalKind,
    realtime_id: &str,
    peer_id: &str,
    revision: u64,
    shared_session_instance_id: String,
    payload: Vec<u8>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    validate_realtime_id(realtime_id).map_err(boxed_protocol_error)?;
    validate_shared_session_instance_id(&shared_session_instance_id)?;
    validate_peer(state, peer_id)
        .await
        .map_err(boxed_protocol_error)?;
    validate_signal(kind, revision, &payload).map_err(boxed_protocol_error)?;

    // Screen-share consent is authenticated control metadata, not a WebRTC
    // description. Keep it on the existing Realtime control route while
    // avoiding any PeerConnection mutation or state transition. The payload
    // carries the shared-session and action-revision guards used by the
    // business layer.
    if kind == RealtimeSignalKind::ScreenShareConsent {
        let expected_shared = state
            .realtime
            .lock()
            .await
            .sessions
            .get(realtime_id)
            .map(|session| session.shared_session_instance_id.clone());
        validate_screen_share_consent(
            &payload,
            realtime_id,
            Some(peer_id),
            expected_shared.as_deref(),
        )?;
        emit_realtime_signal(
            &state.event_tx,
            realtime_id,
            peer_id,
            kind as i32,
            revision,
            payload,
        );
        return Ok(());
    }

    if kind == RealtimeSignalKind::WebRtcClose {
        let generation = {
            let mut manager = state.realtime.lock().await;
            close_remote_realtime_session(
                state,
                &mut manager,
                realtime_id,
                peer_id,
                revision,
                &shared_session_instance_id,
            )?
        };
        state
            .task_supervisor
            .cancel_session(&realtime_task_key(realtime_id))
            .await;
        emit_realtime_signal(
            &state.event_tx,
            realtime_id,
            peer_id,
            kind as i32,
            revision,
            payload,
        );
        emit_realtime_state(
            &state.event_tx,
            realtime_id,
            peer_id,
            RealtimeSessionState::Closed as i32,
            revision,
            RealtimeSessionIdentity::new(generation, &shared_session_instance_id),
            None,
        );
        return Ok(());
    }

    let pending_driver = if kind == RealtimeSignalKind::WebRtcOffer
        && !state
            .realtime
            .lock()
            .await
            .sessions
            .contains_key(realtime_id)
    {
        Some(
            create_io_driver(state, runtime_webrtc_config())
                .await
                .map_err(|error| boxed_message(error.to_string()))?
                .into_handle(),
        )
    } else {
        None
    };
    // §22：responder 新建会话时绑定当前 ConnectionSession；后续 transport 丢失据此
    // 关闭 RealtimeSession。
    let connection_session_id = state.connection_sessions.current_session_id(peer_id).await;

    let pending_driver_for_spawn = pending_driver.clone();
    let outcome = {
        let mut manager = state.realtime.lock().await;
        apply_signal_with_driver(
            &mut manager,
            realtime_id,
            peer_id,
            InboundSignal {
                shared_session_instance_id,
                kind,
                revision,
                payload: payload.clone(),
            },
            pending_driver,
            connection_session_id,
        )?
    };

    let driver_to_spawn = if let Some(pending_driver) = pending_driver_for_spawn {
        let sessions = state.realtime.lock().await;
        sessions.sessions.get(realtime_id).and_then(|session| {
            session
                .driver
                .as_ref()
                .filter(|driver| Arc::ptr_eq(driver, &pending_driver))
                .cloned()
        })
    } else {
        None
    };
    let driver_for_cleanup = driver_to_spawn.clone();
    let mut spawned_io = false;
    if let Some(driver) = driver_to_spawn {
        let cleanup_driver = Arc::clone(&driver);
        if state
            .task_supervisor
            .spawn_session(
                realtime_task_key(realtime_id),
                "realtime-io",
                run_realtime_session_io(
                    Arc::clone(state),
                    realtime_id.to_owned(),
                    peer_id.to_owned(),
                    driver,
                ),
            )
            .is_none()
        {
            let removed = {
                let mut sessions = state.realtime.lock().await;
                let removed = take_realtime_session_if_owned(
                    &mut sessions,
                    realtime_id,
                    peer_id,
                    &cleanup_driver,
                );
                if removed.is_some() {
                    crate::realtime_media::invalidate_realtime(state, realtime_id);
                }
                removed
            };
            if let Some(mut removed) = removed {
                let _ = with_session_peer(&mut removed, WebRtcPeer::close);
            }
            return Err(boxed_message("runtime task supervisor is stopping"));
        }
        spawned_io = true;
    }

    emit_realtime_signal(
        &state.event_tx,
        realtime_id,
        peer_id,
        kind as i32,
        revision,
        payload,
    );
    if let Some(state_value) = outcome.state {
        emit_realtime_state(
            &state.event_tx,
            realtime_id,
            &outcome.peer_id,
            state_value as i32,
            outcome.revision,
            RealtimeSessionIdentity::new(outcome.generation, &outcome.shared_session_instance_id),
            None,
        );
    }
    if let Some(outbound) = outcome.outbound {
        if let Err(error) = send_signal(state, &outbound).await {
            if spawned_io {
                state
                    .task_supervisor
                    .cancel_session(&realtime_task_key(realtime_id))
                    .await;
                if let Some(driver) = driver_for_cleanup.as_ref() {
                    remove_realtime_session_if_owned(state, realtime_id, peer_id, driver).await;
                }
            }
            return Err(boxed_protocol_error(error));
        }
        emit_realtime_signal(
            &state.event_tx,
            &outbound.realtime_id,
            &outbound.peer_id,
            outbound.kind as i32,
            outbound.revision,
            outbound.payload,
        );
    }
    Ok(())
}
