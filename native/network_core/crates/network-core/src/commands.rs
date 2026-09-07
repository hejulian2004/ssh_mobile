//! Network Protocol V2 运行时的命令校验、确认与任务分发。

use std::collections::{HashSet, VecDeque};
use std::sync::{Arc, Mutex};

use crate::events::{
    emit_command_result, emit_peer_lifecycle, emit_relay_state, protocol_error,
    protocol_error_with_peer,
};
use crate::peer;
use crate::relay;
use crate::runtime::RuntimeState;
use crate::transfer;
use crate::{
    connect::{
        ConnectivityAttemptCoordinator, IntentGeneration, PeerId, PeerState, PeerSupervisor,
        CAPABILITY_RELIABLE_MESSAGE, DIRECT_CONNECT_WINDOW,
    },
    errors::CoreNetworkError,
};
use network_protocol::{
    network_command, CommunicationClass, NetworkCommand, NetworkError as ProtocolError,
    NetworkErrorCode, RelayConnectionState, NETWORK_PROTOCOL_VERSION,
};

const MAX_COMPLETED_COMMANDS: usize = 4096;

/// Tracks command ids at the runtime boundary. A command id is claimed before
/// dispatch and its result is emitted at most once for the lifetime of this
/// runtime. The set is deliberately bounded; a runtime restart starts a fresh
/// correlation domain instead of allowing unbounded bookkeeping growth.
struct CommandResultLedger {
    state: Mutex<CommandResultLedgerState>,
}

#[derive(Default)]
struct CommandResultLedgerState {
    pending: HashSet<String>,
    completed: HashSet<String>,
    completed_order: VecDeque<String>,
}

impl CommandResultLedger {
    fn new() -> Self {
        Self {
            state: Mutex::new(CommandResultLedgerState::default()),
        }
    }

    fn claim(&self, command_id: &str) -> Result<bool, CoreNetworkError> {
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

    fn complete(&self, command_id: &str) {
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
fn command_peer_id(command: &NetworkCommand) -> Option<String> {
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

fn validate_e2ee_policy(value: i32) -> Result<(), ProtocolError> {
    network_protocol::E2eePolicy::try_from(value)
        .map(|_| ())
        .map_err(|_| protocol_error(NetworkErrorCode::InvalidArgument, "unknown E2EE policy"))
}

async fn remove_peer_v2(state: &RuntimeState, peer_id: String) -> Result<(), ProtocolError> {
    if PeerId::new(&peer_id).is_err() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id must contain 1-128 characters",
        ));
    }
    let supervisor = state
        .peer_supervisors
        .get_or_create(&peer_id)
        .map_err(|error| protocol_error(NetworkErrorCode::Lifecycle, error.to_string()))?;
    supervisor.disconnect();

    // Disconnect the owned ConnectionSession before removing any peer
    // indexes.  `cancel_session_tasks` closes streams/realtime, pauses
    // business work, and joins the session task group; route.close() hard
    // closes the physical carrier itself.
    close_peer_connection(state, &peer_id).await;

    // RemovePeer is an explicit destructive lifecycle boundary, so paused
    // business state must not remain resumable under a deleted peer.
    cancel_peer_transfers(state, &peer_id).await;

    state.relay.relay_path_ready.write().await.remove(&peer_id);
    clear_peer_relay_crypto(state, &peer_id).await;

    state.delivery.close_peer(&peer_id).await;
    close_peer_streams(state, &peer_id).await;
    state.peers.write().await.remove(&peer_id);
    state
        .peer_route_authorizations
        .write()
        .await
        .remove(&peer_id);
    state.trusted_peer_keys.write().await.remove(&peer_id);
    state.remote_candidate_cache.write().await.remove(&peer_id);
    state.ready_session_index.unregister(&peer_id);
    // `disconnect` preserves long-lived maintenance by design. Removal is a
    // stronger owner boundary: stop the supervisor so maintenance is cleared
    // and the registry can evict the exact peer entry.
    supervisor.stop();
    let _ = state.peer_supervisors.remove_if_evictable(&peer_id);
    crate::events::emit_peer_lifecycle(
        &state.event_tx,
        &peer_id,
        PeerState::Offline,
        Some(protocol_error_with_peer(
            NetworkErrorCode::Cancelled,
            "peer removed",
            "remove_peer",
            &peer_id,
        )),
    );
    Ok(())
}

async fn emit_peer_diagnostics(state: &RuntimeState, peer_id: String) -> Result<(), ProtocolError> {
    if PeerId::new(&peer_id).is_err() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id must contain 1-128 characters",
        ));
    }

    let configured = state.peers.read().await.contains_key(&peer_id);
    let supervisor = if configured {
        Some(
            state
                .peer_supervisors
                .get_or_create(&peer_id)
                .map_err(|error| protocol_error(NetworkErrorCode::Lifecycle, error.to_string()))?,
        )
    } else {
        None
    };
    let peer_state = supervisor
        .as_ref()
        .map(|supervisor| supervisor.state())
        .unwrap_or(PeerState::Offline);
    let queued_command_count = supervisor
        .as_ref()
        .is_some_and(|supervisor| supervisor.state() == PeerState::Connecting)
        as u32;
    let ready_path_count = ready_path_count(state, &peer_id).await;
    let active_stream_count =
        if let Some(manager) = state.reliable_streams.read().await.get(&peer_id).cloned() {
            manager.active_count().await
        } else {
            0
        };
    let active_transfer_count = active_transfer_count(state, &peer_id).await;
    let e2ee_policy = state
        .peers
        .read()
        .await
        .get(&peer_id)
        .map(|peer| peer.e2ee_policy as i32)
        .unwrap_or(network_protocol::E2eePolicy::Required as i32);

    crate::events::emit_peer_diagnostics(
        &state.event_tx,
        network_protocol::PeerDiagnostics {
            peer_id,
            state: peer_state as i32,
            e2ee_policy,
            ready_path_count,
            queued_command_count,
            active_stream_count,
            active_transfer_count,
            last_error: None,
        },
    );
    Ok(())
}

