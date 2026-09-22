use network_identity::DeviceIdentity;
use rand::{rngs::OsRng, RngCore};
use snow::{params::NoiseParams, Builder, HandshakeState, TransportState};
use std::sync::Arc;
use zeroize::Zeroizing;

use super::exchange::{
    InitiatorIdentityOnlyExchange, InitiatorRootExchange, ResponderIdentityOnlyExchange,
    ResponderRootExchange,
};
use super::path_handshake;
use super::payload_hello::prologue;
use super::payload_root::{
    derive_application_root, derive_root_confirm, identity_only_binding_payload,
    parse_fixed_root_exchange_payload, parse_identity_only_binding_payload,
    parse_root_exchange_payload, root_exchange_payload, root_seed_payload, validate_binding,
    Cursor,
};
use super::{
    IDENTITY_ONLY_BINDING, IDENTITY_ONLY_CONFIRM, IDENTITY_PUBLIC_KEY_BYTES,
    MAX_HANDSHAKE_FRAME_BYTES, MAX_HANDSHAKE_PAYLOAD_BYTES, MAX_SESSION_BINDING_BYTES,
    NOISE_PATTERN, NOISE_PUBLIC_KEY_BYTES, NOISE_TRANSPORT_TAG_BYTES, ROOT_CONFIRM_BYTES,
    ROOT_EXCHANGE_ROOT_CONFIRM, ROOT_EXCHANGE_ROOT_SEED, ROOT_SEED_BYTES,
};
#[derive(Debug, thiserror::Error)]
pub(crate) enum CryptoHandshakeError {
    #[error("application crypto handshake is invalid")]
    Invalid,
    #[error("application crypto handshake identity is not trusted")]
    UntrustedIdentity,
    #[error("application crypto handshake Session binding is invalid")]
    InvalidBinding,
    #[error("application crypto handshake capability is unavailable")]
    Unsupported,
    #[error("application crypto handshake failed")]
    Failed,
    #[error("application crypto handshake transport failed: {0}")]
    Transport(#[from] std::io::Error),
    #[error(transparent)]
    Path(#[from] path_handshake::PathHandshakeError),
}

/// Direction-independent material produced by one successful Noise session.
/// `initiator` controls the later directional traffic-key derivation.
#[derive(Clone)]
pub(crate) struct SessionCryptoMaterial {
    /// This field remains the established application-key handoff for the
    /// existing runtime adapter. It is all-zero for identity-only admission;
    /// callers must check `path_security` before installing application crypto.
    pub(crate) root_key: [u8; 32],
    pub(crate) local_session_binding: String,
    pub(crate) remote_session_binding: String,
    pub(crate) initiator: bool,
    pub(crate) e2ee_policy: path_handshake::E2eePolicy,
    #[allow(dead_code)] // read through has_application_e2ee at the runtime boundary
    pub(crate) path_security: path_handshake::PathSecurity,
}

impl SessionCryptoMaterial {
    pub(crate) fn has_application_e2ee(&self) -> bool {
        self.path_security.has_application_e2ee()
    }

    pub(super) fn identity_only(
        local_session_binding: String,
        remote_session_binding: String,
        initiator: bool,
    ) -> Self {
        Self {
            root_key: [0u8; 32],
            local_session_binding,
            remote_session_binding,
            initiator,
            e2ee_policy: path_handshake::E2eePolicy::Disabled,
            path_security: path_handshake::PathSecurity::IdentityOnly,
        }
    }
}

pub(crate) struct NoiseHandshake {
    pub(super) state: HandshakeState,
    pub(super) identity: Arc<DeviceIdentity>,
    pub(super) local_static_public: [u8; NOISE_PUBLIC_KEY_BYTES],
    pub(super) identity_public: [u8; IDENTITY_PUBLIC_KEY_BYTES],
    initiator: bool,
}

pub(super) struct EstablishedNoise {
    transport: TransportState,
    handshake_hash: [u8; 32],
    session_binding: String,
    initiator: bool,
    path_security: path_handshake::PathSecurity,
}

impl NoiseHandshake {
    pub(super) fn new(
        identity: Arc<DeviceIdentity>,
        initiator: bool,
    ) -> Result<Self, CryptoHandshakeError> {
        let params: NoiseParams = NOISE_PATTERN
            .parse()
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let builder = Builder::new(params.clone());
        let keypair = builder
            .generate_keypair()
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let local_static_public: [u8; NOISE_PUBLIC_KEY_BYTES] = keypair
            .public
            .as_slice()
            .try_into()
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let identity_public = identity.public_identity_key().to_bytes();
        let state = if initiator {
            Builder::new(params)
                .local_private_key(&keypair.private)
                .prologue(prologue())
                .build_initiator()
        } else {
            Builder::new(params)
                .local_private_key(&keypair.private)
                .prologue(prologue())
                .build_responder()
        }
        .map_err(|_| CryptoHandshakeError::Failed)?;
        Ok(Self {
            state,
            identity,
            local_static_public,
            identity_public,
            initiator,
        })
    }

    pub(super) fn write(&mut self, payload: &[u8]) -> Result<Vec<u8>, CryptoHandshakeError> {
        let mut message = vec![0u8; MAX_HANDSHAKE_FRAME_BYTES];
        let length = self
            .state
            .write_message(payload, &mut message)
            .map_err(|_| CryptoHandshakeError::Failed)?;
        message.truncate(length);
        Ok(message)
    }

    pub(super) fn read(&mut self, message: &[u8]) -> Result<Vec<u8>, CryptoHandshakeError> {
        if message.is_empty() || message.len() > MAX_HANDSHAKE_FRAME_BYTES {
            return Err(CryptoHandshakeError::Invalid);
        }
        let mut payload = vec![0u8; MAX_HANDSHAKE_PAYLOAD_BYTES];
        let length = self
            .state
            .read_message(message, &mut payload)
            .map_err(|_| CryptoHandshakeError::Failed)?;
        payload.truncate(length);
        Ok(payload)
    }

    #[cfg(test)]
    pub(super) fn into_established(
        self,
        session_binding: String,
    ) -> Result<EstablishedNoise, CryptoHandshakeError> {
        self.into_established_with_policy(session_binding, path_handshake::E2eePolicy::Required)
    }

    #[cfg(test)]
    pub(super) fn into_established_with_policy(
        self,
        session_binding: String,
        e2ee_policy: path_handshake::E2eePolicy,
    ) -> Result<EstablishedNoise, CryptoHandshakeError> {
        let path_security = path_handshake::negotiate_security(
            path_handshake::PathKind::Direct,
            e2ee_policy,
            e2ee_policy,
        )?;
        self.into_established_with_security(session_binding, path_security)
    }

    pub(super) fn into_established_with_security(
        self,
        session_binding: String,
        path_security: path_handshake::PathSecurity,
    ) -> Result<EstablishedNoise, CryptoHandshakeError> {
        if !self.state.is_handshake_finished() {
            return Err(CryptoHandshakeError::Failed);
        }
        validate_binding(&session_binding)?;
        let handshake_hash = self
            .state
            .get_handshake_hash()
            .try_into()
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let transport = self
            .state
            .into_transport_mode()
            .map_err(|_| CryptoHandshakeError::Failed)?;
        Ok(EstablishedNoise {
            transport,
            handshake_hash,
            session_binding,
            initiator: self.initiator,
            path_security,
        })
    }
}

impl EstablishedNoise {
    pub(super) fn begin_responder(
        mut self,
        local_session_binding: &str,
    ) -> Result<(ResponderRootExchange, Vec<u8>), CryptoHandshakeError> {
        if self.initiator || !self.path_security.has_application_e2ee() {
            return Err(CryptoHandshakeError::Failed);
        }
        validate_binding(local_session_binding)?;
        let mut root_seed = Zeroizing::new([0u8; ROOT_SEED_BYTES]);
        OsRng.fill_bytes(root_seed.as_mut());
        let root_key = Zeroizing::new(derive_application_root(
            &root_seed,
            &self.handshake_hash,
            &self.session_binding,
        )?);
        let expected_confirm = Zeroizing::new(derive_root_confirm(
            &root_key,
            &self.handshake_hash,
            &self.session_binding,
        )?);
        let seed_payload = root_seed_payload(&root_seed, local_session_binding)?;
        let encrypted_seed = self.encrypt_exchange(ROOT_EXCHANGE_ROOT_SEED, &seed_payload)?;
        Ok((
            ResponderRootExchange {
                noise: self,
                root_key,
                expected_confirm,
                local_session_binding: local_session_binding.to_string(),
            },
            encrypted_seed,
        ))
    }

    pub(super) fn begin_identity_only(
        mut self,
        local_session_binding: &str,
    ) -> Result<(ResponderIdentityOnlyExchange, Vec<u8>), CryptoHandshakeError> {
        if self.initiator || self.path_security != path_handshake::PathSecurity::IdentityOnly {
            return Err(CryptoHandshakeError::Failed);
        }
        validate_binding(local_session_binding)?;
        let payload = identity_only_binding_payload(local_session_binding)?;
        let encrypted_binding = self.encrypt_exchange(IDENTITY_ONLY_BINDING, &payload)?;
        Ok((
            ResponderIdentityOnlyExchange {
                noise: self,
                local_session_binding: local_session_binding.to_string(),
            },
            encrypted_binding,
        ))
    }

    pub(super) fn accept_root_seed(
        mut self,
        encrypted_seed: &[u8],
    ) -> Result<InitiatorRootExchange, CryptoHandshakeError> {
        if !self.initiator || !self.path_security.has_application_e2ee() {
            return Err(CryptoHandshakeError::Failed);
        }
        let (root_seed, remote_session_binding) =
            self.decrypt_root_seed_exchange(encrypted_seed)?;
        let root_key = Zeroizing::new(derive_application_root(
            &root_seed,
            &self.handshake_hash,
            &self.session_binding,
        )?);
        let confirm = Zeroizing::new(derive_root_confirm(
            &root_key,
            &self.handshake_hash,
            &self.session_binding,
        )?);
        Ok(InitiatorRootExchange {
            noise: self,
            root_key,
            expected_confirm: confirm,
            remote_session_binding,
            local_session_binding: String::new(),
        })
    }

    pub(super) fn accept_identity_only_binding(
        mut self,
        encrypted_binding: &[u8],
    ) -> Result<InitiatorIdentityOnlyExchange, CryptoHandshakeError> {
        if !self.initiator || self.path_security != path_handshake::PathSecurity::IdentityOnly {
            return Err(CryptoHandshakeError::Failed);
        }
        let remote_session_binding = self.decrypt_identity_only_binding(encrypted_binding)?;
        Ok(InitiatorIdentityOnlyExchange {
            noise: self,
            remote_session_binding,
            local_session_binding: String::new(),
        })
    }

    pub(super) fn encrypt_exchange(
        &mut self,
        message_type: u8,
        payload: &[u8],
    ) -> Result<Vec<u8>, CryptoHandshakeError> {
        let plaintext = Zeroizing::new(root_exchange_payload(
            message_type,
            &self.session_binding,
            payload,
        )?);
        let mut ciphertext = vec![0u8; plaintext.len() + NOISE_TRANSPORT_TAG_BYTES];
        let length = self
            .transport
            .write_message(&plaintext, &mut ciphertext)
            .map_err(|_| CryptoHandshakeError::Failed)?;
        ciphertext.truncate(length);
        Ok(ciphertext)
    }

    pub(super) fn decrypt_fixed_exchange<const N: usize>(
        &mut self,
        expected_type: u8,
        ciphertext: &[u8],
    ) -> Result<Zeroizing<[u8; N]>, CryptoHandshakeError> {
        if ciphertext.is_empty() || ciphertext.len() > MAX_HANDSHAKE_FRAME_BYTES {
            return Err(CryptoHandshakeError::Invalid);
        }
        let mut plaintext = Zeroizing::new([0u8; MAX_HANDSHAKE_PAYLOAD_BYTES]);
        let length = self
            .transport
            .read_message(ciphertext, &mut plaintext[..])
            .map_err(|_| CryptoHandshakeError::Failed)?;
        parse_fixed_root_exchange_payload::<N>(
            &plaintext[..length],
            expected_type,
            &self.session_binding,
        )
    }

    pub(super) fn decrypt_root_seed_exchange(
        &mut self,
        ciphertext: &[u8],
    ) -> Result<(Zeroizing<[u8; ROOT_SEED_BYTES]>, String), CryptoHandshakeError> {
        if ciphertext.is_empty() || ciphertext.len() > MAX_HANDSHAKE_FRAME_BYTES {
            return Err(CryptoHandshakeError::Invalid);
        }
        let mut plaintext = Zeroizing::new([0u8; MAX_HANDSHAKE_PAYLOAD_BYTES]);
        let length = self
            .transport
            .read_message(ciphertext, &mut plaintext[..])
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let payload = parse_root_exchange_payload(
            &plaintext[..length],
            ROOT_EXCHANGE_ROOT_SEED,
            &self.session_binding,
        )?;
        if payload.len() < ROOT_SEED_BYTES + 2 {
            return Err(CryptoHandshakeError::Invalid);
        }
        let root_seed = Zeroizing::new(
            payload[..ROOT_SEED_BYTES]
                .try_into()
                .map_err(|_| CryptoHandshakeError::Invalid)?,
        );
        let mut cursor = Cursor::new(&payload[ROOT_SEED_BYTES..]);
        let remote_session_binding = cursor.take_string(MAX_SESSION_BINDING_BYTES)?;
        if !cursor.done() {
            return Err(CryptoHandshakeError::Invalid);
        }
        validate_binding(&remote_session_binding)?;
        Ok((root_seed, remote_session_binding))
    }

    pub(super) fn decrypt_root_confirm_exchange(
        &mut self,
        ciphertext: &[u8],
    ) -> Result<(Zeroizing<[u8; ROOT_CONFIRM_BYTES]>, String), CryptoHandshakeError> {
        if ciphertext.is_empty() || ciphertext.len() > MAX_HANDSHAKE_FRAME_BYTES {
            return Err(CryptoHandshakeError::Invalid);
        }
        let mut plaintext = Zeroizing::new([0u8; MAX_HANDSHAKE_PAYLOAD_BYTES]);
        let length = self
            .transport
            .read_message(ciphertext, &mut plaintext[..])
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let payload = parse_root_exchange_payload(
            &plaintext[..length],
            ROOT_EXCHANGE_ROOT_CONFIRM,
            &self.session_binding,
        )?;
        if payload.len() < ROOT_CONFIRM_BYTES + 2 {
            return Err(CryptoHandshakeError::Invalid);
        }
        let confirm = Zeroizing::new(
            payload[..ROOT_CONFIRM_BYTES]
                .try_into()
                .map_err(|_| CryptoHandshakeError::Invalid)?,
        );
        let mut cursor = Cursor::new(&payload[ROOT_CONFIRM_BYTES..]);
        let remote_session_binding = cursor.take_string(MAX_SESSION_BINDING_BYTES)?;
        if !cursor.done() {
            return Err(CryptoHandshakeError::Invalid);
        }
        validate_binding(&remote_session_binding)?;
        Ok((confirm, remote_session_binding))
    }

    fn decrypt_identity_only_binding(
        &mut self,
        ciphertext: &[u8],
    ) -> Result<String, CryptoHandshakeError> {
        if ciphertext.is_empty() || ciphertext.len() > MAX_HANDSHAKE_FRAME_BYTES {
            return Err(CryptoHandshakeError::Invalid);
        }
        let mut plaintext = Zeroizing::new([0u8; MAX_HANDSHAKE_PAYLOAD_BYTES]);
        let length = self
            .transport
            .read_message(ciphertext, &mut plaintext[..])
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let payload = parse_root_exchange_payload(
            &plaintext[..length],
            IDENTITY_ONLY_BINDING,
            &self.session_binding,
        )?;
        parse_identity_only_binding_payload(payload)
    }

    pub(super) fn decrypt_identity_only_confirm(
        &mut self,
        ciphertext: &[u8],
    ) -> Result<String, CryptoHandshakeError> {
        if ciphertext.is_empty() || ciphertext.len() > MAX_HANDSHAKE_FRAME_BYTES {
            return Err(CryptoHandshakeError::Invalid);
        }
        let mut plaintext = Zeroizing::new([0u8; MAX_HANDSHAKE_PAYLOAD_BYTES]);
        let length = self
            .transport
            .read_message(ciphertext, &mut plaintext[..])
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let payload = parse_root_exchange_payload(
            &plaintext[..length],
            IDENTITY_ONLY_CONFIRM,
            &self.session_binding,
        )?;
        parse_identity_only_binding_payload(payload)
    }

    pub(super) fn into_material(
        self,
        root_key: [u8; 32],
        local_session_binding: String,
        remote_session_binding: String,
    ) -> SessionCryptoMaterial {
        SessionCryptoMaterial {
            root_key,
            local_session_binding,
            remote_session_binding,
            initiator: self.initiator,
            e2ee_policy: self.path_security.policy(),
            path_security: self.path_security,
        }
    }
}
