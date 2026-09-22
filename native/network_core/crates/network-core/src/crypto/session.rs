use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
#[cfg(test)]
use network_identity::DeviceIdentity;
use rand::RngCore;
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret};

use super::{
    derive_material, CryptoContext, CryptoError, FILE_CHUNK_AAD_PREFIX, GCM_NONCE_BYTES,
    GCM_TAG_BYTES, OFFER_AAD_PREFIX, OFFER_KDF_INFO, X25519_PUBLIC_KEY_BYTES,
};

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct CryptoContextKey {
    peer_id: String,
    session_id: String,
}

/// App Scope owner for Session application contexts.  Contexts are keyed by
/// logical Session rather than transport route and are removed only when a
/// Session is explicitly closed.
pub(crate) struct SessionCryptoManager {
    contexts: Mutex<HashMap<CryptoContextKey, Arc<Mutex<CryptoContext>>>>,
}

impl Default for SessionCryptoManager {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionCryptoManager {
    pub(crate) fn new() -> Self {
        Self {
            contexts: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn install_material_aliases(
        &self,
        peer_id: &str,
        session_ids: &[&str],
        root_key: [u8; 32],
        initiator: bool,
    ) -> Result<Arc<Mutex<CryptoContext>>, CryptoError> {
        let mut contexts = self
            .contexts
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?;
        // §18 1:1：每次连接都安装**全新** root。A peer owns one logical Session
        // at a time, so every alias for that peer is retired before the new root
        // is installed; a new alias must never discover an older context by
        // collision. There is no ContinueExisting reuse path.
        contexts.retain(|key, _| key.peer_id != peer_id);
        let context = Arc::new(Mutex::new(CryptoContext::from_session_root(
            root_key, initiator,
        )));
        for session_id in session_ids {
            contexts.insert(
                CryptoContextKey {
                    peer_id: peer_id.to_string(),
                    session_id: (*session_id).to_string(),
                },
                Arc::clone(&context),
            );
        }
        Ok(context)
    }

    #[cfg(test)]
    pub(super) fn get_or_create(
        &self,
        peer_id: &str,
        session_id: &str,
        identity: &DeviceIdentity,
        peer_public_key: [u8; 32],
    ) -> Result<Arc<Mutex<CryptoContext>>, CryptoError> {
        let key = CryptoContextKey {
            peer_id: peer_id.to_string(),
            session_id: session_id.to_string(),
        };
        let mut contexts = self
            .contexts
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?;
        if let Some(context) = contexts.get(&key) {
            return Ok(Arc::clone(context));
        }
        let context = Arc::new(Mutex::new(CryptoContext::from_identity(
            identity,
            peer_public_key,
            session_id,
        )?));
        contexts.insert(key, Arc::clone(&context));
        Ok(context)
    }

    pub(crate) fn get(
        &self,
        peer_id: &str,
        session_id: &str,
    ) -> Result<Arc<Mutex<CryptoContext>>, CryptoError> {
        self.contexts
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?
            .get(&CryptoContextKey {
                peer_id: peer_id.to_string(),
                session_id: session_id.to_string(),
            })
            .cloned()
            .ok_or(CryptoError::E2eeRequired)
    }

    pub(crate) fn remove_session(&self, peer_id: &str, session_id: &str) {
        if let Ok(mut contexts) = self.contexts.lock() {
            let key = CryptoContextKey {
                peer_id: peer_id.to_string(),
                session_id: session_id.to_string(),
            };
            let Some(context) = contexts.remove(&key) else {
                return;
            };
            contexts.retain(|_, current| !Arc::ptr_eq(current, &context));
        }
    }

    #[cfg(test)]
    pub(super) fn contains(&self, peer_id: &str, session_id: &str) -> bool {
        self.contexts
            .lock()
            .expect("context lock")
            .contains_key(&CryptoContextKey {
                peer_id: peer_id.to_string(),
                session_id: session_id.to_string(),
            })
    }
}

/// Encrypt an offer with an ephemeral X25519 key and an HKDF-derived AEAD key.
/// This protects Relay control metadata; the Relay never sees the clear offer.
pub(crate) fn encrypt_application_offer(
    plaintext: &[u8],
    peer_public_key: [u8; 32],
    session_id: &[u8; 16],
) -> Result<Vec<u8>, CryptoError> {
    let ephemeral = StaticSecret::random_from_rng(rand::rngs::OsRng);
    let ephemeral_public = X25519PublicKey::from(&ephemeral);
    let shared = ephemeral.diffie_hellman(&X25519PublicKey::from(peer_public_key));
    let key = derive_material(shared.as_bytes(), session_id, OFFER_KDF_INFO)?;
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| CryptoError::InvalidKey)?;
    let mut nonce = [0u8; GCM_NONCE_BYTES];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    let aad = offer_aad(session_id);
    let encrypted = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| CryptoError::Encryption)?;
    let mut envelope =
        Vec::with_capacity(X25519_PUBLIC_KEY_BYTES + GCM_NONCE_BYTES + encrypted.len());
    envelope.extend_from_slice(ephemeral_public.as_bytes());
    envelope.extend_from_slice(&nonce);
    envelope.extend_from_slice(&encrypted);
    Ok(envelope)
}

/// Decrypt an application offer using the recipient's long-lived E2E secret.
pub(crate) fn decrypt_application_offer(
    envelope: &[u8],
    local_secret: &StaticSecret,
    session_id: &[u8; 16],
) -> Result<Vec<u8>, CryptoError> {
    let minimum = X25519_PUBLIC_KEY_BYTES + GCM_NONCE_BYTES + GCM_TAG_BYTES;
    if envelope.len() < minimum {
        return Err(CryptoError::InvalidEnvelope);
    }
    let ephemeral_key: [u8; 32] = envelope[..X25519_PUBLIC_KEY_BYTES]
        .try_into()
        .map_err(|_| CryptoError::InvalidEnvelope)?;
    let nonce = &envelope[X25519_PUBLIC_KEY_BYTES..minimum - GCM_TAG_BYTES];
    let shared = local_secret.diffie_hellman(&X25519PublicKey::from(ephemeral_key));
    let key = derive_material(shared.as_bytes(), session_id, OFFER_KDF_INFO)?;
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| CryptoError::InvalidKey)?;
    let aad = offer_aad(session_id);
    cipher
        .decrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: &envelope[minimum - GCM_TAG_BYTES..],
                aad: &aad,
            },
        )
        .map_err(|_| CryptoError::Decryption)
}