/// Close the current transport/session owner for one peer.  This helper is
/// shared by RemovePeer and environment recovery; neither caller leaves an
/// `ActiveRoute`, path handle, or session task group behind.
async fn close_peer_connection(state: &RuntimeState, peer_id: &str) {
    // RuntimeState owns the admitted carrier and its PeerPathManager. This is
    // the hard-close boundary for QUIC/generic physical paths; the registry
    // revoke below closes any remaining indexed borrower path as well.
    state.close_transport_path(peer_id).await;
    if let Ok(peer) = PeerId::new(peer_id) {
        state.ready_paths.revoke_peer(&peer);
    }
    // A hard-closed PeerPathManager cannot publish a fresh path. Remove the
    // manager entry so the next environment generation gets a new owner.
    state.peer_path_managers.write().await.remove(peer_id);
    let session_id = state.connection_sessions.current_session_id(peer_id).await;
    if let Some(session_id) = session_id {
        state.cancel_session_tasks(peer_id, session_id).await;
        state
            .connection_sessions
            .retire_session(peer_id, session_id)
            .await;
    }
    state.ready_session_index.unregister(peer_id);

    state.relay.relay_path_ready.write().await.remove(peer_id);
    clear_peer_relay_crypto(state, peer_id).await;
}

/// Retire only the Relay-owned carrier when a peer loses Relay authorization.
/// Direct trust and a live Direct path are independent state and remain
/// usable after this operation.
async fn close_peer_relay_path(state: &RuntimeState, peer_id: &str) {
    let _ = state.close_relay_path(peer_id, None).await;
    state.relay.relay_path_ready.write().await.remove(peer_id);
    clear_peer_relay_crypto(state, peer_id).await;
}

