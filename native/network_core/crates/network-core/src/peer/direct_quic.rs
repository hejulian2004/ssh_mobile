use network_identity::DeviceIdentity;
use network_nat::Candidate;
use network_protocol::{NetworkError as ProtocolError, NetworkErrorCode, RouteType};
use network_quic::QuicPeerSession;
use quinn::{Connection, Endpoint, VarInt};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::watch;

use crate::connect::{CAPABILITY_UNRELIABLE_DATAGRAM, DEFAULT_CONNECTION_CAPABILITY};
use crate::connection::ConnectionProfile;
use crate::crypto_handshake::SessionCryptoMaterial;
use crate::events::protocol_error_with_peer;
use crate::runtime::{ConnectionAdmissionLease, RuntimeState, PEER_CONNECT_TIMEOUT};
use crate::session::{ConnectionAdmissionError, SessionId};

use super::direct_race::connect_direct_candidates_with_crypto;
use super::ConnectedRoute;

/// Direct QUIC 尝试的总预算为 8 秒，避免连接和认证各自再等待一次。
pub(crate) async fn connect_direct(
    endpoint: Endpoint,
    peer_endpoint: SocketAddr,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    attempt_id: String,
    connect_window: Duration,
) -> Result<Connection, ProtocolError> {
    let timeout_peer_id = peer_id.clone();
    tracing::debug!(
        peer_id = %peer_id,
        attempt_id = %attempt_id,
        ?connect_window,
        remote = %peer_endpoint,
        "starting authenticated QUIC candidate attempt"
    );
    let attempt = async move {
        let connecting = endpoint.connect(peer_endpoint, "ssh-mobile").map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::QuicError,
                "failed to create QUIC connection",
                "connect",
                &peer_id,
            )
        })?;
        let connection = connecting.await.map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::QuicError,
                "QUIC connection failed",
                "connect",
                &peer_id,
            )
        })?;
        let session = QuicPeerSession::new(connection.clone(), peer_id.clone());
        session
            .perform_handshake(&identity, expected_peer_public_key)
            .await
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::AuthenticationFailed,
                    "peer authentication failed",
                    "connect",
                    &peer_id,
                )
            })?;
        Ok::<Connection, ProtocolError>(connection)
    };
    tokio::time::timeout(connect_window.min(PEER_CONNECT_TIMEOUT), attempt)
        .await
        .map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "Direct QUIC connection timed out",
                "connect",
                &timeout_peer_id,
            )
        })?
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn connect_direct_with_crypto(
    endpoint: Endpoint,
    peer_endpoint: SocketAddr,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    attempt_id: String,
    connect_window: Duration,
    session_binding: &str,
    state: Arc<RuntimeState>,
    expected_session_id: Option<SessionId>,
    required_capabilities: u8,
) -> Result<(Connection, SessionCryptoMaterial, ConnectionAdmissionLease), ProtocolError> {
    let quic_profile =
        ConnectionProfile::for_route(RouteType::QuicDirect).expect("QUIC route profile");
    if !crate::connect::profile_satisfies(quic_profile, required_capabilities) {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "QUIC candidate does not satisfy the requested capability",
            "connect",
            &peer_id,
        ));
    }
    let started = Instant::now();
    let connection = connect_direct(
        endpoint,
        peer_endpoint,
        Arc::clone(&identity),
        expected_peer_public_key,
        peer_id.clone(),
        attempt_id,
        connect_window,
    )
    .await?;
    let remaining = connect_window
        .min(PEER_CONNECT_TIMEOUT)
        .saturating_sub(started.elapsed());
    let e2ee_policy = state.e2ee_policy(&peer_id).await;
    let expected_peer_id_for_resolver = peer_id.clone();
    let admission_state = Arc::clone(&state);
    let (crypto, admission) = tokio::time::timeout(
        remaining,
        crate::crypto_handshake::initiate_quic_with_policy(
            &connection,
            identity,
            &peer_id,
            expected_peer_public_key,
            session_binding,
            e2ee_policy,
            move |authenticated_peer_id, remote_session_binding| {
                let state = Arc::clone(&admission_state);
                let authenticated_peer_id = authenticated_peer_id.to_string();
                let remote_session_binding = remote_session_binding.to_string();
                async move {
                    if authenticated_peer_id != expected_peer_id_for_resolver {
                        return Err(crate::crypto_handshake::CryptoHandshakeError::Failed);
                    }
                    let admission = admit_single_winner(
                        &state,
                        &authenticated_peer_id,
                        expected_session_id,
                        &remote_session_binding,
                    )
                    .await
                    .map_err(|_| crate::crypto_handshake::CryptoHandshakeError::Failed)?;
                    Ok((admission.session_id.wire_key(), admission))
                }
            },
        ),
    )
    .await
    .map_err(|_| {
        protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "application E2EE handshake timed out",
            "connect",
            &peer_id,
        )
    })?
    .map_err(|_| {
        protocol_error_with_peer(
            NetworkErrorCode::AuthenticationFailed,
            "application E2EE handshake failed",
            "connect",
            &peer_id,
        )
    })?;
    if state.connection_sessions.current_session_id(&peer_id).await != Some(admission.session_id) {
        state
            .release_claimed_session(
                &peer_id,
                admission.session_id,
                &crypto.remote_session_binding,
            )
            .await;
        connection.close(VarInt::from_u32(0), b"candidate lacks requested capability");
        return Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "QUIC candidate Session was replaced before route publication",
            "connect",
            &peer_id,
        ));
    }
    Ok((connection, crypto, admission))
}

