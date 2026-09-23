//! Realtime signal envelopes, consent checks, and relay wire sends.

use crate::events::{emit_realtime_signal, protocol_error, protocol_error_with_peer};
use crate::runtime::RuntimeState;
use network_protocol::{
    RealtimeSignalEnvelope, ScreenShareConsentDecision, ScreenShareConsentPurpose,
    ScreenShareMediaKind,
};
use network_relay::v2::RealtimeSignalKind as V2RealtimeSignalKind;
use network_webrtc::IceCandidate;
use prost::Message;
use rand::RngCore;

use super::*;

pub(crate) async fn forward_local_candidate(
    state: &RuntimeState,
    realtime_id: &str,
    peer_id: &str,
    candidate: IceCandidate,
) {
    let (session_peer_id, shared_session_instance_id, revision) = {
        let sessions = state.realtime.lock().await;
        let Some(session) = sessions.sessions.get(realtime_id) else {
            return;
        };
        (
            session.peer_id.clone(),
            session.shared_session_instance_id.clone(),
            session.ice_revision,
        )
    };
    if session_peer_id != peer_id {
        return;
    }
    let payload = candidate.candidate.into_bytes();
    let outbound = OutboundSignal {
        realtime_id: realtime_id.to_owned(),
        peer_id: peer_id.to_owned(),
        shared_session_instance_id,
        kind: RealtimeSignalKind::IceCandidate,
        revision,
        payload,
    };
    if let Err(error) = send_signal(state, &outbound).await {
        tracing::debug!(peer_id, error = %error.message, "failed to forward WebRTC ICE candidate");
        return;
    }
    emit_realtime_signal(
        &state.event_tx,
        realtime_id,
        peer_id,
        RealtimeSignalKind::IceCandidate as i32,
        revision,
        outbound.payload,
    );
}

pub(crate) async fn validate_peer(
    state: &RuntimeState,
    peer_id: &str,
) -> Result<(), network_protocol::NetworkError> {
    if peer_id.is_empty() || peer_id.len() > 128 || !state.peers.read().await.contains_key(peer_id)
    {
        return Err(protocol_error_with_peer(
            network_protocol::NetworkErrorCode::NoRoute,
            "realtime peer is not registered",
            "realtime",
            peer_id,
        ));
    }
    Ok(())
}

const SHARED_SESSION_INSTANCE_ID_BYTES: usize = 16;
const SHARED_SESSION_INSTANCE_ID_HEX_LEN: usize = SHARED_SESSION_INSTANCE_ID_BYTES * 2;

pub(crate) fn new_shared_session_instance_id() -> String {
    let mut bytes = [0_u8; SHARED_SESSION_INSTANCE_ID_BYTES];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

pub(crate) fn validate_shared_session_instance_id(
    id: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if id.len() != SHARED_SESSION_INSTANCE_ID_HEX_LEN
        || id != id.to_ascii_lowercase()
        || hex::decode(id).map_or(true, |bytes| {
            bytes.len() != SHARED_SESSION_INSTANCE_ID_BYTES
        })
    {
        return Err(boxed_message(
            "shared_session_instance_id must be 32 lowercase hexadecimal characters",
        ));
    }
    Ok(())
}

pub(crate) fn encode_realtime_signal_payload(
    shared_session_instance_id: &str,
    payload: &[u8],
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    validate_shared_session_instance_id(shared_session_instance_id)?;
    let encoded = RealtimeSignalEnvelope {
        shared_session_instance_id: shared_session_instance_id.to_owned(),
        payload: payload.to_vec(),
    }
    .encode_to_vec();
    if encoded.len() > MAX_REALTIME_SIGNAL_PAYLOAD_BYTES {
        return Err(boxed_message("realtime signal envelope is outside bounds"));
    }
    Ok(encoded)
}

pub(crate) fn decode_realtime_signal_payload(
    payload: &[u8],
) -> Result<(String, Vec<u8>), Box<dyn std::error::Error + Send + Sync>> {
    if payload.is_empty() || payload.len() > MAX_REALTIME_SIGNAL_PAYLOAD_BYTES {
        return Err(boxed_message("realtime signal envelope is outside bounds"));
    }
    let envelope = RealtimeSignalEnvelope::decode(payload)
        .map_err(|error| boxed_message(format!("malformed realtime signal envelope: {error}")))?;
    validate_shared_session_instance_id(&envelope.shared_session_instance_id)?;
    if envelope.payload.len() > MAX_REALTIME_SIGNAL_PAYLOAD_BYTES {
        return Err(boxed_message("realtime signal payload is outside bounds"));
    }
    Ok((envelope.shared_session_instance_id, envelope.payload))
}

pub(crate) fn validate_realtime_id(id: &str) -> Result<(), network_protocol::NetworkError> {
    if id.len() != 32
        || id != id.to_ascii_lowercase()
        || hex::decode(id).map_or(true, |bytes| bytes.len() != 16)
    {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "realtime_id must be 32 lowercase hexadecimal characters",
        ));
    }
    Ok(())
}

