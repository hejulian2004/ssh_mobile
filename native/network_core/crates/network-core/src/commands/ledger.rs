use std::collections::{HashSet, VecDeque};
use std::sync::{Arc, Mutex};

use network_protocol::{
    network_command, NetworkCommand, NetworkError as ProtocolError, NetworkErrorCode,
    NETWORK_PROTOCOL_VERSION,
};

use crate::errors::CoreNetworkError;
use crate::events::{emit_command_result, protocol_error};
use crate::peer;
use crate::relay;
use crate::runtime::RuntimeState;
use crate::transfer;

use super::connect::{
    decode_communication_class, handle_network_environment_changed, start_configure_relay,
    start_connect_peer,
};
use super::peer_lifecycle::{
    close_peer_relay_path, emit_peer_diagnostics, remove_peer_v2, validate_e2ee_policy,
};

pub(crate) const MAX_COMPLETED_COMMANDS: usize = 4096;

/// Tracks command ids at the runtime boundary. A command id is claimed before
/// dispatch and its result is emitted at most once for the lifetime of this
/// runtime. The set is deliberately bounded; a runtime restart starts a fresh
/// correlation domain instead of allowing unbounded bookkeeping growth.
pub(crate) struct CommandResultLedger {
    state: Mutex<CommandResultLedgerState>,
}

#[derive(Default)]
struct CommandResultLedgerState {
    pending: HashSet<String>,
    completed: HashSet<String>,
    completed_order: VecDeque<String>,
}

impl CommandResultLedger {
    pub(super) fn new() -> Self {
        Self {
            state: Mutex::new(CommandResultLedgerState::default()),
        }
    }

    pub(super) fn claim(&self, command_id: &str) -> Result<bool, CoreNetworkError> {
        let mut state = self.state.lock().expect("command result ledger lock");
        if state.pending.contains(command_id) || state.completed.contains(command_id) {
            return Ok(false);
        }
        if state.pending.len() >= crate::runtime::COMMAND_MAILBOX_CAPACITY {
            return Err(CoreNetworkError::ResourceLimit("pending command results"));
        }
        state.pending.insert(command_id.to_string());
        Ok(true)
    }

    pub(super) fn complete(&self, command_id: &str) {
        let mut state = self.state.lock().expect("command result ledger lock");
        if !state.pending.remove(command_id) {
            return;
        }
        if state.completed.insert(command_id.to_string()) {
            state.completed_order.push_back(command_id.to_string());
        }
        while state.completed_order.len() > MAX_COMPLETED_COMMANDS {
            if let Some(expired) = state.completed_order.pop_front() {
                state.completed.remove(&expired);
            }
        }
    }
}

/// 运行唯一命令 worker，并为每个命令发布一个终态结果。
pub(crate) async fn run_command_worker(
    mut commands: tokio::sync::mpsc::Receiver<NetworkCommand>,
    state: Arc<RuntimeState>,
) {
    tracing::info!("Network runtime worker started");
    let result_ledger = CommandResultLedger::new();
    while let Some(command) = commands.recv().await {
        let command_id = command.command_id.clone();
        let command_peer_id = command_peer_id(&command);
        match result_ledger.claim(&command_id) {
            Ok(true) => {}
            // A duplicate envelope is still given a correlated terminal
            // result.  Distinct ConnectPeer commands use distinct ids and
            // join the same supervisor generation below; only a repeated
            // envelope id is rejected here.
            Ok(false) => {
                if let Err(error) = emit_command_result(
                    &state.event_tx,
                    command_id,
                    command_peer_id,
                    Err(protocol_error(
                        NetworkErrorCode::InvalidArgument,
                        "command_id has already been completed",
                    )),
                )
                .await
                {
                    tracing::error!(?error, "command result lane closed");
                    break;
                }
                continue;
            }
            Err(error) => {
                if let Err(send_error) = emit_command_result(
                    &state.event_tx,
                    command_id,
                    command_peer_id,
                    Err(protocol_error(NetworkErrorCode::IoError, error.to_string())),
                )
                .await
                {
                    tracing::error!(?send_error, "command result lane closed");
                    break;
                }
                continue;
            }
        }
        let result = dispatch_command(command, Arc::clone(&state)).await;
        if let Err(error) =
            emit_command_result(&state.event_tx, command_id.clone(), command_peer_id, result).await
        {
            tracing::error!(?error, "command result lane closed");
            break;
        }
        result_ledger.complete(&command_id);
    }
    tracing::info!("Network runtime worker shut down");
}

