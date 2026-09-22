use std::collections::{HashSet, VecDeque};

use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
#[cfg(test)]
use network_identity::DeviceIdentity;
#[cfg(test)]
use x25519_dalek::PublicKey as X25519PublicKey;

#[cfg(test)]
use super::TEST_ROOT_KDF_INFO;
use super::{
    derive_material, CryptoError, CryptoSuite, KeyEpoch, ENVELOPE_HEADER_BYTES, ENVELOPE_MAGIC,
    ENVELOPE_VERSION, GCM_NONCE_BYTES, GCM_TAG_BYTES, INITIATOR_TO_RESPONDER_KDF_INFO,
    MAX_BYTES_PER_KEY, MAX_MESSAGES_PER_KEY, MAX_RETAINED_KEY_EPOCHS, NONCE_PREFIX_BYTES,
    NONCE_PREFIX_KDF_INFO, REPLAY_WINDOW_CAPACITY, RESPONDER_TO_INITIATOR_KDF_INFO,
};

/// Bounded nonce replay/reuse window.
///
/// Entries are retained in insertion order so an attacker cannot grow this
/// structure without bound.  A nonce is accepted at most once while it is in
/// the window; AEAD authentication is performed before receive-side inserts.
#[derive(Clone, Debug)]
pub(crate) struct ReplayWindow {
    capacity: usize,
    seen: HashSet<[u8; GCM_NONCE_BYTES]>,
    order: VecDeque<[u8; GCM_NONCE_BYTES]>,
}

impl Default for ReplayWindow {
    fn default() -> Self {
        Self::new(REPLAY_WINDOW_CAPACITY)
    }
}

impl ReplayWindow {
    pub(crate) fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            seen: HashSet::new(),
            order: VecDeque::new(),
        }
    }

    fn reserve(&mut self, nonce: [u8; GCM_NONCE_BYTES]) -> Result<(), CryptoError> {
        if !self.seen.insert(nonce) {
            return Err(CryptoError::NonceReuse);
        }
        self.order.push_back(nonce);
        while self.order.len() > self.capacity {
            if let Some(evicted) = self.order.pop_front() {
                self.seen.remove(&evicted);
            }
        }
        Ok(())
    }

    fn accept_received(&mut self, nonce: [u8; GCM_NONCE_BYTES]) -> Result<(), CryptoError> {
        if self.seen.contains(&nonce) {
            return Err(CryptoError::ReplayDetected);
        }
        self.reserve(nonce).map_err(|_| CryptoError::ReplayDetected)
    }
}

/// Session-owned AEAD context. It owns directional keys, key epoch state,
/// structured nonce counters, and bounded replay windows; it has no Route or
/// Connection handle dependency.
pub(crate) struct CryptoContext {
    suite: CryptoSuite,
    root_key: [u8; 32],
    tx_info: &'static [u8],
    rx_info: &'static [u8],
    send_epoch: KeyEpoch,
    receive_epoch: KeyEpoch,
    send_counter: u64,
    messages_in_epoch: u64,
    bytes_in_epoch: u64,
    send_window: ReplayWindow,
    receive_window: ReplayWindow,
    #[cfg(test)]
    allow_arbitrary_test_nonce: bool,
}

impl CryptoContext {
    /// Creates a context from the root produced by an authenticated Noise
    /// handshake. The root is already bound to the handshake transcript and
    /// logical Session binding; only directional traffic keys are expanded
    /// here.
    pub(crate) fn from_session_root(root_key: [u8; 32], initiator: bool) -> Self {
        let (tx_info, rx_info) = if initiator {
            (
                INITIATOR_TO_RESPONDER_KDF_INFO,
                RESPONDER_TO_INITIATOR_KDF_INFO,
            )
        } else {
            (
                RESPONDER_TO_INITIATOR_KDF_INFO,
                INITIATOR_TO_RESPONDER_KDF_INFO,
            )
        };
        Self {
            suite: CryptoSuite::HkdfSha256Aes256GcmV1,
            root_key,
            tx_info,
            rx_info,
            send_epoch: KeyEpoch::INITIAL,
            receive_epoch: KeyEpoch::INITIAL,
            send_counter: 0,
            messages_in_epoch: 0,
            bytes_in_epoch: 0,
            send_window: ReplayWindow::default(),
            receive_window: ReplayWindow::default(),
            #[cfg(test)]
            allow_arbitrary_test_nonce: false,
        }
    }