pub(crate) fn validate_signal(
    kind: RealtimeSignalKind,
    revision: u64,
    payload: &[u8],
) -> Result<(), network_protocol::NetworkError> {
    if revision == 0 || payload.len() > MAX_REALTIME_SIGNAL_PAYLOAD_BYTES {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "WebRTC signal revision or payload is outside bounds",
        ));
    }
    if kind == RealtimeSignalKind::IceCandidate && payload.len() > MAX_ICE_CANDIDATE_BYTES {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "ICE candidate payload is outside bounds",
        ));
    }
    if !matches!(
        kind,
        RealtimeSignalKind::WebRtcClose
            | RealtimeSignalKind::IceRestart
            | RealtimeSignalKind::IceCandidate
    ) && payload.is_empty()
    {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "WebRTC signal payload must not be empty",
        ));
    }
    if kind == RealtimeSignalKind::ScreenShareConsent && payload.len() > 4096 {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "screen-share consent payload is outside bounds",
        ));
    }
    Ok(())
}

/// Validates the typed ScreenShareConsentV2 payload at the native control
/// boundary. `expected_sender_peer_id` is supplied for inbound signals where
/// the authenticated realtime binding is authoritative; local outgoing
/// commands perform the structural checks without guessing the sender ID.
pub(crate) fn validate_screen_share_consent(
    payload: &[u8],
    expected_realtime_id: &str,
    expected_sender_peer_id: Option<&str>,
    expected_shared_session_instance_id: Option<&str>,
) -> Result<ScreenShareConsentV2, Box<dyn std::error::Error + Send + Sync>> {
    validate_screen_share_consent_at(
        payload,
        expected_realtime_id,
        expected_sender_peer_id,
        expected_shared_session_instance_id,
        crate::events::unix_timestamp_ms().max(0) as u64,
    )
}

#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn validate_screen_share_consent_at(
    payload: &[u8],
    expected_realtime_id: &str,
    expected_sender_peer_id: Option<&str>,
    expected_shared_session_instance_id: Option<&str>,
    now_ms: u64,
) -> Result<ScreenShareConsentV2, Box<dyn std::error::Error + Send + Sync>> {
    if payload.is_empty() || payload.len() > 4096 {
        return Err(boxed_message(
            "screen-share consent payload is outside bounds",
        ));
    }
    let consent = ScreenShareConsentV2::decode(payload)
        .map_err(|error| boxed_message(format!("malformed screen-share consent: {error}")))?;
    if consent.schema_version != 2 {
        return Err(boxed_message(
            "unsupported screen-share consent schema version",
        ));
    }
    if consent.operation_id.is_empty() || consent.operation_id.len() > 128 {
        return Err(boxed_message(
            "screen-share consent operation_id is outside bounds",
        ));
    }
    if consent.realtime_id != expected_realtime_id {
        return Err(boxed_message(
            "screen-share consent realtime_id does not match signal",
        ));
    }
    validate_shared_session_instance_id(&consent.shared_session_instance_id)?;
    if let Some(expected) = expected_shared_session_instance_id {
        if consent.shared_session_instance_id != expected {
            return Err(boxed_message(
                "screen-share consent session instance does not match signal",
            ));
        }
    }
    if consent.issued_at_ms == 0
        || consent.expires_at_ms <= consent.issued_at_ms
        || consent.expires_at_ms.saturating_sub(consent.issued_at_ms)
            > SCREEN_SHARE_CONSENT_MAX_LIFETIME_MS
    {
        return Err(boxed_message("screen-share consent expiration is invalid"));
    }
    if consent.issued_at_ms > now_ms.saturating_add(SCREEN_SHARE_CONSENT_ALLOWED_FUTURE_SKEW_MS)
        || consent.expires_at_ms <= now_ms
    {
        return Err(boxed_message("screen-share consent is not fresh"));
    }
    if consent.sender_peer_id.is_empty() || consent.sender_peer_id.len() > 128 {
        return Err(boxed_message(
            "screen-share consent sender_peer_id is outside bounds",
        ));
    }
    if let Some(expected) = expected_sender_peer_id {
        if consent.sender_peer_id != expected {
            return Err(boxed_message(
                "screen-share consent sender does not match peer binding",
            ));
        }
    }
    if ScreenShareConsentDecision::try_from(consent.decision)
        .map_err(|_| boxed_message("unknown screen-share consent decision"))?
        == ScreenShareConsentDecision::Unspecified
    {
        return Err(boxed_message(
            "screen-share consent decision is unspecified",
        ));
    }
    if ScreenShareConsentPurpose::try_from(consent.purpose)
        .map_err(|_| boxed_message("unknown screen-share consent purpose"))?
        != ScreenShareConsentPurpose::ScreenShare
    {
        return Err(boxed_message("screen-share consent purpose is unsupported"));
    }
    if ScreenShareMediaKind::try_from(consent.media)
        .map_err(|_| boxed_message("unknown screen-share media kind"))?
        != ScreenShareMediaKind::ScreenVideo
    {
        return Err(boxed_message("screen-share media kind is unsupported"));
    }
    if !consent.requires_acceptance || consent.action_revision == 0 {
        return Err(boxed_message(
            "screen-share consent acceptance/revision is invalid",
        ));
    }
    Ok(consent)
}

