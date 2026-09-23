use network_protocol::{PeerConnectionState, RouteType};
use network_quic::QuicPeerSession;
use network_transport::{TcpTransport, Transport, WebSocketTransport};
use quinn::Endpoint;
use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpListener;

use crate::connect::profile_capability_mask;
use crate::connection::{ConnectionProfile, GenericConnection};
use crate::events::{emit_peer_state, emit_route_changed};
use crate::runtime::{RuntimeState, PEER_CONNECT_TIMEOUT};

use super::receiver::ConnectionReceiverSupervisor;
use super::registry::install_admitted_crypto;
use super::GENERIC_ROUTE_CONNECT_TIMEOUT;

/// TCP fallback accept 循环在瞬态错误（EMFILE/ENOBUFS/aborted）后的退避间隔，避免
/// 热点重试（§40）。
const TCP_ACCEPT_RETRY_BACKOFF: Duration = Duration::from_millis(50);
const TCP_ACCEPT_RETRY_BACKOFF_MAX: Duration = Duration::from_millis(500);

/// Owns runtime-scoped QUIC/TCP accept loops and authenticated admission.
pub(crate) struct InboundConnectionAcceptor;

impl InboundConnectionAcceptor {
    /// 接受配置运行时的传入 QUIC 连接。
    pub(crate) async fn accept_connections(endpoint: Endpoint, state: Arc<RuntimeState>) {
        while let Some(incoming) = endpoint.accept().await {
            let state = Arc::clone(&state);
            let supervisor = Arc::clone(&state.task_supervisor);
            let _ = supervisor.spawn_runtime("incoming-quic-handshake", async move {
                let mut attempted_session = None;
                let result = async {
                    let connection = incoming.await?;
                    let identity = state
                        .lifecycle
                        .identity
                        .read()
                        .await
                        .clone()
                        .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?;
                    let session = tokio::time::timeout(
                        PEER_CONNECT_TIMEOUT,
                        QuicPeerSession::accept_trusted(
                            connection,
                            &identity,
                            &state.trusted_peer_keys,
                        ),
                    )
                    .await
                    .map_err(|_| {
                        std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "peer authentication timed out",
                        )
                    })??;
                    let peer_id = session.peer_device_id.clone();
                    if !state
                        .route_is_authorized(&peer_id, crate::connection::RouteTopology::Direct)
                        .await
                    {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::PermissionDenied,
                            "Direct route is not authorized for inbound peer",
                        )
                        .into());
                    }
                    let connection = session.connection.clone();
                    let e2ee_policy = state.e2ee_policy(&peer_id).await;
                    let binding_state = Arc::clone(&state);
                    let crypto = tokio::time::timeout(
                        PEER_CONNECT_TIMEOUT,
                        crate::crypto_handshake::respond_quic_with_policy(
                            &connection,
                            state
                                .lifecycle
                                .identity
                                .read()
                                .await
                                .clone()
                                .ok_or_else(|| {
                                    std::io::Error::other("runtime identity unavailable")
                                })?,
                            &state.trusted_peer_keys,
                            e2ee_policy,
                            move |authenticated_peer_id, remote_session_binding| {
                                let binding_state = Arc::clone(&binding_state);
                                let authenticated_peer_id = authenticated_peer_id.to_string();
                                let remote_session_binding = remote_session_binding.to_string();
                                async move {
                                    let admission = binding_state
                                        .admit_authenticated_session(
                                            &authenticated_peer_id,
                                            None,
                                            &remote_session_binding,
                                        )
                                        .await
                                        .map_err(|_| {
                                            crate::crypto_handshake::CryptoHandshakeError::Failed
                                        })?;
                                    Ok((admission.session_id.wire_key(), admission))
                                }
                            },
                        ),
                    )
                    .await
                    .map_err(|_| {
                        std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "application E2EE handshake timed out",
                        )
                    })??;
                    let (authenticated_peer_id, crypto, admission) = crypto;
                    if authenticated_peer_id != peer_id {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::PermissionDenied,
                            "application E2EE identity does not match transport peer",
                        )
                        .into());
                    }
                    let session_id = admission.session_id;
                    if session_id.wire_key() != crypto.local_session_binding {
                        return Err(std::io::Error::other(
                            "responder Session binding became stale",
                        )
                        .into());
                    }
                    let quic_profile = ConnectionProfile::for_route(RouteType::QuicDirect)
                        .expect("QUIC route profile");
                    if !state
                        .candidate_supports_required(&peer_id, session_id, quic_profile)
                        .await
                    {
                        state
                            .release_claimed_session(
                                &peer_id,
                                session_id,
                                &crypto.remote_session_binding,
                            )
                            .await;
                        return Err(std::io::Error::other(
                            "inbound QUIC route lacks the requested capability",
                        )
                        .into());
                    }
                    attempted_session = Some((peer_id.clone(), session_id));
                    state
                        .connection_sessions
                        .finalize_authenticated_session(
                            &peer_id,
                            session_id,
                            &crypto.remote_session_binding,
                        )
                        .await
                        .map_err(|_| {
                            std::io::Error::other("Session was replaced during handshake")
                        })?;
                    install_admitted_crypto(&state, &peer_id, &admission, &crypto).await?;
                    let _previous_route = state
                        .attach_connection_for_session(
                            &peer_id,
                            Some(session_id),
                            connection.clone(),
                            RouteType::QuicDirect,
                        )
                        .await
                        .map_err(|_| std::io::Error::other("Session was closed"))?;
                    if state.connection_sessions.current_session_id(&peer_id).await
                        != Some(session_id)
                    {
                        return Err(std::io::Error::other("Session was closed").into());
                    }
                    Self::admit_authenticated_inbound(
                        &state,
                        &peer_id,
                        profile_capability_mask(quic_profile),
                    )
                    .await?;
                    emit_peer_state(
                        &state.event_tx,
                        &peer_id,
                        PeerConnectionState::Connected,
                        RouteType::QuicDirect,
                        None,
                    );
                    // transport-network v2：路径指标只发一次快照（§36 无后台路径迁移）。
                    emit_route_changed(
                        &state.event_tx,
                        &peer_id,
                        RouteType::QuicDirect,
                        connection.remote_address(),
                        connection.rtt().as_millis().min(u32::MAX as u128) as u32,
                        0.0,
                    );
                    crate::channel::recover_session(Arc::clone(&state), peer_id.clone()).await;
                    // §19：业务状态（Transfer）不属于 Session；每条新连接都尝试恢复暂停传输。
                    crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.clone())
                        .await;
                    ConnectionReceiverSupervisor::spawn_session_receivers(
                        Arc::clone(&state),
                        peer_id,
                        connection,
                        session_id,
                    );
                    Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
                }
                .await;
                if let Err(error) = result {
                    if let Some((peer_id, session_id)) = attempted_session {
                        state.fail_session(&peer_id, session_id).await;
                    }
                    tracing::warn!("Rejected inbound QUIC connection: {}", error);
                }
            });
        }
    }
}

