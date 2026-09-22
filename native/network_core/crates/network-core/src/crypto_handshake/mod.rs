//! Forward-secret, identity-bound application crypto handshake.
//!
//! The transport authentication performed by QUIC/TCP/WebSocket answers
//! "which device opened this socket?".  This module establishes the
//! Session-owned application root separately with Noise XX.  Each handshake
//! generates a fresh X25519 keypair; the long-lived Ed25519 DeviceIdentity is
//! used only to sign the Noise static key and the logical Session binding.
//! The resulting root is never logged or exposed outside the native crypto
//! owner.

// PathHandshakeV2 is the authenticated metadata/admission evolution carried
// by this module's existing Noise/DATA_ENV_CRYPTO transport. It deliberately
// does not introduce another key exchange or security envelope.
#[allow(dead_code)]
pub(crate) mod path_handshake;

mod exchange;
mod generic;
mod noise;
mod payload_hello;
mod payload_root;
mod quic;
mod relay;
const NOISE_PATTERN: &str = "Noise_XX_25519_AESGCM_SHA256";
const HANDSHAKE_DOMAIN: &[u8] = b"ssh-mobile/session-e2ee/noise-xx/v1";
const HANDSHAKE_HELLO_MAGIC: &[u8; 4] = b"SMEH";
const HANDSHAKE_PROOF_MAGIC: &[u8; 4] = b"SMEP";
const HANDSHAKE_CAPABILITY: &[u8] = b"e2ee/noise-xx-aes256gcm-v3";
const ROOT_EXCHANGE_MAGIC: &[u8; 4] = b"SMKR";
const ROOT_EXCHANGE_VERSION: u8 = 3;
const ROOT_EXCHANGE_ROOT_SEED: u8 = 1;
const ROOT_EXCHANGE_ROOT_CONFIRM: u8 = 2;
const ROOT_EXCHANGE_ACCEPT: u8 = 3;
// Direct identity-only admission uses Noise transport ciphertext for the
// responder/initiator binding exchange. These are not Relay frames and never
// carry an application RootSeed.
const IDENTITY_ONLY_BINDING: u8 = 4;
const IDENTITY_ONLY_CONFIRM: u8 = 5;
const IDENTITY_ONLY_ACCEPT: u8 = 6;
const APPLICATION_ROOT_DOMAIN: &[u8] = b"ssh-mobile/session/application/root/v3";
const ROOT_CONFIRM_DOMAIN: &[u8] = b"ssh-mobile/session/application/root-confirm/v3";
const MAX_DEVICE_ID_BYTES: usize = 128;
const MAX_SESSION_BINDING_BYTES: usize = 128;
const MAX_HANDSHAKE_PAYLOAD_BYTES: usize = 4 * 1024;
const MAX_HANDSHAKE_FRAME_BYTES: usize = 64 * 1024;
const NOISE_PUBLIC_KEY_BYTES: usize = 32;
const IDENTITY_PUBLIC_KEY_BYTES: usize = 32;
const SIGNATURE_BYTES: usize = 64;
const ROOT_SEED_BYTES: usize = 32;
const ROOT_CONFIRM_BYTES: usize = 32;
const NOISE_TRANSPORT_TAG_BYTES: usize = 16;

#[cfg(test)]
pub(crate) use generic::respond_generic_with_policy;
pub(crate) use generic::{initiate_generic_with_policy, respond_generic_auto_policy};
pub(crate) use noise::{CryptoHandshakeError, SessionCryptoMaterial};
pub(crate) use quic::{initiate_quic_with_policy, respond_quic_with_policy};
pub(crate) use relay::{
    decode_relay_frame, encode_relay_frame, RelayInitiatorHandshake, RelayResponderConfirmation,
    RelayResponderHandshake, RELAY_CRYPTO_ACCEPT, RELAY_CRYPTO_FINAL, RELAY_CRYPTO_HELLO,
    RELAY_CRYPTO_RESPONSE, RELAY_CRYPTO_ROOT_CONFIRM, RELAY_CRYPTO_ROOT_SEED,
};

#[cfg(test)]
#[allow(unused_imports)]
use crate::connection::GenericConnection;
#[cfg(test)]
#[allow(unused_imports)]
use network_protocol::NETWORK_PROTOCOL_VERSION;
#[cfg(test)]
#[allow(unused_imports)]
use noise::NoiseHandshake;
#[cfg(test)]
#[allow(unused_imports)]
use payload_hello::{
    direct_path_metadata, hello_payload_with_path, parse_hello_with_path,
    proof_payload_with_signature_with_path, relay_path_metadata, validate_direct_path_metadata,
    validate_relay_path_metadata,
};
#[cfg(test)]
#[allow(unused_imports)]
pub(crate) use payload_hello::{
    hello_payload, parse_hello, parse_proof_identity, proof_payload_with_signature, validate_proof,
    verify_proof_signature,
};
#[cfg(test)]
#[allow(unused_imports)]
use payload_root::{append_bytes, append_string};
#[cfg(test)]
#[allow(unused_imports)]
use payload_root::{
    derive_application_root, identity_only_binding_payload, parse_fixed_root_exchange_payload,
    parse_identity_only_binding_payload, parse_root_exchange_payload, root_confirm_payload,
    root_exchange_payload, root_seed_payload, validate_binding,
};
#[cfg(test)]
#[allow(unused_imports)]
use std::collections::HashMap;
#[cfg(test)]
#[allow(unused_imports)]
use std::sync::Arc;
#[cfg(test)]
#[allow(unused_imports)]
use tokio::sync::RwLock;

#[cfg(test)]
#[path = "../tests/crypto_handshake.rs"]
mod tests;