/// §22：WebRTC 信令经 v2 Relay Control Plane 路由（`signal_webrtc`），与媒体面
/// (P2P/TURN) 分离。v1 Relay 数据面信令路径已在 Step 11 删除。
pub(crate) async fn send_signal(
    state: &RuntimeState,
    signal: &OutboundSignal,
) -> Result<(), network_protocol::NetworkError> {
    let Some(control) = state.relay.control.read().await.clone() else {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::RelayError,
            "Relay signaling route is unavailable",
        ));
    };
    if !control.is_usable().await {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::RelayError,
            "Relay signaling route is disconnected",
        ));
    }
    let payload =
        encode_realtime_signal_payload(&signal.shared_session_instance_id, &signal.payload)
            .map_err(|error| {
                realtime_error(
                    network_protocol::NetworkErrorCode::InvalidArgument,
                    error.to_string(),
                    "send_realtime_signal",
                    &signal.peer_id,
                )
            })?;
    let kind = to_v2_signal_kind(signal.kind);
    control
        .signal_webrtc_wire_kind(
            &signal.realtime_id,
            &signal.peer_id,
            kind,
            signal.revision,
            &payload,
        )
        .await
        .map_err(|error| {
            realtime_error(
                network_protocol::NetworkErrorCode::RelayError,
                error.to_string(),
                "send_realtime_signal",
                &signal.peer_id,
            )
        })
}

/// Maps a network-protocol WebRTC signal to its frozen Relay V2 wire number.
///
/// Screen-share consent is defined by Network V2, while Relay V2's descriptor
/// remains frozen.  Its value (6) is intentionally sent as an unknown enum
/// number and forwarded transparently by the Relay control plane.
pub(crate) fn to_v2_signal_kind(kind: RealtimeSignalKind) -> i32 {
    match kind {
        RealtimeSignalKind::WebRtcOffer => V2RealtimeSignalKind::Offer as i32,
        RealtimeSignalKind::WebRtcAnswer => V2RealtimeSignalKind::Answer as i32,
        RealtimeSignalKind::IceCandidate => V2RealtimeSignalKind::IceCandidate as i32,
        RealtimeSignalKind::IceRestart => V2RealtimeSignalKind::IceRestart as i32,
        RealtimeSignalKind::WebRtcClose => V2RealtimeSignalKind::Close as i32,
        RealtimeSignalKind::ScreenShareConsent => 6,
        RealtimeSignalKind::Unspecified => V2RealtimeSignalKind::Unspecified as i32,
    }
}

pub(crate) fn realtime_error(
    code: network_protocol::NetworkErrorCode,
    message: impl Into<String>,
    operation: &str,
    peer_id: &str,
) -> network_protocol::NetworkError {
    protocol_error_with_peer(code, message, operation, peer_id)
}

pub(crate) fn boxed_protocol_error(
    error: network_protocol::NetworkError,
) -> Box<dyn std::error::Error + Send + Sync> {
    boxed_message(error.message)
}

pub(crate) fn boxed_message(
    message: impl Into<String>,
) -> Box<dyn std::error::Error + Send + Sync> {
    std::io::Error::new(std::io::ErrorKind::InvalidData, message.into()).into()
}
