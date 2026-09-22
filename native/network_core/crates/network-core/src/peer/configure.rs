use network_identity::DeviceIdentity;
use network_nat::PathManager;
use network_protocol::{NetworkError as ProtocolError, NetworkErrorCode};
use network_quic::QuicEndpointManager;
use std::net::SocketAddr;
use std::sync::{atomic::Ordering, Arc};
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::time::timeout;

use crate::events::protocol_error;
use crate::runtime::RuntimeState;

use super::direct_race::monotonic_candidate_generation;
use super::inbound::InboundConnectionAcceptor;

const STUN_SERVERS_ENV: &str = "SSH_MOBILE_STUN_SERVERS";
const STUN_PROBE_TIMEOUT: Duration = Duration::from_millis(750);

/// 校验运行时密钥并启动 QUIC 监听器。
pub(crate) async fn configure_runtime(
    state: Arc<RuntimeState>,
    command: network_protocol::ConfigureRuntimeCommand,
) -> Result<(), ProtocolError> {
    if command.device_id.is_empty() || command.device_id.len() > 128 {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "device_id must contain 1-128 characters",
        ));
    }
    let identity_private_key: [u8; 32] = command
        .identity_private_key
        .try_into()
        .map_err(|_| protocol_error(NetworkErrorCode::InvalidArgument, "invalid identity key"))?;
    let e2e_private_key: [u8; 32] = command
        .e2e_private_key
        .try_into()
        .map_err(|_| protocol_error(NetworkErrorCode::InvalidArgument, "invalid E2E key"))?;
    let listen_address = command.listen_address.parse::<SocketAddr>().map_err(|_| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "listen_address must be an IP socket address",
        )
    })?;
    let receive_directory = std::path::PathBuf::from(command.receive_directory);
    if !receive_directory.is_absolute() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "receive_directory must be absolute",
        ));
    }
    if state.lifecycle.endpoint.read().await.is_some() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "network runtime is already configured",
        ));
    }

    let identity = Arc::new(DeviceIdentity::from_private_keys(
        command.device_id,
        identity_private_key,
        e2e_private_key,
    ));
    // TCP and UDP intentionally advertise the same numeric port, but UDP port
    // 0 allocation can race with another runtime's TCP listener when tests or
    // multiple local runtimes start concurrently. If the caller requested an
    // ephemeral port, discard the colliding UDP socket and select another
    // paired port; an explicit port remains fail-closed.
    const EPHEMERAL_BIND_ATTEMPTS: usize = 8;
    let bind_attempts = if listen_address.port() == 0 {
        EPHEMERAL_BIND_ATTEMPTS
    } else {
        1
    };
    let mut last_tcp_bind_error = None;
    let (path_manager, socket, bound_address, tcp_listener) = {
        let mut selected = None;
        for _ in 0..bind_attempts {
            let path_manager = Arc::new(PathManager::new());
            let (socket, bound_address) = bind_and_gather_candidates(listen_address, &path_manager)
                .await
                .map_err(|error| protocol_error(NetworkErrorCode::QuicError, error.to_string()))?;
            let tcp_socket = match std::net::TcpListener::bind(bound_address) {
                Ok(socket) => socket,
                Err(error) if listen_address.port() == 0 => {
                    last_tcp_bind_error = Some(error);
                    drop(socket);
                    continue;
                }
                Err(error) => {
                    return Err(protocol_error(
                        NetworkErrorCode::IoError,
                        format!("failed to bind TCP fallback listener: {error}"),
                    ));
                }
            };
            tcp_socket
                .set_nonblocking(true)
                .map_err(|error| protocol_error(NetworkErrorCode::IoError, error.to_string()))?;
            let tcp_listener = TcpListener::from_std(tcp_socket).map_err(|error| {
                protocol_error(
                    NetworkErrorCode::IoError,
                    format!("failed to configure TCP fallback listener: {error}"),
                )
            })?;
            selected = Some((path_manager, socket, bound_address, tcp_listener));
            break;
        }
        selected.ok_or_else(|| {
            protocol_error(
                NetworkErrorCode::IoError,
                format!(
                    "failed to bind paired ephemeral TCP/UDP listeners after {bind_attempts} attempts: {}",
                    last_tcp_bind_error
                        .map(|error| error.to_string())
                        .unwrap_or_else(|| "unknown bind error".into())
                ),
            )
        })?
    };
    path_manager
        .set_generation(monotonic_candidate_generation())
        .await;
    let manager = QuicEndpointManager::from_bound_socket(socket, Arc::clone(&path_manager))
        .map_err(|error| protocol_error(NetworkErrorCode::QuicError, error.to_string()))?;
    let endpoint = manager.endpoint;
    state
        .lifecycle
        .bound_port
        .store(bound_address.port(), Ordering::Release);
    *state.lifecycle.identity.write().await = Some(identity);
    *state.lifecycle.receive_directory.write().await = Some(receive_directory);
    *state.local_path_manager.write().await = Some(path_manager);
    *state.lifecycle.endpoint.write().await = Some(endpoint.clone());
    tracing::info!(%bound_address, "native UDP socket is shared by candidate discovery and QUIC");
    let task_id = state
        .task_supervisor
        .spawn_runtime(
            "quic-accept",
            InboundConnectionAcceptor::accept_connections(endpoint, Arc::clone(&state)),
        )
        .ok_or_else(|| {
            protocol_error(NetworkErrorCode::Cancelled, "network runtime is stopping")
        })?;
    {
        // 作用域限定 MutexGuard 生命周期，避免跨 await 持有非 Send 的 guard。
        let mut accept_task = state.lifecycle.accept_task.lock().map_err(|_| {
            protocol_error(NetworkErrorCode::QuicError, "accept task lock poisoned")
        })?;
        *accept_task = Some(task_id);
    }
    let tcp_task_id = state
        .task_supervisor
        .spawn_runtime(
            "tcp-accept",
            InboundConnectionAcceptor::accept_tcp_connections(tcp_listener, Arc::clone(&state)),
        )
        .ok_or_else(|| {
            protocol_error(NetworkErrorCode::Cancelled, "network runtime is stopping")
        })?;
    {
        let mut tcp_accept_task = state.lifecycle.tcp_accept_task.lock().map_err(|_| {
            protocol_error(NetworkErrorCode::IoError, "TCP accept task lock poisoned")
        })?;
        *tcp_accept_task = Some(tcp_task_id);
    }
    // transport-network v2：运行时配置完成（identity + 本地候选已就绪）后初始化本地
    // Discovery 生命周期（新 runtime_epoch + revision=1）。V2 upload_discovery /
    // peer_presence 已随 Step 11 删除。
    crate::discovery::begin_epoch(&state).await;
    Ok(())
}