/// Single-winner Session admission（§18/§40 Concurrency）。
///
/// `connect_direct_candidates_with_crypto` 并发 race 多个 candidate 时，每个 candidate
/// 都会走到 `admit_authenticated_session`。若 winner 已把 route 挂到 Session（state →
/// Connected），loser 迟到的 admit 会触发 `ReplaceWithNew`：拆掉刚挂载的 winning route，
/// 双方都掉线。本 guard 在 admit 前重查当前 Session 状态——仍处于 in-flight（未挂载、
/// 未被替换）才继续 admit，否则视为 loser 拒绝，绝不触发替换。只服务发起方候选
/// （expected_session_id 已知）；应答方 simultaneous connect 的 Initialize 语义不受影响。
pub(crate) async fn admit_single_winner(
    state: &RuntimeState,
    peer_id: &str,
    expected_session_id: Option<SessionId>,
    remote_session_binding: &str,
) -> Result<ConnectionAdmissionLease, ConnectionAdmissionError> {
    loop {
        let changed = state.path_change_notified();
        tokio::pin!(changed);
        // Session 已 Connected（winner 已挂载 route）：后来的 candidate 是 loser，拒绝。
        if state.path_is_connected(peer_id).await {
            return Err(ConnectionAdmissionError::StaleSession);
        }
        // 期望的 Session 已被替换/销毁：同样是 loser。
        if let Some(expected) = expected_session_id {
            if state.connection_sessions.current_session_id(peer_id).await != Some(expected) {
                return Err(ConnectionAdmissionError::StaleSession);
            }
        }
        match state
            .admit_authenticated_session(peer_id, expected_session_id, remote_session_binding)
            .await
        {
            Ok(admission) => return Ok(admission),
            Err(ConnectionAdmissionError::StaleSession)
                if state
                    .path_admission_can_retry(peer_id, expected_session_id)
                    .await =>
            {
                changed.await;
            }
            Err(error) => return Err(error),
        }
    }
}

/// Responder-side authenticated candidate checks started from an inbound
/// ConnectivityOffer. The normal accept loops remain available as the other
/// half of the simultaneous check; this task additionally punches toward the
/// initiator's advertised candidates within the same bounded window.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn connect_responder_direct(
    endpoint: Endpoint,
    candidates: Vec<Candidate>,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    attempt_id: String,
    session_binding: String,
    state: Arc<RuntimeState>,
    connect_window: Duration,
) -> Result<ConnectedRoute, ProtocolError> {
    let (candidate_update_tx, candidate_updates) = watch::channel::<Option<Vec<Candidate>>>(None);
    drop(candidate_update_tx);
    let deadline = Instant::now() + connect_window;
    let (connection, crypto, admission) = connect_direct_candidates_with_crypto(
        endpoint,
        candidates,
        identity,
        expected_peer_public_key,
        peer_id,
        attempt_id,
        deadline,
        session_binding,
        state,
        None,
        DEFAULT_CONNECTION_CAPABILITY | CAPABILITY_UNRELIABLE_DATAGRAM,
        candidate_updates,
    )
    .await?;
    Ok(ConnectedRoute::Quic {
        connection,
        crypto,
        admission,
    })
}