/// Close and remove every ReliableStream manager owned by the peer.  The
/// manager emits the application-visible closed events before its registry
/// entry is dropped.
async fn close_peer_streams(state: &RuntimeState, peer_id: &str) {
    let manager = state.reliable_streams.read().await.get(peer_id).cloned();
    if let Some(manager) = manager {
        let local_opener_device_id = state
            .lifecycle
            .identity
            .read()
            .await
            .as_ref()
            .map(|identity| identity.device_id.clone())
            .unwrap_or_default();
        manager.close_all(peer_id, &local_opener_device_id).await;
    }
    state.reliable_streams.write().await.remove(peer_id);
}

/// Explicit peer removal cancels every known transfer identity, including
/// Relay offers and waiter-only Relay operations.  The TransferManager remains
/// the business owner; this function only drives its public cancellation API
/// and lets the Relay owner remove its own socket/file state.
async fn cancel_peer_transfers(state: &RuntimeState, peer_id: &str) {
    let mut transfer_ids = state
        .transfer
        .manager
        .pause_peer_transfers(peer_id)
        .await
        .into_iter()
        .collect::<HashSet<_>>();

    transfer_ids.extend(
        state
            .relay
            .pending_incoming
            .read()
            .await
            .values()
            .filter(|pending| pending.sender_id == peer_id)
            .map(|pending| pending.transfer_id.clone()),
    );
    transfer_ids.extend(
        state
            .relay
            .active_incoming
            .lock()
            .await
            .values()
            .filter(|active| active.offer.sender_id == peer_id)
            .map(|active| active.offer.transfer_id.clone()),
    );

    let relay_waiter_ids = state
        .relay
        .acceptances
        .read()
        .await
        .keys()
        .chain(state.relay.completions.read().await.keys())
        .cloned()
        .collect::<Vec<_>>();
    for transfer_id in relay_waiter_ids {
        if state
            .transfer
            .manager
            .snapshot(&transfer_id)
            .await
            .is_some_and(|snapshot| snapshot.peer_id == peer_id)
        {
            transfer_ids.insert(transfer_id);
        }
    }

    for transfer_id in transfer_ids {
        state.transfer.manager.cancel_transfer(&transfer_id).await;
        relay::cancel_transfer(state, &transfer_id).await;
        state
            .transfer
            .incoming_decisions
            .write()
            .await
            .remove(&transfer_id);
    }
}

/// Remove crypto waiters whose owner is the deleted peer.  The maps are
/// session/handshake resources, not durable peer configuration.
async fn clear_peer_relay_crypto(state: &RuntimeState, peer_id: &str) {
    let prefix = format!("{peer_id}/");
    state
        .relay
        .crypto_waiters
        .write()
        .await
        .retain(|key, _| !key.starts_with(&prefix));
    state
        .relay
        .crypto_responders
        .lock()
        .await
        .retain(|key, _| !key.starts_with(&prefix));
    state
        .relay
        .crypto_confirmers
        .lock()
        .await
        .retain(|key, _| !key.starts_with(&prefix));
}

/// The ready-path registry deliberately exposes lease selection, not its
/// internal map. Count paths from the peer-owned path manager and its indexed
/// leases; pre-admission Relay data is not a selectable path.
async fn ready_path_count(state: &RuntimeState, peer_id: &str) -> u32 {
    let manager_path_count = state
        .peer_path_managers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .map(|manager| {
            let manager = manager.lock().expect("peer path manager lock");
            manager.direct_ready().len() as u32 + u32::from(manager.relay_ready().is_some())
        })
        .unwrap_or_default();
    let selected_profile = PeerId::new(peer_id).ok().and_then(|peer| {
        state
            .ready_paths
            .select_compatible_ready_path(&peer, 0)
            .ok()
            .map(|lease| lease.profile())
    });
    let current_profile = state.path_profile(peer_id).await;
    let mut count = manager_path_count.max(u32::from(
        selected_profile.is_some() || current_profile.is_some(),
    ));
    count = count.max(manager_path_count);
    count
}

