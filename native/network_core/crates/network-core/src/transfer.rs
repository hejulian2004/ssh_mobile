//! V2 直连文件传输任务分发及类型化完成/失败事件。

use network_protocol::{
    CommunicationClass, NetworkCommand, NetworkError as ProtocolError, NetworkErrorCode,
    RespondIncomingTransferCommand, RouteType, SendFileCommand,
};
use network_quic::{
    read_file_completion, read_file_decision, write_file_completion, write_file_decision,
    write_file_offer,
};
use network_transfer::{
    build_file_manifest, existing_completed_file, existing_partial_offset,
    stream_receive_file_cancellable, stream_send_file_cancellable, FileManifest, ResumableTransfer,
    TransferFailureReason, TransferManager, NETWORK_TRANSFER_PROTOCOL_VERSION,
};
use quinn::{Connection, RecvStream, SendStream};
use std::collections::{hash_map::Entry, HashMap};
use std::error::Error;
use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::AsyncReadExt;
use tokio::sync::{
    mpsc::{channel, Receiver},
    oneshot, RwLock,
};

use crate::channel::select_business_path_lease;
use crate::connect::{PathLease, CAPABILITY_RELIABLE_STREAM};
use crate::connection::RouteTransport;
use crate::delivery::{is_valid_peer_id, BusinessRecoveryError};
use crate::errors::CoreNetworkError;
use crate::events::{
    emit_incoming_offer, emit_transfer_completed, emit_transfer_error,
    emit_transfer_progress_for_peer, protocol_error, protocol_error_with_peer,
};
use crate::runtime::{
    EventSender, RelayTransferPort, RuntimeState, TransferRelayPort, INCOMING_APPROVAL_TIMEOUT,
    MAX_PENDING_INCOMING_TRANSFERS, TRANSFER_COMPLETION_TIMEOUT,
};

/// Runtime-owned Transfer domain state. The manager is kept behind this
/// boundary so RuntimeState does not expose a second flat business owner.
pub(crate) struct TransferDomainState {
    pub(crate) manager: TransferManager,
    pub(crate) incoming_decisions: RwLock<HashMap<String, oneshot::Sender<bool>>>,
}

impl TransferDomainState {
    pub(crate) fn new() -> Self {
        Self {
            manager: TransferManager::new(),
            incoming_decisions: RwLock::new(HashMap::new()),
        }
    }
}

/// Frozen logical transfer identity. ConnectionSession and route handles are
/// intentionally absent; a path loss changes only the current attempt.
#[allow(dead_code)]
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct TransferIdentity {
    pub peer_id: String,
    pub transfer_id: String,
}

impl TransferIdentity {
    #[allow(dead_code)]
    pub fn new(
        peer_id: impl Into<String>,
        transfer_id: impl Into<String>,
    ) -> Result<Self, &'static str> {
        let identity = Self {
            peer_id: peer_id.into(),
            transfer_id: transfer_id.into(),
        };
        if identity.peer_id.is_empty() || identity.transfer_id.is_empty() {
            return Err("peer_id and transfer_id are required");
        }
        Ok(identity)
    }
}

/// Progress is advisory data, but it is emitted once per transfer chunk. Keep
/// the queue bounded so a stalled event consumer cannot retain an entire file
/// transfer in memory; the producer naturally backpressures on this lane.
const TRANSFER_PROGRESS_QUEUE_CAPACITY: usize = 64;

/// 当前一次传输尝试使用的 Route handle。它只存在于 dispatcher/worker，
/// 不会进入 network-transfer 的 TransferSession。
#[derive(Clone)]
enum TransferRoute {
    QuicDirect(Connection),
    Relay,
}

/// 传输的 Route 适配边界。TransferManager 只管理业务会话和偏移，
/// 当前 QUIC/Relay handle 的选择集中在这里。
#[derive(Clone)]
struct TransferDispatcher {
    state: Arc<RuntimeState>,
}

impl TransferDispatcher {
    fn new(state: Arc<RuntimeState>) -> Self {
        Self { state }
    }

