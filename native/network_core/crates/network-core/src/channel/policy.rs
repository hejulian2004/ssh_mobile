use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};

use network_protocol::{NetworkError as ProtocolError, NetworkErrorCode};
use network_quic::MAX_CHANNEL_FRAME_BYTES;

use crate::connect::{PathLease, CAPABILITY_RELIABLE_MESSAGE};
use crate::connection::RouteTopology;
use crate::errors::CoreNetworkError;
use crate::events::protocol_error_with_peer;
use crate::runtime::RuntimeState;
use crate::session::SessionId;

pub(super) const MAX_DELIVERY_MESSAGE_PAYLOAD_BYTES: usize = MAX_CHANNEL_FRAME_BYTES - 1024;
static NEXT_BUSINESS_ENSURE_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ApplicationPayloadMode {
    Encrypted,
    Plaintext,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ApplicationPolicyError {
    SecurityPolicyMismatch,
    RelayRequiresE2ee,
}

impl std::fmt::Display for ApplicationPolicyError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::SecurityPolicyMismatch => formatter.write_str("security policy mismatch"),
            Self::RelayRequiresE2ee => formatter.write_str("Relay paths require E2EE"),
        }
    }
}

impl std::error::Error for ApplicationPolicyError {}

pub(super) fn application_payload_mode(
    policy: crate::crypto_handshake::path_handshake::E2eePolicy,
    topology: RouteTopology,
    has_crypto_context: bool,
) -> Result<ApplicationPayloadMode, ApplicationPolicyError> {
    if topology == RouteTopology::Relay
        && policy == crate::crypto_handshake::path_handshake::E2eePolicy::Disabled
    {
        return Err(ApplicationPolicyError::RelayRequiresE2ee);
    }
    match policy {
        crate::crypto_handshake::path_handshake::E2eePolicy::Required => {
            if has_crypto_context {
                Ok(ApplicationPayloadMode::Encrypted)
            } else {
                Err(ApplicationPolicyError::SecurityPolicyMismatch)
            }
        }
        crate::crypto_handshake::path_handshake::E2eePolicy::Disabled => {
            if has_crypto_context {
                Err(ApplicationPolicyError::SecurityPolicyMismatch)
            } else {
                Ok(ApplicationPayloadMode::Plaintext)
            }
        }
    }
}

pub(super) fn next_business_ensure_id(peer_id: &str) -> String {
    let sequence = NEXT_BUSINESS_ENSURE_ID.fetch_add(1, Ordering::Relaxed);
    format!("delivery/{peer_id}/{sequence}")
}

/// Ensure a Ready ReliableMessage path for one business operation.
///
/// `RuntimeState::ensure_business_path` starts the supervisor mailbox worker
/// while keeping maintenance disabled; the peer supervisor remains the sole
/// owner of the establishment attempt.
pub(super) async fn ensure_reliable_message_path(
    state: Arc<RuntimeState>,
    peer_id: &str,
    command_id: &str,
) -> Result<SessionId, CoreNetworkError> {
    RuntimeState::ensure_business_path(
        state,
        peer_id,
        command_id,
        network_protocol::CommunicationClass::ReliableMessage,
        CAPABILITY_RELIABLE_MESSAGE,
    )
    .await
}

pub(super) async fn validate_business_application_policy(
    state: &RuntimeState,
    peer_id: &str,
    session_id: SessionId,
) -> Result<(), ProtocolError> {
    let profile = state.path_profile(peer_id).await.ok_or_else(|| {
        protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "peer has no compatible ready path",
            "send_message",
            peer_id,
        )
    })?;
    let policy = state.e2ee_policy(peer_id).await;
    let has_context = state
        .crypto_context(peer_id, &session_id.wire_key())
        .await
        .is_ok();
    application_payload_mode(policy, profile.topology(), has_context).map_err(|error| {
        let code = match error {
            ApplicationPolicyError::SecurityPolicyMismatch => {
                NetworkErrorCode::SecurityPolicyMismatch
            }
            ApplicationPolicyError::RelayRequiresE2ee => NetworkErrorCode::RelayRequiresE2ee,
        };
        protocol_error_with_peer(code, error.to_string(), "send_message", peer_id)
    })?;
    Ok(())
}

/// Select one peer-owned ready path for one business attempt.
///
/// The runtime lookup is only for the peer's `PeerPathManager`; selection and
/// lease acquisition remain under that manager's lock. This adapter returns
/// the owning `PathLease`, never a copied route or carrier. A caller must drop
/// the lease after its single send.
pub(crate) async fn select_business_path_lease(
    state: &RuntimeState,
    peer_id: &str,
    required_capabilities: u8,
) -> Result<PathLease, CoreNetworkError> {
    state
        .acquire_path_lease(peer_id, required_capabilities)
        .await
}
