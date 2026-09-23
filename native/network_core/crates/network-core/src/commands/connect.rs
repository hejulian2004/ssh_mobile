use std::sync::Arc;

use network_protocol::{
    CommunicationClass, NetworkError as ProtocolError, NetworkErrorCode, RelayConnectionState,
};

use crate::connect::{
    ConnectivityAttemptCoordinator, IntentGeneration, PeerState, PeerSupervisor,
    CAPABILITY_RELIABLE_MESSAGE, DIRECT_CONNECT_WINDOW,
};
use crate::errors::CoreNetworkError;
use crate::events::{
    emit_peer_lifecycle, emit_relay_state, protocol_error, protocol_error_with_peer,
};
use crate::relay;
use crate::runtime::RuntimeState;

use super::peer_lifecycle::close_peer_connection;

/// Apply an environment transition to the owning lifecycle graph.  Discovery
/// refresh and Direct recovery are independent of healthy Relay/Realtime
/// owners; passive peers never acquire persistent recovery maintenance.
pub(crate) async fn handle_network_environment_changed(
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
pub(crate) async fn start_connect_peer(
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

pub(crate) fn connect_completion_was_cancelled(
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

pub(crate) fn core_error(peer_id: &str, operation: &str, error: CoreNetworkError) -> ProtocolError {
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
pub(crate) async fn start_configure_relay(
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
pub(crate) fn decode_communication_class(value: i32) -> CommunicationClass {
    match CommunicationClass::try_from(value) {
        Ok(CommunicationClass::Unspecified) | Err(_) => CommunicationClass::ReliableMessage,
        Ok(class) => class,
    }
}
