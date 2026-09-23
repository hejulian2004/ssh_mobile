//! Apply one normalized WebRTC signal to the owned peer session.
use super::*;
use crate::runtime::RuntimeState;
use network_webrtc::{
    DescriptionType, IceCandidate, SessionDescription, WebRtcConfig, WebRtcError,
};

#[cfg(test)]
pub(crate) fn apply_signal(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    kind: RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
) -> Result<SignalOutcome, Box<dyn std::error::Error + Send + Sync>> {
    apply_signal_with_driver(
        manager,
        realtime_id,
        peer_id,
        InboundSignal {
            shared_session_instance_id: manager
                .sessions
                .get(realtime_id)
                .map(|session| session.shared_session_instance_id.clone())
                .unwrap_or_else(new_shared_session_instance_id),
            kind,
            revision,
            payload,
        },
        None,
        None,
    )
}

/// Removes a remotely closed session only after its immutable signal binding
/// has been checked. The generation is captured before removal because the
/// manager drops the generation map entry together with the session. Callers
/// own the returned session and must invalidate any borrowed media endpoints
/// before closing its native peer.
fn take_remote_closed_session(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    revision: u64,
    shared_session_instance_id: &str,
) -> Result<(RealtimeSession, u64), Box<dyn std::error::Error + Send + Sync>> {
    let Some(session) = manager.sessions.get(realtime_id) else {
        return Err(boxed_message("realtime session does not exist"));
    };
    if session.peer_id != peer_id {
        return Err(boxed_message("realtime signal peer does not match session"));
    }
    if session.shared_session_instance_id != shared_session_instance_id {
        return Err(boxed_message(
            "realtime signal session instance does not match session",
        ));
    }
    if revision <= session.remote_revision {
        return Err(boxed_message("stale realtime signaling revision"));
    }
    let generation = manager
        .session_generation(realtime_id)
        .ok_or_else(|| boxed_message("realtime session generation missing"))?;
    let session = manager
        .remove_session(realtime_id)
        .ok_or_else(|| boxed_message("realtime session does not exist"))?;
    Ok((session, generation))
}

/// Applies a valid remote-close transition in one synchronous ownership scope.
/// Keeping the large WebRTC session out of the async signal handler's state
/// machine avoids retaining it across the task-supervisor await below.
pub(crate) fn close_remote_realtime_session(
    state: &RuntimeState,
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    revision: u64,
    shared_session_instance_id: &str,
) -> Result<u64, Box<dyn std::error::Error + Send + Sync>> {
    let (mut session, generation) = take_remote_closed_session(
        manager,
        realtime_id,
        peer_id,
        revision,
        shared_session_instance_id,
    )?;
    crate::realtime_media::invalidate_realtime(state, realtime_id);
    let _ = with_session_peer(&mut session, WebRtcPeer::close);
    Ok(generation)
}