/// Return the peer-scoped transfer identities visible at this lifecycle
/// boundary.  Relay pending/active and completion waiters are all real
/// TransferManager-owned identities; no synthetic fixed counter is reported.
async fn active_transfer_count(state: &RuntimeState, peer_id: &str) -> u32 {
    let mut transfer_ids = state
        .transfer
        .manager
        .active_ids_for_peer(peer_id)
        .await
        .into_iter()
        .collect::<HashSet<_>>();
    transfer_ids.extend(
        state
            .relay
            .pending_incoming
            .read()
            .await
            .values()
            .filter(|pending| pending.sender_id == peer_id)
            .map(|pending| pending.transfer_id.clone()),
    );
    transfer_ids.extend(
        state
            .relay
            .active_incoming
            .lock()
            .await
            .values()
            .filter(|active| active.offer.sender_id == peer_id)
            .map(|active| active.offer.transfer_id.clone()),
    );

    let waiter_ids = state
        .relay
        .acceptances
        .read()
        .await
        .keys()
        .chain(state.relay.completions.read().await.keys())
        .cloned()
        .collect::<Vec<_>>();
    for transfer_id in waiter_ids {
        if state
            .transfer
            .manager
            .snapshot(&transfer_id)
            .await
            .is_some_and(|snapshot| snapshot.peer_id == peer_id)
        {
            transfer_ids.insert(transfer_id);
        }
    }
    transfer_ids.len().min(u32::MAX as usize) as u32
}

/// Apply an environment transition to the owning lifecycle graph.  Discovery
/// refresh and Direct recovery are independent of healthy Relay/Realtime
/// owners; passive peers never acquire persistent recovery maintenance.
async fn handle_network_environment_changed(
    state: &Arc<RuntimeState>,
    environment: &network_protocol::NetworkEnvironmentChangedCommand,
) -> Result<(), ProtocolError> {
    let _ = crate::discovery::on_network_environment_changed(
        state,
        environment.generation,
        environment.has_connectivity,
    )
    .await;
    // A local interface/NAT change invalidates the remote Stage-A pairing
    // opportunity as well.  The next supervisor generation must resolve or
    // gather fresh candidates instead of reusing this retry snapshot.
    state.remote_candidate_cache.write().await.clear();

    let peer_ids = state.peers.read().await.keys().cloned().collect::<Vec<_>>();
    let mut first_error = None;
    for peer_id in peer_ids {
        let supervisor = state
            .peer_supervisors
            .get_or_create(&peer_id)
            .map_err(|error| core_error(&peer_id, "environment_changed", error))?;
        let maintain = supervisor.maintain_connection();
        state.reset_direct_recovery(&peer_id);
        let has_relay = state.has_ready_relay_path(&peer_id).await;
        let has_direct = state.has_ready_direct_path(&peer_id).await;

        if has_relay {
            // Direct is an optimisation. Retire only the stale Direct slot;
            // the Relay carrier, Session, and Realtime owner remain usable.
            let _ = crate::realtime::preserve_for_environment_reprobe(state, &peer_id).await;
            if has_direct {
                let _ = state.close_direct_path(&peer_id, None).await;
            }
            if maintain && environment.has_connectivity {
                spawn_direct_recovery(Arc::clone(state), peer_id);
            }
            continue;
        }

        if has_direct
            || matches!(
                supervisor.state(),
                PeerState::Online | PeerState::Connecting
            )
        {
            // This invalidates the peer generation while preserving the
            // maintenance bit; explicit recovery below is the only reconnect
            // trigger for a maintained peer.
            supervisor.path_lost();
            close_peer_connection(state, &peer_id).await;
        }
        if maintain && environment.has_connectivity {
            let command_id = format!("environment-reprobe-{}-{peer_id}", environment.generation);
            match state.peer_supervisors.start_connect(
                Arc::clone(state),
                &peer_id,
                command_id,
                CommunicationClass::ReliableMessage,
            ) {
                Ok(intent) => {
                    if intent.is_new {
                        emit_peer_lifecycle(&state.event_tx, &peer_id, PeerState::Connecting, None);
                    }
                    intent.detach_completion();
                }
                Err(error) => {
                    if first_error.is_none() {
                        first_error = Some(core_error(&peer_id, "environment_changed", error));
                    }
                }
            }
        }
    }
    if let Some(error) = first_error {
        return Err(error);
    }
    Ok(())
}