/// Extract the public peer scope before the command is moved into its
/// subsystem.  `CommandResult` carries this scope so SDK trackers can reject
/// a terminal result for the wrong peer without exposing native handles.
pub(crate) fn command_peer_id(command: &NetworkCommand) -> Option<String> {
    match command.payload.as_ref() {
        Some(network_command::Payload::ConnectPeer(command)) => Some(command.peer_id.clone()),
        Some(network_command::Payload::SendFile(command)) => Some(command.peer_id.clone()),
        Some(network_command::Payload::ConfigureRuntime(_)) => None,
        Some(network_command::Payload::UpsertPeer(command)) => Some(command.peer_id.clone()),
        Some(network_command::Payload::RespondIncomingTransfer(_)) => None,
        Some(network_command::Payload::ConfigureRelay(_)) => None,
        Some(network_command::Payload::DisconnectPeer(command)) => Some(command.peer_id.clone()),
        Some(network_command::Payload::DisconnectRelay(_)) => None,
        Some(network_command::Payload::StartRealtimeSession(command)) => {
            Some(command.peer_id.clone())
        }
        Some(network_command::Payload::StopRealtimeSession(_)) => None,
        Some(network_command::Payload::SendRealtimeSignal(command)) => {
            Some(command.peer_id.clone())
        }
        Some(network_command::Payload::ClaimIncomingRealtimeOffer(command)) => {
            Some(command.peer_id.clone())
        }
        Some(network_command::Payload::RejectIncomingRealtimeOffer(command)) => {
            Some(command.peer_id.clone())
        }
        Some(network_command::Payload::DiscardIncomingRealtimeOffer(command)) => {
            Some(command.peer_id.clone())
        }
        Some(network_command::Payload::UpsertPeerV2(command)) => {
            command.config.as_ref().map(|config| config.peer_id.clone())
        }
        Some(network_command::Payload::RemovePeer(command)) => Some(command.peer_id.clone()),
        Some(network_command::Payload::SendMessageV2(command)) => Some(command.peer_id.clone()),
        Some(network_command::Payload::Transfer(command)) => Some(command.peer_id.clone()),
        Some(network_command::Payload::PeerDiagnostics(command)) => Some(command.peer_id.clone()),
        Some(network_command::Payload::NetworkEnvironmentChanged(_)) => None,
        Some(network_command::Payload::CancelTransfer(_)) => None,
        Some(network_command::Payload::SendMessage(command)) => Some(command.peer_id.clone()),
        Some(network_command::Payload::AcknowledgeMessage(command)) => {
            Some(command.peer_id.clone())
        }
        Some(network_command::Payload::SshStreamOpen(command)) => Some(command.peer_id.clone()),
        Some(network_command::Payload::SshStreamData(command)) => Some(command.peer_id.clone()),
        Some(network_command::Payload::SshStreamClose(command)) => Some(command.peer_id.clone()),
        None => None,
    }
}

/// 校验 V2 信封，并将载荷路由到所属子系统。
pub(crate) async fn dispatch_command(
    command: NetworkCommand,
    state: Arc<RuntimeState>,
) -> Result<(), ProtocolError> {
    if command.protocol_version != NETWORK_PROTOCOL_VERSION {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            format!(
                "unsupported network protocol version {}",
                command.protocol_version
            ),
        ));
    }
    if command.command_id.is_empty() || command.command_id.len() > 128 {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "command_id must contain 1-128 characters",
        ));
    }
    // Command payloads have independent, potentially substantial async
    // lifecycles (notably native WebRTC I/O). Heap-bound the selected payload
    // future so command-worker stack use stays bounded as domains evolve.
    Box::pin(dispatch_command_payload(command, state)).await
}

