use network_identity::DeviceIdentity;
use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;
use tokio::sync::RwLock;

use super::noise::{CryptoHandshakeError, NoiseHandshake, SessionCryptoMaterial};
use super::path_handshake;
use super::payload_hello::{
    direct_path_metadata, hello_payload_with_path, parse_hello_with_path,
    parse_proof_identity_with_path, proof_payload_with_signature_with_path,
    validate_direct_path_metadata, validate_proof_with_path, verify_proof_signature_with_path,
};
use crate::connection::{GenericConnection, RouteTransport};
pub(crate) async fn initiate_generic_with_policy<F, Fut, T>(
    connection: &mut GenericConnection,
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
    let path_metadata = direct_path_metadata(
        session_binding,
        match connection.profile().route().transport() {
            RouteTransport::Tcp => b"direct/tcp/v2".to_vec(),
            RouteTransport::WebSocket => b"direct/websocket/v2".to_vec(),
            RouteTransport::Quic | RouteTransport::Udp => return Err(CryptoHandshakeError::Failed),
        },
        e2ee_policy,
    )?;
    let path_security = path_metadata.security_for(e2ee_policy)?;
    let mut handshake = NoiseHandshake::new(identity, true)?;
    let hello = hello_payload_with_path(session_binding, &path_metadata)?;
    connection
        .send(&handshake.write(&hello)?)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let responder_payload = handshake.read(
        &connection
            .recv()
            .await
            .map_err(|_| CryptoHandshakeError::Failed)?,
    )?;
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
    connection
        .send(&handshake.write(&initiator_proof)?)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let established =
        handshake.into_established_with_security(session_binding.to_string(), path_security)?;
    match path_security {
        path_handshake::PathSecurity::E2ee => {
            let encrypted_seed = connection
                .recv()
                .await
                .map_err(|_| CryptoHandshakeError::Failed)?;
            let initiator = established.accept_root_seed(&encrypted_seed)?;
            let remote_session_binding = initiator.remote_session_binding.clone();
            let (local_session_binding, admission) =
                resolve_remote_session(expected_peer_id, &remote_session_binding).await?;
            let (initiator, encrypted_confirm) = initiator.confirm(local_session_binding)?;
            connection
                .send(&encrypted_confirm)
                .await
                .map_err(|_| CryptoHandshakeError::Failed)?;
            let encrypted_accept = connection
                .recv()
                .await
                .map_err(|_| CryptoHandshakeError::Failed)?;
            Ok((initiator.accept(&encrypted_accept)?, admission))
        }
        path_handshake::PathSecurity::IdentityOnly => {
            let encrypted_binding = connection
                .recv()
                .await
                .map_err(|_| CryptoHandshakeError::Failed)?;
            let initiator = established.accept_identity_only_binding(&encrypted_binding)?;
            let remote_session_binding = initiator.remote_session_binding.clone();
            let (local_session_binding, admission) =
                resolve_remote_session(expected_peer_id, &remote_session_binding).await?;
            let (initiator, encrypted_confirm) = initiator.confirm(local_session_binding)?;
            connection
                .send(&encrypted_confirm)
                .await
                .map_err(|_| CryptoHandshakeError::Failed)?;
            let encrypted_accept = connection
                .recv()
                .await
                .map_err(|_| CryptoHandshakeError::Failed)?;
            Ok((initiator.accept(&encrypted_accept)?, admission))
        }
    }
}

#[cfg(test)]
pub(crate) async fn respond_generic_with_policy<F, Fut, T>(
    connection: &mut GenericConnection,
    identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
    e2ee_policy: path_handshake::E2eePolicy,
    resolve_local_session_binding: F,
) -> Result<(String, SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    respond_generic_internal(
        connection,
        identity,
        trusted_peer_keys,
        Some(e2ee_policy),
        resolve_local_session_binding,
    )
    .await
}

pub(crate) async fn respond_generic_auto_policy<F, Fut, T>(
    connection: &mut GenericConnection,
    identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
    resolve_local_session_binding: F,
) -> Result<(String, SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    respond_generic_internal(
        connection,
        identity,
        trusted_peer_keys,
        None,
        resolve_local_session_binding,
    )
    .await
}

async fn respond_generic_internal<F, Fut, T>(
    connection: &mut GenericConnection,
    identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
    e2ee_policy: Option<path_handshake::E2eePolicy>,
    resolve_local_session_binding: F,
) -> Result<(String, SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    let mut handshake = NoiseHandshake::new(identity, false)?;
    let hello = handshake.read(
        &connection
            .recv()
            .await
            .map_err(|_| CryptoHandshakeError::Failed)?,
    )?;
    let (session_binding, path_metadata) = parse_hello_with_path(&hello)?;
    let path_security = validate_direct_path_metadata(
        &path_metadata,
        match connection.profile().route().transport() {
            RouteTransport::Tcp => b"direct/tcp/v2".as_slice(),
            RouteTransport::WebSocket => b"direct/websocket/v2".as_slice(),
            RouteTransport::Quic | RouteTransport::Udp => return Err(CryptoHandshakeError::Failed),
        },
        e2ee_policy.unwrap_or(path_metadata.e2ee_policy),
    )?;
    // Generic routes do not expose the authenticated peer identity until the
    // initiator proof arrives. Keep the responder proof bound to the same
    // initiator Session binding; the actual responder binding is carried in
    // the encrypted RootSeed exchange after ConnectionSessionStore admission.
    let responder_proof = proof_payload_with_signature_with_path(
        &handshake,
        2,
        &session_binding,
        &session_binding,
        &path_metadata,
    )?;
    connection
        .send(&handshake.write(&responder_proof)?)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let initiator_payload = handshake.read(
        &connection
            .recv()
            .await
            .map_err(|_| CryptoHandshakeError::Failed)?,
    )?;
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
    match path_security {
        path_handshake::PathSecurity::E2ee => {
            let (responder, encrypted_seed) =
                established.begin_responder(&local_session_binding)?;
            connection
                .send(&encrypted_seed)
                .await
                .map_err(|_| CryptoHandshakeError::Failed)?;
            let encrypted_confirm = connection
                .recv()
                .await
                .map_err(|_| CryptoHandshakeError::Failed)?;
            let (encrypted_accept, material) = responder.accept_confirm(&encrypted_confirm)?;
            connection
                .send(&encrypted_accept)
                .await
                .map_err(|_| CryptoHandshakeError::Failed)?;
            Ok((peer_id, material, admission))
        }
        path_handshake::PathSecurity::IdentityOnly => {
            let (responder, encrypted_binding) =
                established.begin_identity_only(&local_session_binding)?;
            connection
                .send(&encrypted_binding)
                .await
                .map_err(|_| CryptoHandshakeError::Failed)?;
            let encrypted_confirm = connection
                .recv()
                .await
                .map_err(|_| CryptoHandshakeError::Failed)?;
            let (encrypted_accept, material) = responder.accept_confirm(&encrypted_confirm)?;
            connection
                .send(&encrypted_accept)
                .await
                .map_err(|_| CryptoHandshakeError::Failed)?;
            Ok((peer_id, material, admission))
        }
    }
}