fn spawn_direct_recovery(state: Arc<RuntimeState>, peer_id: String) {
    let task_state = Arc::clone(&state);
    let task_peer_id = peer_id.clone();
    let _ = state
        .task_supervisor
        .spawn_runtime("direct-recovery", async move {
            loop {
                let Ok(supervisor) = task_state.peer_supervisors.get_or_create(&task_peer_id)
                else {
                    return;
                };
                if !supervisor.maintain_connection()
                    || !task_state.has_ready_relay_path(&task_peer_id).await
                {
                    return;
                }
                let Some(delay) = task_state.next_direct_recovery_delay(&task_peer_id) else {
                    return;
                };
                let generation = supervisor.generation();
                if !task_state
                    .arm_direct_probe(
                        &task_peer_id,
                        generation,
                        delay.saturating_add(DIRECT_CONNECT_WINDOW),
                        CAPABILITY_RELIABLE_MESSAGE,
                    )
                    .await
                {
                    return;
                }
                tokio::time::sleep(delay).await;
                if supervisor.generation() != generation
                    || !supervisor.maintain_connection()
                    || !task_state.has_ready_relay_path(&task_peer_id).await
                {
                    task_state
                        .finish_direct_probe(&task_peer_id, generation)
                        .await;
                    return;
                }
                let result = ConnectivityAttemptCoordinator::new(Arc::clone(&task_state))
                    .probe_direct(&task_peer_id, CommunicationClass::ReliableMessage)
                    .await;
                if task_state.has_ready_direct_path(&task_peer_id).await {
                    return;
                }
                task_state
                    .finish_direct_probe(&task_peer_id, generation)
                    .await;
                if result.is_ok() {
                    return;
                }
            }
        });
}

/// Submit a peer intent and await the supervisor-owned completion.  Queueing
/// the ConnectivityAttempt is not command success: only Online settles as
/// Succeeded; an attempt failure is Failed, while invalidated generations and
/// shutdown are Cancelled.
async fn start_connect_peer(
    state: Arc<RuntimeState>,
    command_id: String,
    peer_id: String,
    class: CommunicationClass,
) -> Result<(), ProtocolError> {
    if peer_id.is_empty() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id is required",
        ));
    }
    if state.lifecycle.endpoint.read().await.is_none()
        || state.lifecycle.identity.read().await.is_none()
    {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "runtime is not configured",
            "connect",
            &peer_id,
        ));
    }
    if !state.peers.read().await.contains_key(&peer_id) {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "peer has no configured route",
            "connect",
            &peer_id,
        ));
    }
    let supervisor = state
        .peer_supervisors
        .get_or_create(&peer_id)
        .map_err(|error| core_error(&peer_id, "connect", error))?;
    let intent = state
        .peer_supervisors
        .start_connect(Arc::clone(&state), &peer_id, command_id, class)
        .map_err(|error| core_error(&peer_id, "connect", error))?;
    let generation = intent.generation;
    if intent.is_new {
        emit_peer_lifecycle(&state.event_tx, &peer_id, PeerState::Connecting, None);
    }
    match intent.completion().await {
        Ok(Ok(PeerState::Online)) => Ok(()),
        Ok(Ok(state)) => Err(protocol_error_with_peer(
            NetworkErrorCode::PeerOffline,
            format!("peer connect completed in unexpected state {state:?}"),
            "connect",
            &peer_id,
        )),
        Ok(Err(error)) => {
            if connect_completion_was_cancelled(&supervisor, generation, &error) {
                Err(protocol_error_with_peer(
                    NetworkErrorCode::Cancelled,
                    error.to_string(),
                    "connect",
                    &peer_id,
                ))
            } else if matches!(error, CoreNetworkError::Cancelled) {
                // The current PeerSupervisor translates an unsuccessful
                // ConnectivityAttempt into Cancelled after it has emitted the
                // detailed PeerState failure.  The generation is unchanged in
                // that case, so preserve the public Failed terminal state.
                Err(protocol_error_with_peer(
                    NetworkErrorCode::IoError,
                    "connectivity attempt failed",
                    "connect",
                    &peer_id,
                ))
            } else {
                Err(core_error(&peer_id, "connect", error))
            }
        }
        Err(_) => Err(protocol_error_with_peer(
            NetworkErrorCode::Cancelled,
            "connectivity attempt was cancelled before completion",
            "connect",
            &peer_id,
        )),
    }
}