/// Accepts TCP fallback sockets on the same numeric port as the QUIC UDP
/// endpoint. A socket is not admitted into a Session until the generic
/// Ed25519/Session-binding handshake succeeds.
///
/// §40：瞬态 accept 错误（EMFILE / ENOBUFS / aborted / reset 等）只记录并退避后继续，
/// 绝不终止 inbound TCP/WS 回退；只有致命错误（listener 已关闭）或任务被取消才退出。
impl InboundConnectionAcceptor {
    pub(crate) async fn accept_tcp_connections(listener: TcpListener, state: Arc<RuntimeState>) {
        Self::accept_tcp_loop(listener, state, Box::new(ListenerAccept)).await;
    }
}

/// §40 TCP accept 步骤的 future 类型（提取别名，避免 clippy type_complexity）。
pub(crate) type AcceptFuture<'a> =
    Pin<Box<dyn Future<Output = std::io::Result<(tokio::net::TcpStream, SocketAddr)>> + Send + 'a>>;

/// TCP fallback accept 步骤抽象（§40 可注入，便于测试注入瞬态错误）。
pub(crate) trait TcpAcceptStep: Send {
    fn accept<'a>(&'a mut self, listener: &'a TcpListener) -> AcceptFuture<'a>;
}

/// 生产 accept 步骤：直接委托给 tokio 的 `TcpListener::accept`。
struct ListenerAccept;