    #[allow(dead_code)]
    pub(crate) fn suite(&self) -> CryptoSuite {
        self.suite
    }

    #[allow(dead_code)]
    pub(crate) fn current_epoch(&self) -> KeyEpoch {
        self.send_epoch.max(self.receive_epoch)
    }

    /// Advance the local send epoch.  The authenticated epoch marker lets the
    /// peer derive the same bounded epoch key on its next receive.
    #[allow(dead_code)]
    pub(crate) fn rotate_key(&mut self) -> Result<KeyEpoch, CryptoError> {
        let next = self
            .send_epoch
            .0
            .checked_add(1)
            .ok_or(CryptoError::SequenceOverflow)?;
        self.send_epoch = KeyEpoch(next);
        self.send_counter = 0;
        self.messages_in_epoch = 0;
        self.bytes_in_epoch = 0;
        Ok(self.send_epoch)
    }

    pub(crate) fn encrypt(&mut self, aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
        let plaintext_bytes =
            u64::try_from(plaintext.len()).map_err(|_| CryptoError::SequenceOverflow)?;
        if self.messages_in_epoch >= MAX_MESSAGES_PER_KEY
            || self.bytes_in_epoch > MAX_BYTES_PER_KEY.saturating_sub(plaintext_bytes)
        {
            self.rotate_key()?;
        }
        let nonce = self.next_nonce()?;
        let envelope = self.encrypt_with_nonce(aad, plaintext, nonce)?;
        self.messages_in_epoch = self
            .messages_in_epoch
            .checked_add(1)
            .ok_or(CryptoError::SequenceOverflow)?;
        self.bytes_in_epoch = self
            .bytes_in_epoch
            .checked_add(plaintext_bytes)
            .ok_or(CryptoError::SequenceOverflow)?;
        Ok(envelope)
    }