    async fn select_attempt(
        &self,
        identity: &TransferIdentity,
    ) -> Result<(TransferRoute, PathLease), ProtocolError> {
        ensure_business_path(
            &self.state,
            &identity.peer_id,
            &identity.transfer_id,
            CommunicationClass::BulkTransfer,
            CAPABILITY_RELIABLE_STREAM,
        )
        .await
        .map_err(|error| {
            protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                error.to_string(),
                "send",
                &identity.peer_id,
            )
        })?;
        let lease =
            select_business_path_lease(&self.state, &identity.peer_id, CAPABILITY_RELIABLE_STREAM)
                .await
                .map_err(|error| {
                    protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        error.to_string(),
                        "send",
                        &identity.peer_id,
                    )
                })?;
        if !lease
            .profile()
            .supports(crate::connection::ConnectionCapability::ReliableStream)
        {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "selected path does not support file transfer",
                "send",
                &identity.peer_id,
            ));
        }
        match lease.profile().transport() {
            RouteTransport::Quic => {
                let connection = lease
                    .connection()
                    .filter(|_| lease.is_active())
                    .ok_or_else(|| {
                        protocol_error_with_peer(
                            NetworkErrorCode::NoRoute,
                            "selected QUIC path has no active Connection",
                            "send",
                            &identity.peer_id,
                        )
                    })?;
                if !lease.is_active() {
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "selected QUIC path was lost before transfer start",
                        "send",
                        &identity.peer_id,
                    ));
                }
                Ok((TransferRoute::QuicDirect(connection), lease))
            }
            RouteTransport::WebSocket
                if lease.profile().topology() == crate::connection::RouteTopology::Relay =>
            {
                let usable = match lease.relay_data().filter(|_| lease.is_active()) {
                    Some(data) => data.is_usable().await,
                    None => false,
                };
                if usable && lease.is_active() {
                    Ok((TransferRoute::Relay, lease))
                } else {
                    Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "selected Relay path has no active data reservation",
                        "send",
                        &identity.peer_id,
                    ))
                }
            }
            _ => Err(protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "selected path cannot carry file transfer",
                "send",
                &identity.peer_id,
            )),
        }
    }

    async fn dispatch_outgoing(
        &self,
        route: TransferRoute,
        lease: PathLease,
        transfer: ResumableTransfer,
    ) -> Result<(), ProtocolError> {
        match route {
            TransferRoute::QuicDirect(connection) => {
                let session_key = transfer.session_id.clone();
                if self
                    .state
                    .task_supervisor
                    .spawn_session(
                        session_key,
                        "file-send",
                        send_file(connection, transfer, Arc::clone(&self.state), lease),
                    )
                    .is_none()
                {
                    return Err(protocol_error(
                        NetworkErrorCode::Cancelled,
                        "network runtime is stopping",
                    ));
                }
                Ok(())
            }
            TransferRoute::Relay => {
                let peer = self
                    .state
                    .peers
                    .read()
                    .await
                    .get(&transfer.peer_id)
                    .cloned()
                    .ok_or_else(|| {
                        protocol_error_with_peer(
                            NetworkErrorCode::NoRoute,
                            "peer is not registered",
                            "send",
                            &transfer.peer_id,
                        )
                    })?;
                let session_key = transfer.session_id.clone();
                let state = Arc::clone(&self.state);
                if self
                    .state
                    .task_supervisor
                    .spawn_session(session_key, "relay-file-send", async move {
                        state.dispatch_relay_transfer(peer, transfer, lease).await;
                    })
                    .is_none()
                {
                    return Err(protocol_error(
                        NetworkErrorCode::Cancelled,
                        "network runtime is stopping",
                    ));
                }
                Ok(())
            }
        }
    }
}

#[derive(Debug)]
struct TransferAttemptError {
    reason: TransferFailureReason,
    recovery_error: BusinessRecoveryError,
    terminal: bool,
    message: &'static str,
}

impl fmt::Display for TransferAttemptError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.message)
    }
}

impl Error for TransferAttemptError {}

impl TransferAttemptError {
    fn stale_attempt(reason: TransferFailureReason) -> Self {
        Self {
            reason,
            recovery_error: BusinessRecoveryError::RecoverableTransportLoss,
            terminal: false,
            message: "transfer attempt no longer owns the business operation",
        }
    }

    fn recovery_error(&self) -> BusinessRecoveryError {
        self.recovery_error
    }
}

#[path = "transfer_operations/mod.rs"]
mod transfer_operations;

pub(super) use transfer_operations::*;

#[cfg(test)]
#[path = "tests/transfer.rs"]
mod tests;
