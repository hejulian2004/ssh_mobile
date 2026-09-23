use network_identity::DeviceIdentity;
use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;
use tokio::sync::RwLock;

use super::exchange::{InitiatorRootExchange, ResponderRootExchange};
use super::noise::{CryptoHandshakeError, NoiseHandshake, SessionCryptoMaterial};
use super::path_handshake;
use super::payload_hello::{
    hello_payload_with_path, parse_hello_with_path, parse_proof_identity_with_path,
    proof_payload_with_signature_with_path, relay_path_metadata, validate_proof_with_path,
    validate_relay_path_metadata, verify_proof_signature_with_path,
};
use super::payload_root::validate_binding;
use super::MAX_HANDSHAKE_FRAME_BYTES;
/// Relay carries the Noise XX messages plus the post-handshake root exchange
/// as six opaque control payloads.
/// The relay event loop owns the message exchange; these small state objects
/// keep the handshake transcript and identity proof in this crypto module.
pub(crate) struct RelayInitiatorHandshake {
    handshake: NoiseHandshake,
    session_binding: String,
    path_metadata: path_handshake::PathHandshakeMetadata,
    path_security: path_handshake::PathSecurity,
}

pub(crate) struct RelayInitiatorConfirmation {
    exchange: InitiatorRootExchange,
}

impl RelayInitiatorHandshake {
    #[cfg(test)]
    pub(crate) fn start(
        identity: Arc<DeviceIdentity>,
        session_binding: &str,
    ) -> Result<(Self, Vec<u8>), CryptoHandshakeError> {
        Self::start_with_policy(
            identity,
            session_binding,
            path_handshake::E2eePolicy::Required,
        )
    }

    pub(crate) fn start_with_policy(
        identity: Arc<DeviceIdentity>,
        session_binding: &str,
        e2ee_policy: path_handshake::E2eePolicy,
    ) -> Result<(Self, Vec<u8>), CryptoHandshakeError> {
        validate_binding(session_binding)?;
        let path_metadata = relay_path_metadata(session_binding, e2ee_policy)?;
        let path_security = validate_relay_path_metadata(&path_metadata, e2ee_policy)?;
        let mut handshake = NoiseHandshake::new(identity, true)?;
        let message =
            handshake.write(&hello_payload_with_path(session_binding, &path_metadata)?)?;
        Ok((
            Self {
                handshake,
                session_binding: session_binding.to_string(),
                path_metadata,
                path_security,
            },
            message,
        ))
    }

    pub(crate) fn accept_response(
        &mut self,
        response: &[u8],
        expected_peer_id: &str,
        expected_peer_identity_key: [u8; 32],
    ) -> Result<Vec<u8>, CryptoHandshakeError> {
        let responder_payload = self.handshake.read(response)?;
        let _remote_session_binding = validate_proof_with_path(
            &responder_payload,
            2,
            expected_peer_id,
            &expected_peer_identity_key,
            &self.handshake,
            &self.session_binding,
            &self.path_metadata,
        )?;
        let initiator_proof = proof_payload_with_signature_with_path(
            &self.handshake,
            1,
            &self.session_binding,
            &self.session_binding,
            &self.path_metadata,
        )?;
        self.handshake.write(&initiator_proof)
    }

    pub(crate) fn accept_root_seed(
        self,
        encrypted_seed: &[u8],
    ) -> Result<RelayInitiatorConfirmation, CryptoHandshakeError> {
        let established = self
            .handshake
            .into_established_with_security(self.session_binding, self.path_security)?;
        let exchange = established.accept_root_seed(encrypted_seed)?;
        Ok(RelayInitiatorConfirmation { exchange })
    }
}

impl RelayInitiatorConfirmation {
    pub(crate) fn remote_session_binding(&self) -> &str {
        &self.exchange.remote_session_binding
    }

    pub(crate) fn confirm(
        mut self,
        local_session_binding: String,
    ) -> Result<(Self, Vec<u8>), CryptoHandshakeError> {
        let (exchange, encrypted_confirm) = self.exchange.confirm(local_session_binding)?;
        self.exchange = exchange;
        Ok((self, encrypted_confirm))
    }

    pub(crate) fn accept(
        self,
        encrypted_accept: &[u8],
    ) -> Result<SessionCryptoMaterial, CryptoHandshakeError> {
        self.exchange.accept(encrypted_accept)
    }
}

pub(crate) struct RelayResponderHandshake {
    handshake: NoiseHandshake,
    session_binding: String,
    path_metadata: path_handshake::PathHandshakeMetadata,
    path_security: path_handshake::PathSecurity,
}

pub(crate) struct RelayResponderConfirmation<T> {
    peer_id: String,
    exchange: ResponderRootExchange,
    admission: T,
}

impl RelayResponderHandshake {
    pub(crate) fn accept_hello(
        identity: Arc<DeviceIdentity>,
        hello: &[u8],
    ) -> Result<(Self, Vec<u8>), CryptoHandshakeError> {
        Self::accept_hello_with_policy(identity, hello, path_handshake::E2eePolicy::Required)
    }