impl TcpAcceptStep for ListenerAccept {
    fn accept<'a>(
        &'a mut self,
        listener: &'a TcpListener,
    ) -> Pin<
        Box<dyn Future<Output = std::io::Result<(tokio::net::TcpStream, SocketAddr)>> + Send + 'a>,
    > {
        Box::pin(listener.accept())
    }
}

/// TCP fallback accept 核心循环。`accept` 步骤可注入，便于测试注入瞬态错误。
impl InboundConnectionAcceptor {
    pub(crate) async fn accept_tcp_loop(
        listener: TcpListener,
        state: Arc<RuntimeState>,
        mut accept: Box<dyn TcpAcceptStep>,
    ) {
        let mut backoff = TCP_ACCEPT_RETRY_BACKOFF;
        loop {
            let (stream, peer_address) = match accept.accept(&listener).await {
                Ok(connection) => connection,
                Err(error) => {
                    if Self::accept_error_is_fatal(&error) {
                        tracing::debug!(%error, "TCP fallback accept loop stopped");
                        return;
                    }
                    tracing::debug!(
                        %error,
                        "transient TCP fallback accept error; retrying after backoff"
                    );
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(TCP_ACCEPT_RETRY_BACKOFF_MAX);
                    continue;
                }
            };
            // 一次成功 accept 说明瞬态资源压力已缓解：复位退避。
            backoff = TCP_ACCEPT_RETRY_BACKOFF;
            let state = Arc::clone(&state);
            let supervisor = Arc::clone(&state.task_supervisor);
            let _ = supervisor.spawn_runtime("incoming-tcp-handshake", async move {
                let mut probe = [0u8; 4];
                let looks_like_websocket =
                    tokio::time::timeout(GENERIC_ROUTE_CONNECT_TIMEOUT, stream.peek(&mut probe))
                        .await
                        .ok()
                        .and_then(Result::ok)
                        .is_some_and(|length| length == probe.len() && &probe == b"GET ");
                #[cfg(test)]
                if !looks_like_websocket
                    && !state.lifecycle.tcp_fallback_enabled.load(Ordering::Acquire)
                {
                    return;
                }
                let connection = if looks_like_websocket {
                    WebSocketTransport::accept(stream).await.map(|socket| {
                        GenericConnection::from_transport(Transport::WebSocket(Box::new(socket)))
                    })
                } else {
                    Ok(GenericConnection::from_transport(Transport::Tcp(
                        TcpTransport::from_stream(stream),
                    )))
                };
                let result = match connection {
                    Ok(connection) => {
                        Self::accept_authenticated_generic(state, connection, peer_address).await
                    }
                    Err(error) => Err(error.into()),
                };
                if let Err(error) = result {
                    tracing::debug!(%error, "rejected inbound TCP fallback route");
                }
            });
        }
    }

    /// accept 错误是否致命：仅 listener 已关闭（fd 失效）视为致命；其余（EMFILE / ENOBUFS /
    /// aborted / reset / interrupted 等）都是瞬态错误，应退避重试。
    pub(crate) fn accept_error_is_fatal(error: &std::io::Error) -> bool {
        matches!(
            error.kind(),
            std::io::ErrorKind::InvalidInput | std::io::ErrorKind::Unsupported
        )
    }
}
