use std::sync::Arc;

use network_protocol::{
    NetworkError as ProtocolError, NetworkErrorCode, SshStreamCloseCommand, SshStreamDataCommand,
    SshStreamOpenCommand, StreamHandle,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::events::protocol_error_with_peer;
use crate::runtime::RuntimeState;

use super::session::{
    close_stream, close_stream_with_opener, local_stream_opener_peer_id, open_stream,
    receive_stream_with_opener, send_stream, send_stream_with_opener,
};
use super::{
    validate_peer, StreamConsumer, StreamOpener, MAX_SERVICE_BYTES, STREAM_LOCAL_HOST,
    STREAM_SOCKET_CHUNK_BYTES,
};

/// The SSH Server Service (design §21 option B): bridges a native byte stream
/// whose service hint is `ssh` to a local TCP sshd socket. Zero SSH protocol
/// code; the bridge just pumps bytes both ways.
pub(crate) struct SshGatewayAdapter;

impl SshGatewayAdapter {
    pub(crate) fn spawn_ssh_gateway(
        state: Arc<RuntimeState>,
        peer_id: String,
        opener: StreamOpener,
        stream_id: u16,
    ) {
        let supervisor = Arc::clone(&state.task_supervisor);
        let _ = supervisor.spawn_runtime("ssh-gateway", async move {
            let gateway_port = state
                .stream_gateway_port
                .load(std::sync::atomic::Ordering::Acquire);
            let address = format!("{STREAM_LOCAL_HOST}:{gateway_port}");
            let socket = match TcpStream::connect(address.as_str()).await {
                Ok(socket) => socket,
                Err(error) => {
                    tracing::warn!(
                        peer_id = %peer_id,
                        stream_id,
                        %error,
                        "SSH gateway could not connect to local sshd"
                    );
                    let _ = close_stream_with_opener(&state, &peer_id, opener, stream_id).await;
                    return;
                }
            };
            let (mut read_half, mut write_half) = socket.into_split();

            // socket -> native stream
            let socket_to_stream = tokio::spawn({
                let state = Arc::clone(&state);
                let peer_id = peer_id.clone();
                async move {
                    let mut buf = vec![0u8; STREAM_SOCKET_CHUNK_BYTES];
                    loop {
                        match read_half.read(&mut buf).await {
                            Ok(0) | Err(_) => break,
                            Ok(n) => {
                                if send_stream_with_opener(
                                    &state,
                                    &peer_id,
                                    opener,
                                    stream_id,
                                    &buf[..n],
                                )
                                .await
                                .is_err()
                                {
                                    break;
                                }
                            }
                        }
                    }
                    let _ = close_stream_with_opener(&state, &peer_id, opener, stream_id).await;
                }
            });

            // native stream -> socket
            let stream_to_socket = tokio::spawn({
                let state = Arc::clone(&state);
                let peer_id = peer_id.clone();
                async move {
                    let mut buf = vec![0u8; STREAM_SOCKET_CHUNK_BYTES];
                    loop {
                        match receive_stream_with_opener(
                            &state, &peer_id, opener, stream_id, &mut buf,
                        )
                        .await
                        {
                            Ok(0) | Err(_) => break,
                            Ok(n) => {
                                if write_half.write_all(&buf[..n]).await.is_err() {
                                    break;
                                }
                            }
                        }
                    }
                    let _ = write_half.shutdown().await;
                }
            });

            let _ = tokio::join!(socket_to_stream, stream_to_socket);
            let _ = close_stream_with_opener(&state, &peer_id, opener, stream_id).await;
        });
    }

    // ---------------------------------------------------------------------------
    // FFI command handlers
    // ---------------------------------------------------------------------------

    pub(crate) fn parse_stream_handle(
        handle: Option<StreamHandle>,
        peer_id: &str,
        operation: &str,
    ) -> Result<(StreamHandle, u16), ProtocolError> {
        let handle = handle.ok_or_else(|| {
            protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "handle is required",
                operation,
                peer_id,
            )
        })?;
        if !validate_peer(&handle.opener_device_id) {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "handle.opener_device_id must contain 1-128 characters",
                operation,
                peer_id,
            ));
        }
        let stream_id = u16::try_from(handle.stream_id).map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "handle.stream_id must be in 1..=65535",
                operation,
                peer_id,
            )
        })?;
        if stream_id == 0 {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "handle.stream_id must be non-zero",
                operation,
                peer_id,
            ));
        }
        Ok((handle, stream_id))
    }

    pub(crate) async fn handle_ssh_stream_open(
        state: Arc<RuntimeState>,
        command: SshStreamOpenCommand,
    ) -> Result<(), ProtocolError> {
        if !validate_peer(&command.peer_id) {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "peer_id must contain 1-128 characters",
                "ssh_stream_open",
                &command.peer_id,
            ));
        }
        if command.service.is_empty() || command.service.len() > MAX_SERVICE_BYTES {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "service must contain 1-128 characters",
                "ssh_stream_open",
                &command.peer_id,
            ));
        }
        let (handle, stream_id) =
            Self::parse_stream_handle(command.handle, &command.peer_id, "ssh_stream_open")?;
        let local_opener_device_id = local_stream_opener_peer_id(&state)
            .await
            .map_err(|error| error.into_protocol(&command.peer_id, "ssh_stream_open"))?;
        if handle.opener_device_id != local_opener_device_id {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "ssh stream open handle must identify the local opener",
                "ssh_stream_open",
                &command.peer_id,
            ));
        }
        open_stream(
            &state,
            &command.peer_id,
            stream_id,
            &command.service,
            StreamConsumer::Event,
        )
        .await
        .map_err(|error| error.into_protocol(&command.peer_id, "ssh_stream_open"))
    }

    pub(crate) async fn handle_ssh_stream_data(
        state: Arc<RuntimeState>,
        command: SshStreamDataCommand,
    ) -> Result<(), ProtocolError> {
        if !validate_peer(&command.peer_id) {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "peer_id must contain 1-128 characters",
                "ssh_stream_data",
                &command.peer_id,
            ));
        }
        let (handle, _) =
            Self::parse_stream_handle(command.handle, &command.peer_id, "ssh_stream_data")?;
        send_stream(&state, &command.peer_id, &handle, &command.data)
            .await
            .map_err(|error| error.into_protocol(&command.peer_id, "ssh_stream_data"))
    }

    pub(crate) async fn handle_ssh_stream_close(
        state: Arc<RuntimeState>,
        command: SshStreamCloseCommand,
    ) -> Result<(), ProtocolError> {
        if !validate_peer(&command.peer_id) {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "peer_id must contain 1-128 characters",
                "ssh_stream_close",
                &command.peer_id,
            ));
        }
        let (handle, _) =
            Self::parse_stream_handle(command.handle, &command.peer_id, "ssh_stream_close")?;
        close_stream(&state, &command.peer_id, &handle)
            .await
            .map_err(|error| error.into_protocol(&command.peer_id, "ssh_stream_close"))
    }
}

pub(crate) fn spawn_ssh_gateway(
    state: Arc<RuntimeState>,
    peer_id: String,
    opener: StreamOpener,
    stream_id: u16,
) {
    SshGatewayAdapter::spawn_ssh_gateway(state, peer_id, opener, stream_id);
}

pub(crate) async fn handle_ssh_stream_open(
    state: Arc<RuntimeState>,
    command: SshStreamOpenCommand,
) -> Result<(), ProtocolError> {
    SshGatewayAdapter::handle_ssh_stream_open(state, command).await
}

pub(crate) async fn handle_ssh_stream_data(
    state: Arc<RuntimeState>,
    command: SshStreamDataCommand,
) -> Result<(), ProtocolError> {
    SshGatewayAdapter::handle_ssh_stream_data(state, command).await
}

pub(crate) async fn handle_ssh_stream_close(
    state: Arc<RuntimeState>,
    command: SshStreamCloseCommand,
) -> Result<(), ProtocolError> {
    SshGatewayAdapter::handle_ssh_stream_close(state, command).await
}
