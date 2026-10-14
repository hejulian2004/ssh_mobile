//! Session-bound application-encrypted signaling over authenticated Direct paths.
//! Only metadata crosses the reliable carrier; RTP remains native WebRTC-owned.
use std::sync::Arc;

use network_protocol::NetworkErrorCode;
use network_relay::v2::RealtimeSignal;
use prost::Message;

use crate::connect::CAPABILITY_RELIABLE_MESSAGE;
use crate::connection::{GenericFrameKind, RouteTopology};
use crate::runtime::RuntimeState;

use super::{boxed_message, handle_v2_realtime_signal, realtime_error, OutboundSignal};

const MAGIC: &[u8; 5] = b"SMRS2";
const MAX_FRAME: usize = network_quic::MAX_CHANNEL_FRAME_BYTES;
const MAX_SESSION_ID: usize = 128;
type FrameParts<'a> = (&'a str, &'a [u8], &'a [u8]);

fn header(session_id: &str) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    if session_id.is_empty() || session_id.len() > MAX_SESSION_ID {
        return Err(boxed_message("invalid direct signaling session binding"));
    }
    let mut bytes = MAGIC.to_vec();
    bytes.extend_from_slice(&(session_id.len() as u16).to_be_bytes());
    bytes.extend_from_slice(session_id.as_bytes());
    Ok(bytes)
}

fn split_frame(bytes: &[u8]) -> Result<FrameParts<'_>, Box<dyn std::error::Error + Send + Sync>> {
    if bytes.len() < 8 || bytes.len() > MAX_FRAME || &bytes[..5] != MAGIC {
        return Err(boxed_message("direct signaling frame outside bounds"));
    }
    let length = u16::from_be_bytes([bytes[5], bytes[6]]) as usize;
    if length == 0 || length > MAX_SESSION_ID || 7 + length >= bytes.len() {
        return Err(boxed_message("invalid direct signaling session binding"));
    }
    let id = std::str::from_utf8(&bytes[7..7 + length])?;
    Ok((id, &bytes[..7 + length], &bytes[7 + length..]))
}

pub(super) async fn try_send_direct(
    state: &RuntimeState,
    signal: &OutboundSignal,
) -> Result<bool, network_protocol::NetworkError> {
    let retained = state
        .realtime
        .lock()
        .await
        .sessions
        .get(&signal.realtime_id)
        .and_then(|session| session.direct_signaling_path.clone());
    let lease = if let Some(retained) = retained {
        retained
    } else {
        let Ok(lease) = state
            .acquire_path_lease(&signal.peer_id, CAPABILITY_RELIABLE_MESSAGE)
            .await
        else {
            return Ok(false);
        };
        Arc::new(lease)
    };
    if lease.profile().topology() != RouteTopology::Direct {
        return Ok(false);
    }
    let result = async {
        let session = state
            .connection_sessions
            .current_session_id(&signal.peer_id)
            .await
            .ok_or_else(|| boxed_message("direct signaling session unavailable"))?;
        if !lease.is_active()
            || !state
                .route_is_authorized(&signal.peer_id, RouteTopology::Direct)
                .await
        {
            return Err(boxed_message(
                "direct signaling carrier is no longer authorized",
            ));
        }
        if state
            .realtime
            .lock()
            .await
            .sessions
            .get(&signal.realtime_id)
            .and_then(|s| s.connection_session_id)
            .is_some_and(|bound| bound != session)
        {
            return Err(boxed_message("direct signaling generation changed"));
        }
        {
            let mut manager = state.realtime.lock().await;
            if let Some(owner) = manager.sessions.get_mut(&signal.realtime_id) {
                if owner.peer_id != signal.peer_id
                    || owner.shared_session_instance_id != signal.shared_session_instance_id
                {
                    return Err(boxed_message("direct signaling owner mismatch"));
                }
                if owner.connection_session_id == Some(session)
                    && owner.direct_signaling_path.is_none()
                {
                    owner.direct_signaling_path = Some(Arc::clone(&lease));
                }
            }
        }
        let local_id = state
            .lifecycle
            .identity
            .read()
            .await
            .as_ref()
            .map(|identity| identity.device_id.clone())
            .ok_or_else(|| boxed_message("direct signaling identity unavailable"))?;
        let encoded = RealtimeSignal {
            request_id: 1,
            realtime_id: signal.realtime_id.clone(),
            target_device_id: signal.peer_id.clone(),
            source_device_id: local_id,
            kind: super::wire::to_v2_signal_kind(signal.kind),
            revision: signal.revision,
            payload: super::wire::encode_realtime_signal_payload(
                &signal.shared_session_instance_id,
                &signal.payload,
            )?,
        }
        .encode_to_vec();
        if encoded.len() > MAX_FRAME - 512 {
            return Err(boxed_message("direct signaling payload outside bounds"));
        }
        let key = session.wire_key();
        let mut frame = header(&key)?;
        let encrypted = state
            .encrypt_application_payload(&signal.peer_id, &key, &frame, &encoded)
            .await?;
        frame.extend_from_slice(&encrypted);
        if frame.len() > MAX_FRAME
            || state
                .connection_sessions
                .current_session_id(&signal.peer_id)
                .await
                != Some(session)
        {
            return Err(boxed_message(
                "direct signaling session changed during send",
            ));
        }
        state
            .path_send_channel_frame_for_lease(&lease, "", GenericFrameKind::RealtimeSignal, &frame)
            .await
    }
    .await;
    result.map(|()| true).map_err(|_| {
        realtime_error(
            NetworkErrorCode::NoRoute,
            "Authenticated direct screen-share signaling failed.",
            "send_realtime_signal",
            &signal.peer_id,
        )
    })
}