async fn dispatch_command_payload(
    command: NetworkCommand,
    state: Arc<RuntimeState>,
) -> Result<(), ProtocolError> {
    let command_id = command.command_id.clone();
    match command.payload {
        Some(network_command::Payload::ConfigureRuntime(config)) => {
            peer::configure_runtime(state, config).await
        }
        Some(network_command::Payload::UpsertPeer(_)) => Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "legacy peer registration is not supported",
        )),
        Some(network_command::Payload::UpsertPeerV2(command)) => {
            let config = command.config.ok_or_else(|| {
                protocol_error(NetworkErrorCode::InvalidArgument, "peer config is required")
            })?;
            let e2ee_policy =
                network_protocol::E2eePolicy::try_from(config.e2ee_policy).map_err(|_| {
                    protocol_error(NetworkErrorCode::InvalidArgument, "unknown E2EE policy")
                })?;
            if !config.allow_direct && config.allow_relay {
                return Err(protocol_error(
                    NetworkErrorCode::InvalidArgument,
                    "relay-only peers are not supported",
                ));
            }
            if !config.allow_direct && !config.allow_relay {
                return Err(protocol_error(
                    NetworkErrorCode::InvalidArgument,
                    "peer must authorize at least one route",
                ));
            }
            let peer_id = config.peer_id.clone();
            let previous = state
                .peer_route_authorizations
                .read()
                .await
                .get(&peer_id)
                .copied();
            let result = peer::upsert_peer_with_policy(
                &state,
                network_protocol::UpsertPeerCommand {
                    peer_id: config.peer_id,
                    endpoint_address: config.endpoint_address,
                    identity_public_key: config.identity_public_key,
                    e2e_public_key: config.e2e_public_key,
                },
                e2ee_policy,
            )
            .await;
            if result.is_ok() {
                state.peer_route_authorizations.write().await.insert(
                    peer_id.clone(),
                    crate::runtime::PeerRouteAuthorization {
                        direct: config.allow_direct,
                        relay: config.allow_relay,
                    },
                );
                if previous.is_some_and(|authorization| authorization.relay) && !config.allow_relay
                {
                    // Revoking Relay authorization must retire a live Relay
                    // carrier, but it must not tear down an independent
                    // Direct path that remains authorized.
                    close_peer_relay_path(&state, &peer_id).await;
                }
            }
            result
        }
        Some(network_command::Payload::ConnectPeer(connect)) => {
            let class = decode_communication_class(connect.communication_class);
            start_connect_peer(state, command_id, connect.peer_id, class).await
        }
        Some(network_command::Payload::SendFile(_))
        | Some(network_command::Payload::CancelTransfer(_))
        | Some(network_command::Payload::RespondIncomingTransfer(_)) => {
            transfer::dispatch_transfer_command(state, command).await
        }
        Some(network_command::Payload::SendMessage(message)) => {
            crate::channel::start_send_message(state, message).await
        }
        Some(network_command::Payload::AcknowledgeMessage(ack)) => {
            crate::channel::acknowledge_message(&state, ack).await
        }
        Some(network_command::Payload::StartRealtimeSession(start)) => {
            crate::realtime::start_session(state, start).await
        }
        Some(network_command::Payload::StopRealtimeSession(stop)) => {
            crate::realtime::stop_session(&state, stop).await
        }
        Some(network_command::Payload::SendRealtimeSignal(signal)) => {
            crate::realtime::send_signal_command(&state, signal).await
        }
        Some(network_command::Payload::ClaimIncomingRealtimeOffer(claim)) => {
            crate::realtime::claim_incoming_offer(state, claim).await
        }
        Some(network_command::Payload::RejectIncomingRealtimeOffer(reject)) => {
            crate::realtime::reject_incoming_offer(&state, reject).await
        }
        Some(network_command::Payload::DiscardIncomingRealtimeOffer(discard)) => {
            crate::realtime::discard_incoming_offer(&state, discard).await
        }
        Some(network_command::Payload::ConfigureRelay(config)) => {
            start_configure_relay(state, config).await
        }
        Some(network_command::Payload::DisconnectPeer(disconnect)) => {
            peer::disconnect_peer(&state, disconnect.peer_id).await
        }
        Some(network_command::Payload::RemovePeer(remove)) => {
            remove_peer_v2(&state, remove.peer_id).await
        }
        Some(network_command::Payload::SendMessageV2(message)) => {
            validate_e2ee_policy(message.e2ee_policy)?;
            crate::channel::start_send_message(
                state,
                network_protocol::SendMessageCommand {
                    peer_id: message.peer_id,
                    channel_id: message.channel_id,
                    payload: message.payload,
                    policy: message.policy,
                },
            )
            .await
        }
        Some(network_command::Payload::Transfer(transfer)) => {
            if transfer.peer_id.is_empty() || transfer.transfer_id.is_empty() {
                return Err(protocol_error(
                    NetworkErrorCode::InvalidArgument,
                    "peer_id and transfer_id are required",
                ));
            }
            transfer::dispatch_transfer_command(
                state,
                NetworkCommand {
                    command_id,
                    protocol_version: NETWORK_PROTOCOL_VERSION,
                    payload: Some(network_command::Payload::SendFile(
                        network_protocol::SendFileCommand {
                            transfer_id: transfer.transfer_id,
                            peer_id: transfer.peer_id,
                            file_path: transfer.file_path,
                        },
                    )),
                },
            )
            .await
        }
        Some(network_command::Payload::PeerDiagnostics(diagnostics)) => {
            emit_peer_diagnostics(&state, diagnostics.peer_id).await
        }
        Some(network_command::Payload::NetworkEnvironmentChanged(environment)) => {
            handle_network_environment_changed(&state, &environment).await?;
            crate::events::emit_network_environment_changed(&state.event_tx, environment);
            Ok(())
        }
        Some(network_command::Payload::DisconnectRelay(_)) => relay::disconnect_relay(&state).await,
        Some(network_command::Payload::SshStreamOpen(open)) => {
            crate::stream::handle_ssh_stream_open(state, open).await
        }
        Some(network_command::Payload::SshStreamData(data)) => {
            crate::stream::handle_ssh_stream_data(state, data).await
        }
        Some(network_command::Payload::SshStreamClose(close)) => {
            crate::stream::handle_ssh_stream_close(state, close).await
        }
        None => Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "network command payload is required",
        )),
    }
}
