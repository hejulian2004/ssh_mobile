use ed25519_dalek::VerifyingKey;
use network_identity::DeviceIdentity;
use network_protocol::NETWORK_PROTOCOL_VERSION;

use super::noise::{CryptoHandshakeError, NoiseHandshake};
use super::path_handshake;
use super::payload_root::{
    append_bytes, append_bytes_unchecked, append_string, append_string_unchecked,
    proof_unsigned_length_with_path, validate_binding, Cursor,
};
use super::{
    HANDSHAKE_CAPABILITY, HANDSHAKE_DOMAIN, HANDSHAKE_HELLO_MAGIC, HANDSHAKE_PROOF_MAGIC,
    IDENTITY_PUBLIC_KEY_BYTES, MAX_DEVICE_ID_BYTES, MAX_HANDSHAKE_PAYLOAD_BYTES,
    MAX_SESSION_BINDING_BYTES, NOISE_PUBLIC_KEY_BYTES, SIGNATURE_BYTES,
};
pub(super) fn prologue() -> &'static [u8] {
    HANDSHAKE_DOMAIN
}

pub(super) fn direct_path_metadata(
    session_binding: &str,
    connection_profile: Vec<u8>,
    policy: path_handshake::E2eePolicy,
) -> Result<path_handshake::PathHandshakeMetadata, CryptoHandshakeError> {
    validate_binding(session_binding)?;
    Ok(path_handshake::PathHandshakeMetadata::new(
        policy,
        path_handshake::PathKind::Direct,
        session_binding.as_bytes().to_vec(),
        connection_profile,
    )?)
}

pub(super) fn relay_path_metadata(
    session_binding: &str,
    policy: path_handshake::E2eePolicy,
) -> Result<path_handshake::PathHandshakeMetadata, CryptoHandshakeError> {
    validate_binding(session_binding)?;
    Ok(path_handshake::PathHandshakeMetadata::new(
        policy,
        path_handshake::PathKind::Relay,
        session_binding.as_bytes().to_vec(),
        b"relay-data/v2".to_vec(),
    )?)
}

pub(super) fn validate_direct_path_metadata(
    metadata: &path_handshake::PathHandshakeMetadata,
    profile: &[u8],
    policy: path_handshake::E2eePolicy,
) -> Result<path_handshake::PathSecurity, CryptoHandshakeError> {
    if metadata.path_kind != path_handshake::PathKind::Direct {
        return Err(path_handshake::PathHandshakeError::PathBindingMismatch.into());
    }
    if metadata.connection_profile != profile {
        return Err(path_handshake::PathHandshakeError::ConnectionProfileMismatch.into());
    }
    Ok(metadata.security_for(policy)?)
}

pub(super) fn validate_relay_path_metadata(
    metadata: &path_handshake::PathHandshakeMetadata,
    policy: path_handshake::E2eePolicy,
) -> Result<path_handshake::PathSecurity, CryptoHandshakeError> {
    if metadata.path_kind != path_handshake::PathKind::Relay
        || metadata.connection_profile != b"relay-data/v2"
    {
        return Err(path_handshake::PathHandshakeError::PathBindingMismatch.into());
    }
    Ok(metadata.security_for(policy)?)
}

#[cfg(test)]
pub(crate) fn hello_payload(session_binding: &str) -> Result<Vec<u8>, CryptoHandshakeError> {
    let metadata = direct_path_metadata(
        session_binding,
        b"direct/generic/v2".to_vec(),
        path_handshake::E2eePolicy::Required,
    )?;
    hello_payload_with_path(session_binding, &metadata)
}

