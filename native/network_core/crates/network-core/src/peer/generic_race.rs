use network_identity::DeviceIdentity;
use network_nat::Candidate;
use network_protocol::{NetworkError as ProtocolError, NetworkErrorCode};
use std::collections::{HashSet, VecDeque};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::watch;
use tokio::task::JoinSet;
use tokio::time::timeout;

use crate::connect::GenericRouteScope;
use crate::connection::GenericRouteRuntime;
use crate::events::protocol_error_with_peer;
use crate::runtime::RuntimeState;
use crate::session::SessionId;

use super::direct_race::{candidate_attempt_key, enqueue_candidates};
use super::generic_dial::GenericDial;
use super::receiver::ConnectionReceiverSupervisor;
use super::{AuthenticatedGenericRoute, CANDIDATE_STAGGER};

const GENERIC_ROUTE_TASK_START_TIMEOUT: Duration = Duration::from_secs(1);

/// Owns outbound TCP/WebSocket candidate races and route startup.
pub(crate) struct OutboundGenericConnector;

#[allow(clippy::too_many_arguments)]
impl OutboundGenericConnector {
    pub(crate) async fn connect_generic_candidate(
        endpoint: SocketAddr,
        identity: Arc<DeviceIdentity>,
        expected_peer_public_key: [u8; 32],
        peer_id: String,
        session_binding: String,
        state: Arc<RuntimeState>,
        expected_session_id: SessionId,
        required_capabilities: u8,
        allow_websocket: bool,
        candidate_window: Duration,
    ) -> Result<AuthenticatedGenericRoute, ProtocolError> {
        let error_peer_id = peer_id.clone();
        let operation = async move {
            let mut transports = JoinSet::new();
            transports.spawn(Self::connect_generic_route(
                GenericDial::Tcp,
                endpoint,
                Arc::clone(&identity),
                expected_peer_public_key,
                peer_id.clone(),
                session_binding.clone(),
                Arc::clone(&state),
                expected_session_id,
                required_capabilities,
            ));
            if allow_websocket {
                transports.spawn(Self::connect_generic_route(
                    GenericDial::WebSocket,
                    endpoint,
                    identity,
                    expected_peer_public_key,
                    peer_id.clone(),
                    session_binding,
                    Arc::clone(&state),
                    expected_session_id,
                    required_capabilities,
                ));
            }

            let mut last_error = None;
            while let Some(result) = transports.join_next().await {
                match result {
                    Ok(Ok(route)) => {
                        let session_id = route.admission.session_id;
                        let remote_binding = route.crypto.remote_session_binding.clone();
                        let compatible = match route.scope.profile() {
                            Some(profile) => {
                                state
                                    .candidate_supports(
                                        &peer_id,
                                        session_id,
                                        profile,
                                        required_capabilities,
                                    )
                                    .await
                            }
                            None => false,
                        };
                        if !compatible {
                            route.scope.close().await;
                            state
                                .release_claimed_session(&peer_id, session_id, &remote_binding)
                                .await;
                            last_error = Some(protocol_error_with_peer(
                                NetworkErrorCode::NoRoute,
                                "generic candidate no longer satisfies the requested capability",
                                "connect",
                                &peer_id,
                            ));
                            continue;
                        }
                        transports.abort_all();
                        return Ok(route);
                    }
                    Ok(Err(error)) => last_error = Some(error),
                    Err(error) => {
                        last_error = Some(protocol_error_with_peer(
                            NetworkErrorCode::IoError,
                            format!("generic transport task failed: {error}"),
                            "connect",
                            &peer_id,
                        ));
                    }
                }
            }
            Err(last_error.unwrap_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::NoRoute,
                    "generic candidate transport race produced no route",
                    "connect",
                    &peer_id,
                )
            }))
        };
        tokio::time::timeout(candidate_window, operation)
            .await
            .unwrap_or_else(|_| {
                Err(protocol_error_with_peer(
                    NetworkErrorCode::Timeout,
                    "generic candidate deadline elapsed",
                    "connect",
                    &error_peer_id,
                ))
            })
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn connect_generic_candidates(
        candidates: Vec<Candidate>,
        identity: Arc<DeviceIdentity>,
        expected_peer_public_key: [u8; 32],
        peer_id: String,
        session_binding: String,
        state: Arc<RuntimeState>,
        expected_session_id: SessionId,
        required_capabilities: u8,
        allow_websocket: bool,
        deadline: Instant,
        mut candidate_updates: watch::Receiver<Option<Vec<Candidate>>>,
    ) -> Result<AuthenticatedGenericRoute, ProtocolError> {
        let mut pending = VecDeque::new();
        let mut started = HashSet::new();
        enqueue_candidates(&mut pending, &mut started, candidates);
        let mut attempts = JoinSet::new();
        let mut next_launch_at = Instant::now();
        let mut updates_closed = false;
        let mut last_error = None;

        loop {
            if !pending.is_empty() && Instant::now() >= next_launch_at {
                let candidate = pending.pop_front().expect("pending candidate");
                started.insert(candidate_attempt_key(&candidate));
                let candidate_window = deadline.saturating_duration_since(Instant::now());
                if candidate_window.is_zero() {
                    break;
                }
                let candidate_endpoint = candidate.endpoint;
                let candidate_identity = Arc::clone(&identity);
                let peer_id_for_task = peer_id.clone();
                let session_binding_for_task = session_binding.clone();
                let state_for_task = Arc::clone(&state);
                attempts.spawn(Self::connect_generic_candidate(
                    candidate_endpoint,
                    candidate_identity,
                    expected_peer_public_key,
                    peer_id_for_task,
                    session_binding_for_task,
                    state_for_task,
                    expected_session_id,
                    required_capabilities,
                    allow_websocket,
                    candidate_window,
                ));
                next_launch_at = Instant::now() + CANDIDATE_STAGGER;
                continue;
            }

            if attempts.is_empty() && pending.is_empty() && updates_closed {
                break;
            }

            tokio::select! {
                result = attempts.join_next(), if !attempts.is_empty() => {
                    match result {
                        Some(Ok(Ok(route))) => {
                            attempts.abort_all();
                            return Ok(route);
                        }
                        Some(Ok(Err(error))) => last_error = Some(error),
                        Some(Err(error)) => {
                            last_error = Some(protocol_error_with_peer(
                                NetworkErrorCode::IoError,
                                format!("generic candidate task failed: {error}"),
                                "connect",
                                &peer_id,
                            ));
                        }
                        None => {}
                    }
                }
                changed = candidate_updates.changed(), if !updates_closed => {
                    match changed {
                        Ok(()) => {
                            if let Some(update) = candidate_updates.borrow_and_update().clone() {
                                let had_pending = !pending.is_empty();
                                enqueue_candidates(&mut pending, &mut started, update);
                                if !had_pending && !pending.is_empty() {
                                    next_launch_at = Instant::now();
                                }
                            }
                        }
                        Err(_) => updates_closed = true,
                    }
                }
                _ = tokio::time::sleep_until(tokio::time::Instant::from_std(next_launch_at)), if !pending.is_empty() => {}
                _ = tokio::time::sleep_until(tokio::time::Instant::from_std(deadline)),
                    if attempts.is_empty() && pending.is_empty() =>
                {
                    break;
                }
            }
        }
        Err(last_error.unwrap_or_else(|| {
            protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "no generic direct candidates are available",
                "connect",
                &peer_id,
            )
        }))
    }
    /// Register both halves of one GenericRoute with the Session supervisor and
    /// wait for their deterministic startup barriers. The returned scope remains
    /// staged until ConnectionSessionStore sends its atomic commit signal.
    pub(crate) async fn supervise_generic_route(
        state: Arc<RuntimeState>,
        peer_id: &str,
        session_id: SessionId,
        runtime: GenericRouteRuntime,
    ) -> Result<GenericRouteScope, ProtocolError> {
        let GenericRouteRuntime {
            handle,
            inbound,
            driver,
            ready,
            commit,
            stop,
            stopping,
        } = runtime;
        let session_key = session_id.wire_key();
        let supervisor = Arc::clone(&state.task_supervisor);
        let mut driver_task = supervisor
            .spawn_session_controlled(session_key.clone(), "generic-route-io", driver)
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::Cancelled,
                    "generic-route-io could not be registered",
                    "generic-route_start",
                    peer_id,
                )
            })?;
        if timeout(GENERIC_ROUTE_TASK_START_TIMEOUT, ready)
            .await
            .ok()
            .and_then(Result::ok)
            .is_none()
        {
            driver_task.cancel().await;
            return Err(protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "generic-route-io did not become ready",
                "generic-route_start",
                peer_id,
            ));
        }

        let (receiver, receiver_ready) = ConnectionReceiverSupervisor::generic_route_receiver_task(
            Arc::clone(&state),
            peer_id.to_string(),
            handle.clone(),
            inbound,
            session_id,
            stop.clone(),
            Arc::clone(&stopping),
        );
        let mut receiver_task = match supervisor.spawn_session_controlled(
            session_key,
            "generic-route-receiver",
            receiver,
        ) {
            Some(task) => task,
            None => {
                driver_task.cancel().await;
                return Err(protocol_error_with_peer(
                    NetworkErrorCode::Cancelled,
                    "generic-route-receiver could not be registered",
                    "generic-route_start",
                    peer_id,
                ));
            }
        };
        if timeout(GENERIC_ROUTE_TASK_START_TIMEOUT, receiver_ready)
            .await
            .ok()
            .and_then(Result::ok)
            .is_none()
        {
            receiver_task.cancel().await;
            driver_task.cancel().await;
            return Err(protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "generic-route-receiver did not become ready",
                "generic-route_start",
                peer_id,
            ));
        }

        Ok(GenericRouteScope::new(
            handle,
            driver_task,
            receiver_task,
            stop,
            stopping,
            commit,
        ))
    }
}
