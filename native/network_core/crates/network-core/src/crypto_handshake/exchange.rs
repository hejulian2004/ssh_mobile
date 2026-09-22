use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use super::noise::{CryptoHandshakeError, EstablishedNoise, SessionCryptoMaterial};
use super::payload_root::{identity_only_binding_payload, root_confirm_payload, validate_binding};
use super::{
    IDENTITY_ONLY_ACCEPT, IDENTITY_ONLY_CONFIRM, ROOT_CONFIRM_BYTES, ROOT_EXCHANGE_ACCEPT,
    ROOT_EXCHANGE_ROOT_CONFIRM,
};

pub(super) struct InitiatorRootExchange {
    pub(super) noise: EstablishedNoise,
    pub(super) root_key: Zeroizing<[u8; 32]>,
    pub(super) expected_confirm: Zeroizing<[u8; ROOT_CONFIRM_BYTES]>,
    pub(super) remote_session_binding: String,
    pub(super) local_session_binding: String,
}

pub(super) struct ResponderRootExchange {
    pub(super) noise: EstablishedNoise,
    pub(super) root_key: Zeroizing<[u8; 32]>,
    pub(super) expected_confirm: Zeroizing<[u8; ROOT_CONFIRM_BYTES]>,
    pub(super) local_session_binding: String,
}

pub(super) struct InitiatorIdentityOnlyExchange {
    pub(super) noise: EstablishedNoise,
    pub(super) remote_session_binding: String,
    pub(super) local_session_binding: String,
}

pub(super) struct ResponderIdentityOnlyExchange {
    pub(super) noise: EstablishedNoise,
    pub(super) local_session_binding: String,
}
impl InitiatorIdentityOnlyExchange {
    pub(super) fn confirm(
        mut self,
        local_session_binding: String,
    ) -> Result<(Self, Vec<u8>), CryptoHandshakeError> {
        validate_binding(&local_session_binding)?;
        let payload = identity_only_binding_payload(&local_session_binding)?;
        let encrypted_confirm = self
            .noise
            .encrypt_exchange(IDENTITY_ONLY_CONFIRM, &payload)?;
        self.local_session_binding = local_session_binding;
        Ok((self, encrypted_confirm))
    }

    pub(super) fn accept(
        self,
        encrypted_accept: &[u8],
    ) -> Result<SessionCryptoMaterial, CryptoHandshakeError> {
        let mut noise = self.noise;
        noise.decrypt_fixed_exchange::<0>(IDENTITY_ONLY_ACCEPT, encrypted_accept)?;
        Ok(SessionCryptoMaterial::identity_only(
            self.local_session_binding,
            self.remote_session_binding,
            true,
        ))
    }
}

impl ResponderIdentityOnlyExchange {
    pub(super) fn accept_confirm(
        self,
        encrypted_confirm: &[u8],
    ) -> Result<(Vec<u8>, SessionCryptoMaterial), CryptoHandshakeError> {
        let mut noise = self.noise;
        let remote_session_binding = noise.decrypt_identity_only_confirm(encrypted_confirm)?;
        let encrypted_accept = noise.encrypt_exchange(IDENTITY_ONLY_ACCEPT, &[])?;
        Ok((
            encrypted_accept,
            SessionCryptoMaterial::identity_only(
                self.local_session_binding,
                remote_session_binding,
                false,
            ),
        ))
    }
}

impl InitiatorRootExchange {
    pub(super) fn confirm(
        mut self,
        local_session_binding: String,
    ) -> Result<(Self, Vec<u8>), CryptoHandshakeError> {
        validate_binding(&local_session_binding)?;
        let payload = root_confirm_payload(&self.expected_confirm, &local_session_binding)?;
        let encrypted_confirm = self
            .noise
            .encrypt_exchange(ROOT_EXCHANGE_ROOT_CONFIRM, &payload)?;
        self.local_session_binding = local_session_binding;
        Ok((self, encrypted_confirm))
    }

    pub(super) fn accept(
        self,
        encrypted_accept: &[u8],
    ) -> Result<SessionCryptoMaterial, CryptoHandshakeError> {
        let mut noise = self.noise;
        noise.decrypt_fixed_exchange::<0>(ROOT_EXCHANGE_ACCEPT, encrypted_accept)?;
        Ok(noise.into_material(
            *self.root_key,
            self.local_session_binding,
            self.remote_session_binding,
        ))
    }
}

impl ResponderRootExchange {
    pub(super) fn accept_confirm(
        self,
        encrypted_confirm: &[u8],
    ) -> Result<(Vec<u8>, SessionCryptoMaterial), CryptoHandshakeError> {
        let mut noise = self.noise;
        let (confirm, remote_session_binding) =
            noise.decrypt_root_confirm_exchange(encrypted_confirm)?;
        if !bool::from(confirm[..].ct_eq(&self.expected_confirm[..])) {
            return Err(CryptoHandshakeError::Failed);
        }
        let encrypted_accept = noise.encrypt_exchange(ROOT_EXCHANGE_ACCEPT, &[])?;
        let local_session_binding = self.local_session_binding;
        Ok((
            encrypted_accept,
            noise.into_material(
                *self.root_key,
                local_session_binding,
                remote_session_binding,
            ),
        ))
    }
}