    /// Deterministic nonce injection is test-only support for proving that a
    /// nonce cannot be reused. Production sends use the structured counter in
    /// [`Self::encrypt`].
    pub(crate) fn encrypt_with_nonce(
        &mut self,
        aad: &[u8],
        plaintext: &[u8],
        nonce: [u8; GCM_NONCE_BYTES],
    ) -> Result<Vec<u8>, CryptoError> {
        self.send_window.reserve(nonce)?;
        let key = self.epoch_key(self.tx_info, self.send_epoch)?;
        let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| CryptoError::InvalidKey)?;
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: plaintext,
                    aad,
                },
            )
            .map_err(|_| CryptoError::Encryption)?;
        let mut envelope = Vec::with_capacity(ENVELOPE_HEADER_BYTES + ciphertext.len());
        envelope.extend_from_slice(ENVELOPE_MAGIC);
        envelope.push(ENVELOPE_VERSION);
        envelope.push(self.suite.code());
        envelope.extend_from_slice(&self.send_epoch.0.to_be_bytes());
        envelope.extend_from_slice(&nonce);
        envelope.extend_from_slice(&ciphertext);
        Ok(envelope)
    }

    pub(crate) fn decrypt(&mut self, aad: &[u8], envelope: &[u8]) -> Result<Vec<u8>, CryptoError> {
        self.decrypt_internal(aad, envelope, false)
    }

    /// Decrypt a reliable Delivery envelope idempotently. A duplicate wire
    /// frame is still authenticated, then returned to Delivery so its
    /// DuplicateInFlight/Processed semantics can decide whether to emit or
    /// re-ACK. Best-effort payloads use strict `decrypt` instead.
    pub(crate) fn decrypt_for_delivery(
        &mut self,
        aad: &[u8],
        envelope: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        self.decrypt_internal(aad, envelope, true)
    }

    fn decrypt_internal(
        &mut self,
        aad: &[u8],
        envelope: &[u8],
        allow_authenticated_replay: bool,
    ) -> Result<Vec<u8>, CryptoError> {
        if envelope.len() < ENVELOPE_HEADER_BYTES + GCM_TAG_BYTES
            || &envelope[..ENVELOPE_MAGIC.len()] != ENVELOPE_MAGIC
            || envelope[ENVELOPE_MAGIC.len()] != ENVELOPE_VERSION
        {
            return Err(CryptoError::InvalidEnvelope);
        }
        let suite = CryptoSuite::from_code(envelope[5]).ok_or(CryptoError::InvalidEnvelope)?;
        if suite != self.suite {
            return Err(CryptoError::InvalidEnvelope);
        }
        let epoch = KeyEpoch(u64::from_be_bytes(
            envelope[6..14]
                .try_into()
                .map_err(|_| CryptoError::InvalidEnvelope)?,
        ));
        if epoch.0 > self.receive_epoch.0.saturating_add(1)
            || self.receive_epoch.0.saturating_sub(epoch.0) >= MAX_RETAINED_KEY_EPOCHS
        {
            return Err(CryptoError::KeyEpochUnavailable);
        }
        let nonce: [u8; GCM_NONCE_BYTES] = envelope[14..26]
            .try_into()
            .map_err(|_| CryptoError::InvalidEnvelope)?;
        let nonce_prefix_matches = nonce[..NONCE_PREFIX_BYTES]
            == self.nonce_prefix(self.rx_info, epoch)?[..NONCE_PREFIX_BYTES];
        #[cfg(test)]
        let nonce_prefix_matches = nonce_prefix_matches || self.allow_arbitrary_test_nonce;
        if !nonce_prefix_matches {
            return Err(CryptoError::NoncePrefixMismatch);
        }
        let key = self.epoch_key(self.rx_info, epoch)?;
        let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| CryptoError::InvalidKey)?;
        let clear = cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: &envelope[ENVELOPE_HEADER_BYTES..],
                    aad,
                },
            )
            .map_err(|_| CryptoError::Decryption)?;
        if self.receive_window.seen.contains(&nonce) {
            if !allow_authenticated_replay {
                return Err(CryptoError::ReplayDetected);
            }
        } else {
            self.receive_window.accept_received(nonce)?;
        }
        if epoch > self.receive_epoch {
            self.receive_epoch = epoch;
        }
        Ok(clear)
    }

    fn next_nonce(&mut self) -> Result<[u8; GCM_NONCE_BYTES], CryptoError> {
        let counter = self.send_counter;
        self.send_counter = self
            .send_counter
            .checked_add(1)
            .ok_or(CryptoError::SequenceOverflow)?;
        let mut nonce = [0u8; GCM_NONCE_BYTES];
        nonce[..NONCE_PREFIX_BYTES].copy_from_slice(
            &self.nonce_prefix(self.tx_info, self.send_epoch)?[..NONCE_PREFIX_BYTES],
        );
        nonce[NONCE_PREFIX_BYTES..].copy_from_slice(&counter.to_be_bytes());
        Ok(nonce)
    }

    fn nonce_prefix(&self, info: &'static [u8], epoch: KeyEpoch) -> Result<[u8; 32], CryptoError> {
        let key = self.epoch_key(info, epoch)?;
        derive_material(&key, &[], NONCE_PREFIX_KDF_INFO)
    }

    fn epoch_key(&self, info: &'static [u8], epoch: KeyEpoch) -> Result<[u8; 32], CryptoError> {
        let mut epoch_info = Vec::with_capacity(info.len() + 8);
        epoch_info.extend_from_slice(info);
        epoch_info.extend_from_slice(&epoch.0.to_be_bytes());
        derive_material(&self.root_key, &[], &epoch_info)
    }

    #[cfg(test)]
    pub(crate) fn from_identity(
        local_identity: &DeviceIdentity,
        peer_public_key: [u8; 32],
        session_id: &str,
    ) -> Result<Self, CryptoError> {
        let local_public = X25519PublicKey::from(&local_identity.e2e_key);
        let peer_public = X25519PublicKey::from(peer_public_key);
        let shared = local_identity.e2e_key.diffie_hellman(&peer_public);
        if shared.as_bytes().iter().all(|byte| *byte == 0) {
            return Err(CryptoError::InvalidKey);
        }
        let root_key =
            derive_material(shared.as_bytes(), session_id.as_bytes(), TEST_ROOT_KDF_INFO)?;
        let mut context =
            Self::from_session_root(root_key, local_public.as_bytes() <= peer_public.as_bytes());
        context.allow_arbitrary_test_nonce = true;
        Ok(context)
    }
}