/// Binds exactly one native UDP socket, gathers candidates, and returns that
/// same socket for Quinn to own. Optional STUN discovery is native-only and is
/// enabled with `SSH_MOBILE_STUN_SERVERS=host:port,host:port`; no client
/// protocol field is needed for deployments that do not configure STUN.
async fn bind_and_gather_candidates(
    listen_address: SocketAddr,
    path_manager: &PathManager,
) -> Result<(std::net::UdpSocket, SocketAddr), Box<dyn std::error::Error + Send + Sync>> {
    let socket = std::net::UdpSocket::bind(listen_address)?;
    socket.set_nonblocking(true)?;
    let bound_address = socket.local_addr()?;
    let socket = tokio::net::UdpSocket::from_std(socket)?;

    path_manager
        .add_candidates(network_nat::discover_candidates(bound_address.port()).await)
        .await;
    for stun_server in configured_stun_servers() {
        if let Some(candidate) = timeout(
            STUN_PROBE_TIMEOUT,
            network_nat::query_stun(&socket, stun_server),
        )
        .await
        .ok()
        .flatten()
        {
            path_manager.add_candidates(vec![candidate]).await;
        }
    }

    Ok((socket.into_std()?, bound_address))
}

fn configured_stun_servers() -> Vec<SocketAddr> {
    std::env::var(STUN_SERVERS_ENV)
        .ok()
        .map(|value| parse_stun_servers(&value))
        .unwrap_or_default()
}

pub(crate) fn parse_stun_servers(value: &str) -> Vec<SocketAddr> {
    value
        .split(',')
        .filter_map(|entry| {
            let entry = entry.trim();
            if entry.is_empty() {
                None
            } else {
                match entry.parse() {
                    Ok(server) => Some(server),
                    Err(error) => {
                        tracing::debug!(%entry, %error, "ignoring invalid STUN server");
                        None
                    }
                }
            }
        })
        .take(8)
        .collect()
}