pub(crate) fn apply_signal_with_driver(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    signal: InboundSignal,
    pending_driver: Option<RealtimeIoDriverHandle>,
    connection_session_id: Option<SessionId>,
) -> Result<SignalOutcome, Box<dyn std::error::Error + Send + Sync>> {
    let InboundSignal {
        shared_session_instance_id,
        kind,
        revision,
        payload,
    } = signal;
    validate_shared_session_instance_id(&shared_session_instance_id)?;
    if kind == RealtimeSignalKind::WebRtcClose {
        let (mut session, generation) = take_remote_closed_session(
            manager,
            realtime_id,
            peer_id,
            revision,
            &shared_session_instance_id,
        )?;
        let _ = with_session_peer(&mut session, WebRtcPeer::close);
        return Ok(SignalOutcome {
            peer_id: peer_id.to_string(),
            shared_session_instance_id,
            revision,
            generation,
            state: Some(RealtimeSessionState::Closed),
            outbound: None,
        });
    }

    if let Some(session) = manager.sessions.get(realtime_id) {
        if session.peer_id != peer_id {
            return Err(boxed_message("realtime signal peer does not match session"));
        }
        if session.shared_session_instance_id != shared_session_instance_id {
            return Err(boxed_message(
                "realtime signal session instance does not match session",
            ));
        }
        match kind {
            RealtimeSignalKind::IceCandidate => {
                if revision != session.ice_revision {
                    return Err(boxed_message("stale realtime ICE generation"));
                }
                if session.seen_candidates.contains(&payload) {
                    return Err(boxed_message("replayed realtime ICE candidate"));
                }
            }
            _ if revision <= session.remote_revision => {
                return Err(boxed_message("stale realtime signaling revision"));
            }
            _ => {}
        }
    }

    match kind {
        RealtimeSignalKind::WebRtcOffer => {
            let had_generation = manager.session_generations.contains_key(realtime_id);
            let existing = manager.sessions.remove(realtime_id);
            let had_existing = existing.is_some();
            let mut session = match existing {
                Some(session) => session,
                None => match pending_driver {
                    Some(driver) => RealtimeSession {
                        peer_id: peer_id.to_string(),
                        shared_session_instance_id: shared_session_instance_id.clone(),
                        connection_session_id,
                        peer: None,
                        driver: Some(driver),
                        revision: 0,
                        remote_revision: 0,
                        ice_revision: 0,
                        seen_candidates: HashSet::new(),
                    },
                    None => RealtimeSession {
                        peer_id: peer_id.to_string(),
                        shared_session_instance_id: shared_session_instance_id.clone(),
                        connection_session_id,
                        peer: Some(
                            WebRtcPeer::new(WebRtcConfig::default())
                                .expect("validated default WebRTC configuration"),
                        ),
                        driver: None,
                        revision: 0,
                        remote_revision: 0,
                        ice_revision: 0,
                        seen_candidates: HashSet::new(),
                    },
                },
            };
            let description = match String::from_utf8(payload)
                .map_err(|error| boxed_message(error.to_string()))
                .and_then(|sdp| {
                    SessionDescription::new(DescriptionType::Offer, sdp)
                        .map_err(|error| boxed_message(error.to_string()))
                }) {
                Ok(description) => description,
                Err(error) => {
                    if had_existing {
                        manager.insert_existing_session(realtime_id.to_string(), session);
                    }
                    return Err(error);
                }
            };
            if let Err(error) =
                with_session_peer(&mut session, |peer| peer.accept_remote_offer(description))
            {
                if had_existing {
                    manager.insert_existing_session(realtime_id.to_string(), session);
                }
                return Err(boxed_message(error.to_string()));
            }
            let answer = match with_session_peer(&mut session, WebRtcPeer::create_answer) {
                Ok(answer) => answer,
                Err(error) => {
                    if had_existing {
                        manager.insert_existing_session(realtime_id.to_string(), session);
                    }
                    return Err(boxed_message(error.to_string()));
                }
            };
            let answer_revision = with_session_peer(&mut session, |peer| {
                Ok::<_, WebRtcError>(peer.signaling_revision())
            })
            .map_err(|error| boxed_message(error.to_string()))?
            .max(revision);
            session.revision = answer_revision;
            session.remote_revision = revision;
            session.ice_revision = revision;
            session.seen_candidates.clear();
            let peer_id = session.peer_id.clone();
            if had_existing || had_generation {
                manager.insert_existing_session(realtime_id.to_string(), session);
            } else {
                manager.insert_new_session(realtime_id.to_string(), session);
            }
            let generation = manager
                .session_generation(realtime_id)
                .ok_or_else(|| boxed_message("realtime session generation missing"))?;
            Ok(SignalOutcome {
                peer_id: peer_id.clone(),
                shared_session_instance_id: shared_session_instance_id.clone(),
                revision: answer_revision,
                generation,
                state: Some(RealtimeSessionState::Negotiating),
                outbound: Some(OutboundSignal {
                    realtime_id: realtime_id.to_string(),
                    peer_id,
                    shared_session_instance_id: shared_session_instance_id.clone(),
                    kind: RealtimeSignalKind::WebRtcAnswer,
                    revision: answer_revision,
                    payload: answer.sdp.into_bytes(),
                }),
            })
        }
        RealtimeSignalKind::WebRtcAnswer => {
            let generation = manager.session_generation(realtime_id).unwrap_or_default();
            let session = manager
                .sessions
                .get_mut(realtime_id)
                .ok_or_else(|| boxed_message("realtime session does not exist"))?;
            let description =
                SessionDescription::new(DescriptionType::Answer, String::from_utf8(payload)?)?;
            with_session_peer(&mut *session, |peer| peer.accept_remote_answer(description))?;
            session.revision = with_session_peer(&mut *session, |peer| {
                Ok::<_, WebRtcError>(peer.signaling_revision())
            })?
            .max(revision);
            session.remote_revision = revision;
            Ok(SignalOutcome {
                peer_id: session.peer_id.clone(),
                shared_session_instance_id: session.shared_session_instance_id.clone(),
                revision: session.revision,
                generation,
                state: Some(RealtimeSessionState::Connected),
                outbound: None,
            })
        }
        RealtimeSignalKind::IceCandidate => {
            let generation = manager.session_generation(realtime_id).unwrap_or_default();
            let session = manager
                .sessions
                .get_mut(realtime_id)
                .ok_or_else(|| boxed_message("realtime session does not exist"))?;
            let candidate =
                IceCandidate::new(String::from_utf8(payload.clone())?, None, None, None)?;
            with_session_peer(&mut *session, |peer| {
                peer.add_remote_ice_candidate(candidate)
            })?;
            session.seen_candidates.insert(payload);
            Ok(SignalOutcome {
                peer_id: session.peer_id.clone(),
                shared_session_instance_id: session.shared_session_instance_id.clone(),
                revision: session.revision,
                generation,
                state: None,
                outbound: None,
            })
        }
        RealtimeSignalKind::IceRestart => {
            let generation = manager.session_generation(realtime_id).unwrap_or_default();
            let session = manager
                .sessions
                .get_mut(realtime_id)
                .ok_or_else(|| boxed_message("realtime session does not exist"))?;
            with_session_peer(&mut *session, WebRtcPeer::restart_ice)?;
            let offer = with_session_peer(&mut *session, WebRtcPeer::create_offer)?;
            session.revision = with_session_peer(&mut *session, |peer| {
                Ok::<_, WebRtcError>(peer.signaling_revision())
            })?
            .max(revision);
            session.remote_revision = revision;
            session.ice_revision = session.revision;
            session.seen_candidates.clear();
            Ok(SignalOutcome {
                peer_id: session.peer_id.clone(),
                shared_session_instance_id: session.shared_session_instance_id.clone(),
                revision: session.revision,
                generation,
                state: Some(RealtimeSessionState::Restarting),
                outbound: Some(OutboundSignal {
                    realtime_id: realtime_id.to_string(),
                    peer_id: session.peer_id.clone(),
                    shared_session_instance_id: session.shared_session_instance_id.clone(),
                    kind: RealtimeSignalKind::WebRtcOffer,
                    revision: session.revision,
                    payload: offer.sdp.into_bytes(),
                }),
            })
        }
        RealtimeSignalKind::ScreenShareConsent => Err(boxed_message(
            "screen-share consent must be handled before WebRTC state transitions",
        )),
        RealtimeSignalKind::Unspecified | RealtimeSignalKind::WebRtcClose => {
            Err(boxed_message("unsupported WebRTC signal kind"))
        }
    }
}
