use network_identity::DeviceIdentity;
use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::RwLock;

use super::noise::{CryptoHandshakeError, NoiseHandshake, SessionCryptoMaterial};
use super::path_handshake;
use super::payload_hello::{
    direct_path_metadata, hello_payload_with_path, parse_hello_with_path,
    parse_proof_identity_with_path, proof_payload_with_signature_with_path,
    validate_direct_path_metadata, validate_proof_with_path, verify_proof_signature_with_path,
};
use super::MAX_HANDSHAKE_FRAME_BYTES;
pub(crate) async fn initiate_quic_with_policy<F, Fut, T>(
    connection: &quinn::Connection,
    identity: Arc<DeviceIdentity>,
    expected_peer_id: &str,
    expected_peer_identity_key: [u8; 32],
    session_binding: &str,
    e2ee_policy: path_handshake::E2eePolicy,
    resolve_remote_session: F,
) -> Result<(SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    let (mut send, mut recv) = connection
        .open_bi()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let path_metadata =
        direct_path_metadata(session_binding, b"direct/quic/v2".to_vec(), e2ee_policy)?;
    let path_security = path_metadata.security_for(e2ee_policy)?;
    let mut handshake = NoiseHandshake::new(identity, true)?;
    write_quic_frame(
        &mut send,
        &handshake.write(&hello_payload_with_path(session_binding, &path_metadata)?)?,
    )
    .await?;
    let responder_payload = handshake.read(&read_quic_frame(&mut recv).await?)?;
    let _remote_session_binding = validate_proof_with_path(
        &responder_payload,
        2,
        expected_peer_id,
        &expected_peer_identity_key,
        &handshake,
        session_binding,
        &path_metadata,
    )?;
    let initiator_proof = proof_payload_with_signature_with_path(
        &handshake,
        1,
        session_binding,
        session_binding,
        &path_metadata,
    )?;
    write_quic_frame(&mut send, &handshake.write(&initiator_proof)?).await?;
    let established =
        handshake.into_established_with_security(session_binding.to_string(), path_security)?;
    let (material, admission) = match path_security {
        path_handshake::PathSecurity::E2ee => {
            let encrypted_seed = read_quic_frame(&mut recv).await?;
            let initiator = established.accept_root_seed(&encrypted_seed)?;
            let remote_session_binding = initiator.remote_session_binding.clone();
            let (local_session_binding, admission) =
                resolve_remote_session(expected_peer_id, &remote_session_binding).await?;
            let (initiator, encrypted_confirm) = initiator.confirm(local_session_binding)?;
            write_quic_frame(&mut send, &encrypted_confirm).await?;
            let encrypted_accept = read_quic_frame(&mut recv).await?;
            (initiator.accept(&encrypted_accept)?, admission)
        }
        path_handshake::PathSecurity::IdentityOnly => {
            let encrypted_binding = read_quic_frame(&mut recv).await?;
            let initiator = established.accept_identity_only_binding(&encrypted_binding)?;
            let remote_session_binding = initiator.remote_session_binding.clone();
            let (local_session_binding, admission) =
                resolve_remote_session(expected_peer_id, &remote_session_binding).await?;
            let (initiator, encrypted_confirm) = initiator.confirm(local_session_binding)?;
            write_quic_frame(&mut send, &encrypted_confirm).await?;
            let encrypted_accept = read_quic_frame(&mut recv).await?;
            (initiator.accept(&encrypted_accept)?, admission)
        }
    };
    send.finish().map_err(|_| CryptoHandshakeError::Failed)?;
    Ok((material, admission))
}

pub(crate) async fn respond_quic_with_policy<F, Fut, T>(
    connection: &quinn::Connection,
    identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
    e2ee_policy: path_handshake::E2eePolicy,
    resolve_local_session_binding: F,
) -> Result<(String, SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    let (mut send, mut recv) = connection
        .accept_bi()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let mut handshake = NoiseHandshake::new(identity, false)?;
    let (session_binding, path_metadata) =
        parse_hello_with_path(&handshake.read(&read_quic_frame(&mut recv).await?)?)?;
    let path_security =
        validate_direct_path_metadata(&path_metadata, b"direct/quic/v2", e2ee_policy)?;
    // The peer identity is not available until the final Noise proof. Use the
    // initiator binding as a pre-authentication placeholder; the authenticated
    // local binding is sent after the identity proof. Required uses RootSeed;
    // Disabled uses only the identity-only binding exchange.
    let responder_proof = proof_payload_with_signature_with_path(
        &handshake,
        2,
        &session_binding,
        &session_binding,
        &path_metadata,
    )?;
    write_quic_frame(&mut send, &handshake.write(&responder_proof)?).await?;
    let initiator_payload = handshake.read(&read_quic_frame(&mut recv).await?)?;
    let (peer_id, peer_key, peer_session_binding) = parse_proof_identity_with_path(
        &initiator_payload,
        1,
        &handshake,
        &session_binding,
        &path_metadata,
    )?;
    if peer_session_binding != session_binding {
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
        &session_binding,
        &peer_session_binding,
        &peer_key,
        &path_metadata,
    )?;
    let (local_session_binding, admission) =
        resolve_local_session_binding(&peer_id, &session_binding).await?;
    let established =
        handshake.into_established_with_security(session_binding.clone(), path_security)?;
    let material = match path_security {
        path_handshake::PathSecurity::E2ee => {
            let (responder, encrypted_seed) =
                established.begin_responder(&local_session_binding)?;
            write_quic_frame(&mut send, &encrypted_seed).await?;
            let encrypted_confirm = read_quic_frame(&mut recv).await?;
            let (encrypted_accept, material) = responder.accept_confirm(&encrypted_confirm)?;
            write_quic_frame(&mut send, &encrypted_accept).await?;
            material
        }
        path_handshake::PathSecurity::IdentityOnly => {
            let (responder, encrypted_binding) =
                established.begin_identity_only(&local_session_binding)?;
            write_quic_frame(&mut send, &encrypted_binding).await?;
            let encrypted_confirm = read_quic_frame(&mut recv).await?;
            let (encrypted_accept, material) = responder.accept_confirm(&encrypted_confirm)?;
            write_quic_frame(&mut send, &encrypted_accept).await?;
            material
        }
    };
    send.finish().map_err(|_| CryptoHandshakeError::Failed)?;
    Ok((peer_id, material, admission))
}

async fn write_quic_frame(
    stream: &mut quinn::SendStream,
    payload: &[u8],
) -> Result<(), CryptoHandshakeError> {
    if payload.is_empty() || payload.len() > MAX_HANDSHAKE_FRAME_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    stream
        .write_u32(payload.len() as u32)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    stream
        .write_all(payload)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)
}

async fn read_quic_frame(stream: &mut quinn::RecvStream) -> Result<Vec<u8>, CryptoHandshakeError> {
    let length = stream
        .read_u32()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)? as usize;
    if length == 0 || length > MAX_HANDSHAKE_FRAME_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    let mut payload = vec![0u8; length];
    stream
        .read_exact(&mut payload)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    Ok(payload)
}