fn connect_completion_was_cancelled(
    supervisor: &PeerSupervisor,
    generation: IntentGeneration,
    error: &CoreNetworkError,
) -> bool {
    matches!(
        error,
        CoreNetworkError::SupervisorStopping
            | CoreNetworkError::StaleAttempt
            | CoreNetworkError::StaleIntent
    ) || (matches!(error, CoreNetworkError::Cancelled) && supervisor.generation() != generation)
}

fn core_error(peer_id: &str, operation: &str, error: CoreNetworkError) -> ProtocolError {
    let code = match &error {
        CoreNetworkError::MailboxFull | CoreNetworkError::ResourceLimit(_) => {
            NetworkErrorCode::IoError
        }
        CoreNetworkError::SupervisorStopping | CoreNetworkError::Cancelled => {
            NetworkErrorCode::Cancelled
        }
        CoreNetworkError::NoRoute => NetworkErrorCode::NoRoute,
        CoreNetworkError::InvalidPeerId | CoreNetworkError::InvalidCommandId => {
            NetworkErrorCode::InvalidArgument
        }
        CoreNetworkError::DuplicateCommand => NetworkErrorCode::InvalidArgument,
        CoreNetworkError::StaleAttempt | CoreNetworkError::StaleIntent => {
            NetworkErrorCode::Cancelled
        }
        CoreNetworkError::CapabilityUnavailable => NetworkErrorCode::NoRoute,
    };
    protocol_error_with_peer(code, error.to_string(), operation, peer_id)
}

/// 接受 Relay 配置，并通过 Relay 事件报告 socket 认证结果。
async fn start_configure_relay(
    state: Arc<RuntimeState>,
    command: network_protocol::ConfigureRelayCommand,
) -> Result<(), ProtocolError> {
    if state.lifecycle.identity.read().await.is_none() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "runtime must be configured before Relay",
        ));
    }
    if command.relay_signing_seed.len() != 32 {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "Relay signing seed must contain 32 bytes",
        ));
    }
    if command.relay_url.trim().is_empty() || command.relay_credential.is_empty() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "Relay URL and credential are required",
        ));
    }
    emit_relay_state(&state.event_tx, RelayConnectionState::Connecting, None);
    let supervisor = Arc::clone(&state.task_supervisor);
    let task_started = supervisor.spawn_runtime("relay-configure", async move {
        match relay::configure_relay_for_state(Arc::clone(&state), command).await {
            Ok(()) => emit_relay_state(&state.event_tx, RelayConnectionState::Connected, None),
            Err(error) => {
                emit_relay_state(&state.event_tx, RelayConnectionState::Failed, Some(error))
            }
        }
    });
    if task_started.is_none() {
        return Err(protocol_error(
            NetworkErrorCode::Cancelled,
            "network runtime is stopping",
        ));
    }
    Ok(())
}

/// 把 wire 上的 CommunicationClass 解码为内部值；未知值（非法）按默认
/// ReliableMessage 处理，保证旧调用方（发送 0）行为不变。
fn decode_communication_class(value: i32) -> CommunicationClass {
    match CommunicationClass::try_from(value) {
        Ok(CommunicationClass::Unspecified) | Err(_) => CommunicationClass::ReliableMessage,
        Ok(class) => class,
    }
}

#[cfg(test)]
#[path = "tests/commands.rs"]
mod tests;
