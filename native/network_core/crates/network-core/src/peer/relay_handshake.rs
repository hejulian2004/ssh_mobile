use network_identity::DeviceIdentity;
use network_protocol::{NetworkError as ProtocolError, NetworkErrorCode};
use network_relay::RelayDataClient;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::time::timeout;

use crate::crypto_handshake::SessionCryptoMaterial;
use crate::events::protocol_error_with_peer;
use crate::runtime::{
    ConnectionAdmissionLease, RuntimeState, MAX_PENDING_RELAY_CRYPTO_HANDSHAKES,
    PEER_CONNECT_TIMEOUT,
};
use crate::session::SessionId;

pub(crate) async fn establish_relay_crypto(
    state: &RuntimeState,
    data: Arc<RelayDataClient>,
    peer_id: &str,
    session_id: SessionId,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
) -> Result<(SessionCryptoMaterial, ConnectionAdmissionLease), ProtocolError> {
    let e2ee_policy = state.e2ee_policy(peer_id).await;
    if e2ee_policy != crate::crypto_handshake::path_handshake::E2eePolicy::Required {
        state.fail_session(peer_id, session_id).await;
        return Err(protocol_error_with_peer(
            NetworkErrorCode::AuthenticationFailed,
            "Relay paths require application E2EE",
            "connect",
            peer_id,
        ));
    }
    let session_token = session_id.wire_key();
    let (mut handshake, hello) =
        crate::crypto_handshake::RelayInitiatorHandshake::start_with_policy(
            identity,
            &session_token,
            e2ee_policy,
        )
        .map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                "Relay application E2EE handshake could not start",
                "connect",
                peer_id,
            )
        })?;
    let key = format!("{peer_id}/{session_token}");
    let (response_tx, mut response_rx) = mpsc::channel(3);
    let mut waiters = state.relay.crypto_waiters.write().await;
    if waiters.len() >= MAX_PENDING_RELAY_CRYPTO_HANDSHAKES && !waiters.contains_key(&key) {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::RelayError,
            "Relay application E2EE handshake queue is full",
            "connect",
            peer_id,
        ));
    }
    waiters.insert(key.clone(), response_tx);
    drop(waiters);
    let result = async {
        crate::relay::send_relay_crypto(
            &data,
            &session_token,
            crate::crypto_handshake::RELAY_CRYPTO_HELLO,
            &hello,
        )
        .await
        .map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "Relay application E2EE hello could not be sent",
                "connect",
                peer_id,
            )
        })?;
        let response = receive_relay_crypto_step(
            &mut response_rx,
            crate::crypto_handshake::RELAY_CRYPTO_RESPONSE,
            peer_id,
        )
        .await?;
        let final_message = handshake
            .accept_response(&response, peer_id, expected_peer_public_key)
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::AuthenticationFailed,
                    "Relay application E2EE identity proof failed",
                    "connect",
                    peer_id,
                )
            })?;
        crate::relay::send_relay_crypto(
            &data,
            &session_token,
            crate::crypto_handshake::RELAY_CRYPTO_FINAL,
            &final_message,
        )
        .await
        .map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "Relay application E2EE final message could not be sent",
                "connect",
                peer_id,
            )
        })?;
        let encrypted_seed = receive_relay_crypto_step(
            &mut response_rx,
            crate::crypto_handshake::RELAY_CRYPTO_ROOT_SEED,
            peer_id,
        )
        .await?;
        let confirmation = handshake.accept_root_seed(&encrypted_seed).map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                "Relay application E2EE RootSeed was rejected",
                "connect",
                peer_id,
            )
        })?;
        let remote_session_binding = confirmation.remote_session_binding().to_string();
        let admission = state
            .admit_authenticated_session(peer_id, Some(session_id), &remote_session_binding)
            .await
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::AuthenticationFailed,
                    "Relay Session continuity check failed",
                    "connect",
                    peer_id,
                )
            })?;
        let (confirmation, encrypted_confirm) = confirmation
            .confirm(admission.session_id.wire_key())
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::AuthenticationFailed,
                    "Relay application E2EE root confirmation is invalid",
                    "connect",
                    peer_id,
                )
            })?;
        crate::relay::send_relay_crypto(
            &data,
            &session_token,
            crate::crypto_handshake::RELAY_CRYPTO_ROOT_CONFIRM,
            &encrypted_confirm,
        )
        .await
        .map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "Relay application E2EE root confirmation could not be sent",
                "connect",
                peer_id,
            )
        })?;
        let encrypted_accept = receive_relay_crypto_step(
            &mut response_rx,
            crate::crypto_handshake::RELAY_CRYPTO_ACCEPT,
            peer_id,
        )
        .await?;
        let material = confirmation.accept(&encrypted_accept).map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                "Relay application E2EE acceptance failed",
                "connect",
                peer_id,
            )
        })?;
        if material.local_session_binding != admission.session_id.wire_key() {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                "Relay application E2EE local Session binding is invalid",
                "connect",
                peer_id,
            ));
        }
        // RelayDataClient::connect_reservation() has already consumed the
        // reservation's PairReady lifecycle frame. PathHandshakeV2 metadata
        // and proof were authenticated inside this Noise exchange; there is
        // no independent wire handshake or extra business gate here.
        Ok((material, admission))
    }
    .await;
    state.relay.crypto_waiters.write().await.remove(&key);
    result
}

pub(crate) async fn receive_relay_crypto_step(
    receiver: &mut mpsc::Receiver<(u8, Vec<u8>)>,
    expected_step: u8,
    peer_id: &str,
) -> Result<Vec<u8>, ProtocolError> {
    match timeout(PEER_CONNECT_TIMEOUT, receiver.recv()).await {
        Ok(Some((step, payload))) if step == expected_step => Ok(payload),
        Ok(Some(_)) => Err(protocol_error_with_peer(
            NetworkErrorCode::AuthenticationFailed,
            "Relay application E2EE handshake step is out of order",
            "connect",
            peer_id,
        )),
        _ => Err(protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "Relay application E2EE handshake timed out",
            "connect",
            peer_id,
        )),
    }
}
