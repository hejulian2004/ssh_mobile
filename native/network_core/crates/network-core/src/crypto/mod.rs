//! Session-owned application cryptography.
//!
//! The transport only carries opaque bytes.  A `CryptoContext` is created for
//! one logical `(peer, SessionId)` pair and does **not** survive transport loss
//! (transport-network v2 §18): every new connection derives a fresh Noise root
//! and installs a fresh context.  The traffic root is installed only after the
//! authenticated Noise XX handshake in `crypto_handshake.rs`; long-lived
//! DeviceIdentity keys do not directly become application traffic keys.

mod context;
mod session;

use hkdf::Hkdf;
use sha2::Sha256;
use std::fmt;

#[cfg(test)]
use network_identity::DeviceIdentity;
#[cfg(test)]
use std::collections::HashSet;
#[cfg(test)]
use std::sync::Arc;
#[cfg(test)]
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret};

pub(crate) use context::CryptoContext;
#[allow(unused_imports)]
pub(crate) use context::ReplayWindow;
pub(crate) use session::{
    data_message_aad, decrypt_application_offer, encrypt_application_offer, file_chunk_aad,
    next_sequence, SessionCryptoManager,
};

/// The application crypto suite carried by encrypted Relay offer metadata.
/// Network Protocol V2 always uses the ConnectionSession-owned E2EE context;
/// crypto mode is not negotiated per message.
pub(crate) const APPLICATION_CRYPTO_SUITE: &str = "hkdf-sha256-aes256gcm-v1";

#[cfg(test)]
const TEST_ROOT_KDF_INFO: &[u8] = b"ssh-mobile/session/application/test-root/v1";
const INITIATOR_TO_RESPONDER_KDF_INFO: &[u8] =
    b"ssh-mobile/session/application/initiator-to-responder/v2";
const RESPONDER_TO_INITIATOR_KDF_INFO: &[u8] =
    b"ssh-mobile/session/application/responder-to-initiator/v2";
const NONCE_PREFIX_KDF_INFO: &[u8] = b"ssh-mobile/session/application/nonce-prefix/v2";
const OFFER_KDF_INFO: &[u8] = b"ssh-mobile/session/application/offer/v1";
const OFFER_AAD_PREFIX: &[u8] = b"ssh-mobile/session/application/offer/v1";
const FILE_CHUNK_AAD_PREFIX: &[u8] = b"ssh-mobile/session/application/file-chunk/v1";
const ENVELOPE_MAGIC: &[u8; 4] = b"SME1";
const ENVELOPE_VERSION: u8 = 1;
const X25519_PUBLIC_KEY_BYTES: usize = 32;
const GCM_NONCE_BYTES: usize = 12;
const GCM_TAG_BYTES: usize = 16;
const ENVELOPE_HEADER_BYTES: usize = 4 + 1 + 1 + std::mem::size_of::<u64>() + GCM_NONCE_BYTES;
const REPLAY_WINDOW_CAPACITY: usize = 4096;
const MAX_RETAINED_KEY_EPOCHS: u64 = 4;
pub(crate) const MAX_MESSAGES_PER_KEY: u64 = 1_048_576;
pub(crate) const MAX_BYTES_PER_KEY: u64 = 1 << 30;
const NONCE_PREFIX_BYTES: usize = 4;

/// Whether bytes carry the frozen application E2EE envelope marker.
///
/// Disabled Direct paths intentionally carry the authenticated application
/// payload unchanged. Receivers use this marker only to reject an encrypted
/// payload arriving under a Disabled policy; transport identity/authentication
/// remains mandatory in both modes.
pub(crate) fn is_application_envelope(bytes: &[u8]) -> bool {
    bytes.len() >= ENVELOPE_MAGIC.len() && bytes[..ENVELOPE_MAGIC.len()] == *ENVELOPE_MAGIC
}

/// Numeric suite marker in the application envelope.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CryptoSuite {
    HkdfSha256Aes256GcmV1,
}

impl CryptoSuite {
    fn code(self) -> u8 {
        match self {
            Self::HkdfSha256Aes256GcmV1 => 1,
        }
    }

    fn from_code(value: u8) -> Option<Self> {
        match value {
            1 => Some(Self::HkdfSha256Aes256GcmV1),
            _ => None,
        }
    }
}

/// Monotonic application key epoch.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(crate) struct KeyEpoch(u64);

impl KeyEpoch {
    pub(crate) const INITIAL: Self = Self(0);
}

/// Errors exposed by the native crypto boundary without including key material.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CryptoError {
    InvalidEnvelope,
    InvalidKey,
    KeyDerivation,
    Encryption,
    Decryption,
    SequenceOverflow,
    ReplayDetected,
    NonceReuse,
    KeyEpochUnavailable,
    NoncePrefixMismatch,
    E2eeRequired,
    StateUnavailable,
}

impl fmt::Display for CryptoError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidEnvelope => "invalid application crypto envelope",
            Self::InvalidKey => "invalid application crypto key",
            Self::KeyDerivation => "application key derivation failed",
            Self::Encryption => "application encryption failed",
            Self::Decryption => "application decryption failed",
            Self::SequenceOverflow => "application sequence overflow",
            Self::ReplayDetected => "application ciphertext replay detected",
            Self::NonceReuse => "application nonce reuse rejected",
            Self::KeyEpochUnavailable => "application key epoch is unavailable",
            Self::NoncePrefixMismatch => "application nonce prefix is invalid",
            Self::E2eeRequired => "application E2EE context is required",
            Self::StateUnavailable => "application crypto state is unavailable",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for CryptoError {}

fn derive_material(
    input_key_material: &[u8],
    salt: &[u8],
    info: &[u8],
) -> Result<[u8; 32], CryptoError> {
    let hkdf = Hkdf::<Sha256>::new(Some(salt), input_key_material);
    let mut key = [0u8; 32];
    hkdf.expand(info, &mut key)
        .map_err(|_| CryptoError::KeyDerivation)?;
    Ok(key)
}

#[cfg(test)]
#[path = "../tests/crypto.rs"]
mod tests;