/// Construct stable associated data for a Relay file chunk.
pub(crate) fn file_chunk_aad(
    session_id: &str,
    transfer_id: &str,
    manifest_hash: &str,
    sequence: u64,
) -> Vec<u8> {
    let mut aad = Vec::with_capacity(
        FILE_CHUNK_AAD_PREFIX.len()
            + session_id.len()
            + transfer_id.len()
            + manifest_hash.len()
            + std::mem::size_of::<u64>()
            + 12,
    );
    aad.extend_from_slice(FILE_CHUNK_AAD_PREFIX);
    append_len_prefixed(&mut aad, session_id.as_bytes());
    append_len_prefixed(&mut aad, transfer_id.as_bytes());
    append_len_prefixed(&mut aad, manifest_hash.as_bytes());
    aad.extend_from_slice(&sequence.to_be_bytes());
    aad
}

/// Advance an ordered transfer sequence without wrapping.
pub(crate) fn next_sequence(sequence: u64) -> Result<u64, CryptoError> {
    sequence.checked_add(1).ok_or(CryptoError::SequenceOverflow)
}

/// Build AAD from a DataMessage's clear metadata. The payload is intentionally
/// excluded, so retries can replace ciphertext without changing the binding.
pub(crate) fn data_message_aad(
    session_id: &str,
    channel_id: &str,
    message_id: &[u8],
    sequence: u64,
    recovery_epoch: u64,
    policy: i32,
) -> Vec<u8> {
    let mut aad = Vec::with_capacity(64 + session_id.len() + channel_id.len() + message_id.len());
    append_len_prefixed(&mut aad, session_id.as_bytes());
    append_len_prefixed(&mut aad, channel_id.as_bytes());
    append_len_prefixed(&mut aad, message_id);
    aad.extend_from_slice(&sequence.to_be_bytes());
    aad.extend_from_slice(&recovery_epoch.to_be_bytes());
    aad.extend_from_slice(&policy.to_be_bytes());
    aad
}

fn append_len_prefixed(output: &mut Vec<u8>, bytes: &[u8]) {
    output.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    output.extend_from_slice(bytes);
}

fn offer_aad(session_id: &[u8; 16]) -> Vec<u8> {
    let mut aad = Vec::with_capacity(OFFER_AAD_PREFIX.len() + session_id.len());
    aad.extend_from_slice(OFFER_AAD_PREFIX);
    aad.extend_from_slice(session_id);
    aad
}
