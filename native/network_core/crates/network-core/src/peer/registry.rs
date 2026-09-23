use network_protocol::{
    NetworkError as ProtocolError, NetworkErrorCode, PeerConnectionState, RouteType,
    UpsertPeerCommand,
};
use std::net::SocketAddr;

use crate::crypto_handshake::SessionCryptoMaterial;
use crate::events::{emit_peer_state, protocol_error};
use crate::runtime::{ConnectionAdmissionLease, PeerConfig, RuntimeState};

/// Installs the fresh Noise root for a Session admission（§18 1:1）. The root is
/// always new per connection; there is no ContinueExisting path. Responder
/// handshakes use this after selecting the final local binding before sending
/// the RootSeed.
pub(crate) async fn install_admitted_crypto(
    state: &RuntimeState,
    peer_id: &str,
    admission: &ConnectionAdmissionLease,
    crypto: &SessionCryptoMaterial,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !crypto.has_application_e2ee() {
        return Ok(());
    }
    if state.connection_sessions.current_session_id(peer_id).await != Some(admission.session_id) {
        state.fail_session(peer_id, admission.session_id).await;
        return Err(std::io::Error::other("application E2EE admission is stale").into());
    }
    if state
        .install_crypto_material(peer_id, &admission.session_id.wire_key(), crypto)
        .is_err()
    {
        state.fail_session(peer_id, admission.session_id).await;
        return Err(std::io::Error::other("application E2EE install failed").into());
    }
    Ok(())
}

/// 校验并保存一个对端路由及其可信身份密钥。
#[cfg(test)]
pub(crate) async fn upsert_peer(
    state: &RuntimeState,
    command: UpsertPeerCommand,
) -> Result<(), ProtocolError> {
    upsert_peer_with_policy(state, command, network_protocol::E2eePolicy::Required).await
}

pub(crate) async fn upsert_peer_with_policy(
    state: &RuntimeState,
    command: UpsertPeerCommand,
    e2ee_policy: network_protocol::E2eePolicy,
) -> Result<(), ProtocolError> {
    if command.peer_id.is_empty() || command.peer_id.len() > 128 {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id must contain 1-128 characters",
        ));
    }
    let endpoint = if command.endpoint_address.is_empty() {
        None
    } else {
        Some(
            command
                .endpoint_address
                .parse::<SocketAddr>()
                .map_err(|_| {
                    protocol_error(
                        NetworkErrorCode::InvalidArgument,
                        "peer endpoint must be an IP socket address",
                    )
                })?,
        )
    };
    let identity_public_key: [u8; 32] = command.identity_public_key.try_into().map_err(|_| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer identity key must contain 32 bytes",
        )
    })?;
    let e2e_public_key: [u8; 32] = command.e2e_public_key.try_into().map_err(|_| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer E2E key must contain 32 bytes",
        )
    })?;
    state
        .peer_supervisors
        .get_or_create_with_configured(&command.peer_id, true)
        .map_err(|error| protocol_error(NetworkErrorCode::InvalidArgument, error.to_string()))?;
    // transport-network v2：upsert 只保存配置 endpoint 与可信密钥；对端候选不再存
    // 全局 path_manager（§12/§29）。每次 connect 前由 ConnectivityAttemptCoordinator 经 Resolve
    // 获取权威 Discovery，本地配置 endpoint 作为 Direct 候选追加。
    state.peers.write().await.insert(
        command.peer_id.clone(),
        PeerConfig {
            endpoint,
            identity_public_key,
            e2e_public_key,
            e2ee_policy,
        },
    );
    state
        .trusted_peer_keys
        .write()
        .await
        .insert(command.peer_id, identity_public_key);
    Ok(())
}

/// 停止活跃对端任务，并发布类型化断开状态。
pub(crate) async fn disconnect_peer(
    state: &RuntimeState,
    peer_id: String,
) -> Result<(), ProtocolError> {
    if peer_id.is_empty() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id is required",
        ));
    }
    state
        .peer_supervisors
        .disconnect(&peer_id)
        .map_err(|error| protocol_error(NetworkErrorCode::InvalidArgument, error.to_string()))?;
    let session_id = state.connection_sessions.current_session_id(&peer_id).await;
    let _ = state.close_transport_path(&peer_id).await;
    if let Some(session_id) = session_id {
        let _ = state
            .connection_sessions
            .retire_session(&peer_id, session_id)
            .await;
        state.cancel_session_tasks(&peer_id, session_id).await;
        // Explicit Peer disconnect releases receive-side active handlers and
        // ordered buffers. A transient Connection loss takes a different path
        // (Session destroyed) and must keep them for Delivery recovery（§20）——
        // 因此清理只发生在用户显式断开时，transport 丢失不清理。
        state.delivery.close_peer(&peer_id).await;
    }
    // transport-network v2：断开时注销连接登记（§34）。
    state.ready_session_index.unregister(&peer_id);
    emit_peer_state(
        &state.event_tx,
        &peer_id,
        PeerConnectionState::Disconnected,
        RouteType::Unspecified,
        None,
    );
    Ok(())
}