pub(super) fn hello_payload_with_path(
    session_binding: &str,
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Result<Vec<u8>, CryptoHandshakeError> {
    validate_binding(session_binding)?;
    let mut payload = Vec::with_capacity(
        4 + 4
            + 2
            + session_binding.len()
            + 4
            + 4
            + 2
            + metadata.path_binding.len()
            + metadata.connection_profile.len()
            + HANDSHAKE_CAPABILITY.len(),
    );
    payload.extend_from_slice(HANDSHAKE_HELLO_MAGIC);
    payload.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
    append_string(&mut payload, session_binding)?;
    metadata.encode(&mut payload)?;
    append_bytes(&mut payload, HANDSHAKE_CAPABILITY)?;
    Ok(payload)
}

#[cfg(test)]
pub(crate) fn parse_hello(payload: &[u8]) -> Result<String, CryptoHandshakeError> {
    parse_hello_with_path(payload)
        .map(|(binding, _)| binding)
        .map_err(|error| match error {
            // The compatibility-only test helper treats a pre-PathHandshake
            // payload as the rejected legacy capability, preserving the
            // fail-closed downgrade assertion without keeping a production
            // legacy parser alive.
            CryptoHandshakeError::Path(_) => CryptoHandshakeError::Unsupported,
            other => other,
        })
}

pub(super) fn parse_hello_with_path(
    payload: &[u8],
) -> Result<(String, path_handshake::PathHandshakeMetadata), CryptoHandshakeError> {
    let mut cursor = Cursor::new(payload);
    if cursor.take(4)? != HANDSHAKE_HELLO_MAGIC || cursor.take_u32()? != NETWORK_PROTOCOL_VERSION {
        return Err(CryptoHandshakeError::Invalid);
    }
    let binding = cursor.take_string(MAX_SESSION_BINDING_BYTES)?;
    validate_binding(&binding)?;
    let metadata = path_handshake::PathHandshakeMetadata::decode(&mut cursor)?;
    if cursor.take_bytes(MAX_HANDSHAKE_PAYLOAD_BYTES)? != HANDSHAKE_CAPABILITY || !cursor.done() {
        return Err(CryptoHandshakeError::Unsupported);
    }
    Ok((binding, metadata))
}

#[cfg(test)]
pub(crate) fn proof_payload_with_signature(
    handshake: &NoiseHandshake,
    role: u8,
    session_binding: &str,
    local_session_binding: &str,
) -> Result<Vec<u8>, CryptoHandshakeError> {
    let metadata = direct_path_metadata(
        session_binding,
        b"direct/generic/v2".to_vec(),
        path_handshake::E2eePolicy::Required,
    )?;
    proof_payload_with_signature_with_path(
        handshake,
        role,
        session_binding,
        local_session_binding,
        &metadata,
    )
}

pub(super) fn proof_payload_with_signature_with_path(
    handshake: &NoiseHandshake,
    role: u8,
    session_binding: &str,
    local_session_binding: &str,
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Result<Vec<u8>, CryptoHandshakeError> {
    validate_binding(session_binding)?;
    validate_binding(local_session_binding)?;
    let unsigned = proof_payload_with_path(
        role,
        &handshake.identity.device_id,
        &handshake.identity_public,
        &handshake.local_static_public,
        session_binding,
        local_session_binding,
        metadata,
    );
    let signature = handshake.identity.sign_proof(&unsigned);
    let mut output = unsigned;
    if signature.len() != SIGNATURE_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    output.extend_from_slice(&signature);
    Ok(output)
}

fn proof_payload_with_path(
    role: u8,
    device_id: &str,
    identity_public: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
    noise_static_public: &[u8; NOISE_PUBLIC_KEY_BYTES],
    session_binding: &str,
    local_session_binding: &str,
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Vec<u8> {
    let mut output = Vec::with_capacity(128);
    output.extend_from_slice(HANDSHAKE_PROOF_MAGIC);
    output.push(role);
    output.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
    append_string_unchecked(&mut output, device_id);
    output.extend_from_slice(identity_public);
    output.extend_from_slice(noise_static_public);
    append_string_unchecked(&mut output, session_binding);
    append_string_unchecked(&mut output, local_session_binding);
    metadata
        .encode(&mut output)
        .expect("validated PathHandshakeV2 metadata is encodable");
    append_bytes_unchecked(&mut output, HANDSHAKE_CAPABILITY);
    output
}

#[cfg(test)]
pub(crate) fn validate_proof(
    payload: &[u8],
    role: u8,
    expected_peer_id: &str,
    expected_peer_key: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
    handshake: &NoiseHandshake,
    session_binding: &str,
) -> Result<String, CryptoHandshakeError> {
    let metadata = direct_path_metadata(
        session_binding,
        b"direct/generic/v2".to_vec(),
        path_handshake::E2eePolicy::Required,
    )?;
    validate_proof_with_path(
        payload,
        role,
        expected_peer_id,
        expected_peer_key,
        handshake,
        session_binding,
        &metadata,
    )
}

pub(super) fn validate_proof_with_path(
    payload: &[u8],
    role: u8,
    expected_peer_id: &str,
    expected_peer_key: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
    handshake: &NoiseHandshake,
    session_binding: &str,
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Result<String, CryptoHandshakeError> {
    let (peer_id, peer_key, local_session_binding) =
        parse_proof_identity_with_path(payload, role, handshake, session_binding, metadata)?;
    if peer_id != expected_peer_id || peer_key != *expected_peer_key {
        return Err(CryptoHandshakeError::UntrustedIdentity);
    }
    verify_proof_signature_with_path(
        payload,
        &peer_id,
        session_binding,
        &local_session_binding,
        &peer_key,
        metadata,
    )?;
    Ok(local_session_binding)
}

#[cfg(test)]
pub(crate) fn verify_proof_signature(
    payload: &[u8],
    peer_id: &str,
    session_binding: &str,
    local_session_binding: &str,
    peer_key: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
) -> Result<(), CryptoHandshakeError> {
    let metadata = direct_path_metadata(
        session_binding,
        b"direct/generic/v2".to_vec(),
        path_handshake::E2eePolicy::Required,
    )?;
    verify_proof_signature_with_path(
        payload,
        peer_id,
        session_binding,
        local_session_binding,
        peer_key,
        &metadata,
    )
}

pub(super) fn verify_proof_signature_with_path(
    payload: &[u8],
    peer_id: &str,
    session_binding: &str,
    local_session_binding: &str,
    peer_key: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Result<(), CryptoHandshakeError> {
    let signature_offset =
        proof_unsigned_length_with_path(peer_id, session_binding, local_session_binding, metadata);
    if payload.len() != signature_offset + SIGNATURE_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    verify_signature(
        peer_key,
        &payload[..signature_offset],
        &payload[signature_offset..],
    )
}

#[cfg(test)]
pub(crate) fn parse_proof_identity(
    payload: &[u8],
    role: u8,
    handshake: &NoiseHandshake,
    session_binding: &str,
) -> Result<(String, [u8; IDENTITY_PUBLIC_KEY_BYTES], String), CryptoHandshakeError> {
    let metadata = direct_path_metadata(
        session_binding,
        b"direct/generic/v2".to_vec(),
        path_handshake::E2eePolicy::Required,
    )?;
    parse_proof_identity_with_path(payload, role, handshake, session_binding, &metadata)
}

pub(super) fn parse_proof_identity_with_path(
    payload: &[u8],
    role: u8,
    handshake: &NoiseHandshake,
    session_binding: &str,
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Result<(String, [u8; IDENTITY_PUBLIC_KEY_BYTES], String), CryptoHandshakeError> {
    let mut cursor = Cursor::new(payload);
    if cursor.take(4)? != HANDSHAKE_PROOF_MAGIC
        || cursor.take_byte()? != role
        || cursor.take_u32()? != NETWORK_PROTOCOL_VERSION
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    let peer_id = cursor.take_string(MAX_DEVICE_ID_BYTES)?;
    let peer_key: [u8; IDENTITY_PUBLIC_KEY_BYTES] = cursor
        .take_fixed(IDENTITY_PUBLIC_KEY_BYTES)?
        .try_into()
        .map_err(|_| CryptoHandshakeError::Invalid)?;
    let noise_static: [u8; NOISE_PUBLIC_KEY_BYTES] = cursor
        .take_fixed(NOISE_PUBLIC_KEY_BYTES)?
        .try_into()
        .map_err(|_| CryptoHandshakeError::Invalid)?;
    if noise_static.as_slice() != remote_noise_static(handshake)? {
        return Err(CryptoHandshakeError::UntrustedIdentity);
    }
    let claimed_session_binding = cursor.take_string(MAX_SESSION_BINDING_BYTES)?;
    let local_session_binding = cursor.take_string(MAX_SESSION_BINDING_BYTES)?;
    let peer_metadata = path_handshake::PathHandshakeMetadata::decode(&mut cursor)?;
    if peer_metadata.e2ee_policy != metadata.e2ee_policy {
        return Err(path_handshake::PathHandshakeError::SecurityPolicyMismatch.into());
    }
    if peer_metadata.path_kind != metadata.path_kind
        || peer_metadata.path_binding != metadata.path_binding
    {
        return Err(path_handshake::PathHandshakeError::PathBindingMismatch.into());
    }
    if peer_metadata.connection_profile != metadata.connection_profile {
        return Err(path_handshake::PathHandshakeError::ConnectionProfileMismatch.into());
    }
    if claimed_session_binding != session_binding
        || validate_binding(&local_session_binding).is_err()
        || cursor.take_bytes(MAX_HANDSHAKE_PAYLOAD_BYTES)? != HANDSHAKE_CAPABILITY
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    if cursor.remaining() != SIGNATURE_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    Ok((peer_id, peer_key, local_session_binding))
}

fn remote_noise_static(handshake: &NoiseHandshake) -> Result<&[u8], CryptoHandshakeError> {
    handshake
        .state
        .get_remote_static()
        .ok_or(CryptoHandshakeError::UntrustedIdentity)
}

fn verify_signature(
    public_key: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
    payload: &[u8],
    signature: &[u8],
) -> Result<(), CryptoHandshakeError> {
    let key = VerifyingKey::from_bytes(public_key).map_err(|_| CryptoHandshakeError::Invalid)?;
    if DeviceIdentity::verify_peer_proof(&key, payload, signature) {
        Ok(())
    } else {
        Err(CryptoHandshakeError::UntrustedIdentity)
    }
}