    pub(crate) fn accept_hello_with_policy(
        identity: Arc<DeviceIdentity>,
        hello: &[u8],
        e2ee_policy: path_handshake::E2eePolicy,
    ) -> Result<(Self, Vec<u8>), CryptoHandshakeError> {
        let mut handshake = NoiseHandshake::new(identity, false)?;
        let (session_binding, path_metadata) = parse_hello_with_path(&handshake.read(hello)?)?;
        let path_security = validate_relay_path_metadata(&path_metadata, e2ee_policy)?;
        let responder_proof = proof_payload_with_signature_with_path(
            &handshake,
            2,
            &session_binding,
            &session_binding,
            &path_metadata,
        )?;
        let response = handshake.write(&responder_proof)?;
        Ok((
            Self {
                handshake,
                session_binding,
                path_metadata,
                path_security,
            },
            response,
        ))
    }

    pub(crate) async fn accept_final<F, Fut, T>(
        mut self,
        final_message: &[u8],
        trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
        resolve_local_session_binding: F,
    ) -> Result<(String, RelayResponderConfirmation<T>, Vec<u8>), CryptoHandshakeError>
    where
        F: FnOnce(&str, &str) -> Fut,
        Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
    {
        let initiator_payload = self.handshake.read(final_message)?;
        let (peer_id, peer_key, peer_session_binding) = parse_proof_identity_with_path(
            &initiator_payload,
            1,
            &self.handshake,
            &self.session_binding,
            &self.path_metadata,
        )?;
        if peer_session_binding != self.session_binding {
            return Err(CryptoHandshakeError::InvalidBinding);
        }
        let expected = trusted_peer_keys
            .read()
            .await
            .get(&peer_id)
            .copied()
            .ok_or(CryptoHandshakeError::UntrustedIdentity)?;
        if expected != peer_key {
            return Err(CryptoHandshakeError::UntrustedIdentity);
        }
        verify_proof_signature_with_path(
            &initiator_payload,
            &peer_id,
            &self.session_binding,
            &peer_session_binding,
            &peer_key,
            &self.path_metadata,
        )?;
        let (local_session_binding, admission) =
            resolve_local_session_binding(&peer_id, &self.session_binding).await?;
        let established = self
            .handshake
            .into_established_with_security(self.session_binding.clone(), self.path_security)?;
        let (exchange, encrypted_seed) = established.begin_responder(&local_session_binding)?;
        Ok((
            peer_id.clone(),
            RelayResponderConfirmation {
                peer_id,
                exchange,
                admission,
            },
            encrypted_seed,
        ))
    }
}

impl<T> RelayResponderConfirmation<T> {
    pub(crate) fn accept_root_confirm(
        self,
        encrypted_confirm: &[u8],
    ) -> Result<(String, Vec<u8>, SessionCryptoMaterial, T), CryptoHandshakeError> {
        let (encrypted_accept, material) = self.exchange.accept_confirm(encrypted_confirm)?;
        Ok((self.peer_id, encrypted_accept, material, self.admission))
    }
}

pub(crate) const RELAY_CRYPTO_HELLO: u8 = 1;
pub(crate) const RELAY_CRYPTO_RESPONSE: u8 = 2;
pub(crate) const RELAY_CRYPTO_FINAL: u8 = 3;
pub(crate) const RELAY_CRYPTO_ROOT_SEED: u8 = 4;
pub(crate) const RELAY_CRYPTO_ROOT_CONFIRM: u8 = 5;
pub(crate) const RELAY_CRYPTO_ACCEPT: u8 = 6;
pub(crate) fn encode_relay_frame(
    step: u8,
    payload: &[u8],
) -> Result<Vec<u8>, CryptoHandshakeError> {
    if !matches!(
        step,
        RELAY_CRYPTO_HELLO
            | RELAY_CRYPTO_RESPONSE
            | RELAY_CRYPTO_FINAL
            | RELAY_CRYPTO_ROOT_SEED
            | RELAY_CRYPTO_ROOT_CONFIRM
            | RELAY_CRYPTO_ACCEPT
    ) || payload.is_empty()
        || payload.len() > MAX_HANDSHAKE_FRAME_BYTES
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    let mut frame = Vec::with_capacity(payload.len() + 1);
    frame.push(step);
    frame.extend_from_slice(payload);
    Ok(frame)
}

pub(crate) fn decode_relay_frame(frame: &[u8]) -> Result<(u8, &[u8]), CryptoHandshakeError> {
    let (&step, payload) = frame.split_first().ok_or(CryptoHandshakeError::Invalid)?;
    if !matches!(
        step,
        RELAY_CRYPTO_HELLO
            | RELAY_CRYPTO_RESPONSE
            | RELAY_CRYPTO_FINAL
            | RELAY_CRYPTO_ROOT_SEED
            | RELAY_CRYPTO_ROOT_CONFIRM
            | RELAY_CRYPTO_ACCEPT
    ) || payload.is_empty()
        || payload.len() > MAX_HANDSHAKE_FRAME_BYTES
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    Ok((step, payload))
}