pub(crate) async fn handle_direct_signal(
    state: &Arc<RuntimeState>,
    authenticated_peer: &str,
    frame: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut phase = "authorization";
    let result = async {
        if !state
            .route_is_authorized(authenticated_peer, RouteTopology::Direct)
            .await
        {
            return Err(boxed_message("direct signaling is not authorized"));
        }
        phase = "frame";
        let (session_id, aad, encrypted) = split_frame(frame)?;
        phase = "binding";
        let session = state
            .connection_sessions
            .current_session_id(authenticated_peer)
            .await
            .ok_or_else(|| boxed_message("direct signaling session unavailable"))?;
        if state
            .connection_sessions
            .current_remote_session_binding(authenticated_peer)
            .await
            .as_deref()
            != Some(session_id)
        {
            return Err(boxed_message("stale direct signaling session"));
        }
        phase = "authentication";
        let decoded = state
            .decrypt_application_payload(authenticated_peer, session_id, aad, encrypted)
            .await?;
        phase = "envelope";
        let signal = RealtimeSignal::decode(decoded.as_slice())?;
        if signal.source_device_id != authenticated_peer
            || signal.revision == 0
            || state
                .connection_sessions
                .current_session_id(authenticated_peer)
                .await
                != Some(session)
        {
            return Err(boxed_message(
                "direct signaling authenticated binding mismatch",
            ));
        }
        super::validate_realtime_id(&signal.realtime_id).map_err(super::boxed_protocol_error)?;
        phase = "dispatch";
        handle_v2_realtime_signal(state, &signal).await
    }
    .await;
    if result.is_err() {
        // Rejection remains fail-closed. Publish only a fixed stage name on
        // the existing bounded diagnostics lane; never echo payload or IDs.
        let error = realtime_error(
            NetworkErrorCode::IoError,
            format!("Screen-share direct rejection: {phase}"),
            "receive_realtime_signal",
            authenticated_peer,
        );
        let _ = crate::commands::emit_peer_diagnostics_with_error(
            state,
            authenticated_peer.to_owned(),
            Some(error),
        )
        .await;
    }
    result
}

#[cfg(test)]
#[path = "../tests/realtime_direct.rs"]
mod tests;
