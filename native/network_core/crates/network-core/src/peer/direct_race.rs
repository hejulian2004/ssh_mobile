use network_identity::DeviceIdentity;
use network_nat::{Candidate, CandidateKind, MAX_CANDIDATES_PER_SIGNAL};
use network_protocol::{NetworkError as ProtocolError, NetworkErrorCode};
use quinn::{Connection, Endpoint};
use std::collections::{HashSet, VecDeque};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::watch;
use tokio::task::JoinSet;

use crate::crypto_handshake::SessionCryptoMaterial;
use crate::events::protocol_error_with_peer;
use crate::runtime::{ConnectionAdmissionLease, RuntimeState};
use crate::session::SessionId;

use super::direct_quic::connect_direct_with_crypto;
use super::generic_race::OutboundGenericConnector;
use super::{ConnectedRoute, DirectRouteAttempt, CANDIDATE_STAGGER};

/// Direct 阶段中 QUIC race 的领先预算（§15）：先给 QUIC 候选一个子预算，然后用窗口
/// 剩余预算跑 generic（TCP/WebSocket）候选。避免 QUIC 候选被黑洞/超时耗尽整个 Direct
/// 窗口时，仅 TCP/WS 可达的 peer 被饿死而错误回退 Relay。
const QUIC_LEAD_BUDGET: Duration = Duration::from_millis(2500);

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct CandidateAttemptKey {
    pub(crate) candidate_id: String,
    pub(crate) endpoint: SocketAddr,
    pub(crate) generation: u64,
}

pub(crate) fn candidate_attempt_key(candidate: &Candidate) -> CandidateAttemptKey {
    CandidateAttemptKey {
        candidate_id: candidate.candidate_id.clone(),
        endpoint: candidate.endpoint,
        generation: candidate.generation,
    }
}

/// Reconciles an authoritative candidate snapshot with the not-yet-started queue.
/// An endpoint or generation change creates a new attempt key even when the
/// candidate ID is unchanged; candidates removed from the snapshot are dropped
/// before they can enter the race. Active attempts are intentionally left alone.
pub(crate) fn enqueue_candidates(
    pending: &mut VecDeque<Candidate>,
    started: &mut HashSet<CandidateAttemptKey>,
    candidates: Vec<Candidate>,
) {
    let snapshot = candidates
        .into_iter()
        // Relay is a separate fallback path. It is never a DirectProbe target,
        // even if a stale/legacy Discovery snapshot still carries a relay
        // candidate alongside direct candidates.
        .filter(|candidate| candidate.kind != CandidateKind::Relay)
        .take(MAX_CANDIDATES_PER_SIGNAL)
        .collect::<Vec<_>>();
    let snapshot_keys = snapshot
        .iter()
        .map(candidate_attempt_key)
        .collect::<HashSet<_>>();
    pending.retain(|candidate| snapshot_keys.contains(&candidate_attempt_key(candidate)));
    for candidate in snapshot {
        let key = candidate_attempt_key(&candidate);
        if !started.contains(&key)
            && !pending
                .iter()
                .any(|pending| candidate_attempt_key(pending) == key)
        {
            pending.push_back(candidate);
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn connect_direct_candidates_with_crypto(
    endpoint: Endpoint,
    candidates: Vec<Candidate>,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    attempt_id: String,
    deadline: Instant,
    session_binding: String,
    state: Arc<RuntimeState>,
    expected_session_id: Option<SessionId>,
    required_capabilities: u8,
    mut candidate_updates: watch::Receiver<Option<Vec<Candidate>>>,
) -> Result<(Connection, SessionCryptoMaterial, ConnectionAdmissionLease), ProtocolError> {
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
            let endpoint = endpoint.clone();
            let identity = Arc::clone(&identity);
            let peer_id_for_task = peer_id.clone();
            let session_binding = session_binding.clone();
            let attempt_id = attempt_id.clone();
            let state = Arc::clone(&state);
            attempts.spawn(async move {
                connect_direct_with_crypto(
                    endpoint,
                    candidate.endpoint,
                    identity,
                    expected_peer_public_key,
                    peer_id_for_task,
                    attempt_id,
                    candidate_window,
                    &session_binding,
                    state,
                    expected_session_id,
                    required_capabilities,
                )
                .await
            });
            next_launch_at = Instant::now() + CANDIDATE_STAGGER;
            continue;
        }

        // QUIC is only the lead phase, but keep the coordination receiver alive until
        // its deadline even if current candidates fail: a late ConnectivityAnswer may
        // add the candidate that wins the race. The same receiver is handed to generic
        // fallback after the QUIC lead budget expires.
        if attempts.is_empty()
            && pending.is_empty()
            && (updates_closed || Instant::now() >= deadline)
        {
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
                            NetworkErrorCode::QuicError,
                            format!("candidate connectivity task failed: {error}"),
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
            "candidate set is empty",
            "connect",
            &peer_id,
        )
    }))
}

/// Route selection gives QUIC the first direct budget, then races authenticated
/// TCP and binary WebSocket attempts in staggered candidate groups. Each
/// generic route is admitted only after the same identity proof used by QUIC.
///
/// §15/§37：Direct 窗口被切成两段——QUIC 候选并行竞争 `min(window, QUIC_LEAD_BUDGET)`，
/// 然后用窗口**剩余**预算在统一 deadline 内按候选组交错启动 generic
/// （TCP/WebSocket）尝试。这样 QUIC 被黑洞/超时耗尽后，仅 TCP/WS 可达的 peer
/// 仍能在窗口内走 generic 成功，而不是被饿死回退 Relay。
pub(crate) async fn connect_direct_or_generic(
    attempt: DirectRouteAttempt,
) -> Result<ConnectedRoute, ProtocolError> {
    let DirectRouteAttempt {
        state,
        endpoint,
        candidates,
        identity,
        expected_peer_public_key,
        peer_id,
        session_binding,
        session_id,
        attempt_id,
        connect_window,
        required_capabilities,
        allow_websocket,
        candidate_updates,
    } = attempt;
    let generic_candidates = candidates.clone();
    let started = Instant::now();
    // QUIC race 领先预算（不改变 DIRECT_CONNECT_WINDOW 的语义：它仍是整个 Direct 阶段
    // 的总窗口）。
    let quic_budget = connect_window.min(QUIC_LEAD_BUDGET);

    // 1) QUIC 候选并行竞争（子预算内）。
    let quic_deadline = Instant::now() + quic_budget;
    let quic_result = tokio::time::timeout(
        quic_budget,
        connect_direct_candidates_with_crypto(
            endpoint,
            candidates,
            Arc::clone(&identity),
            expected_peer_public_key,
            peer_id.clone(),
            attempt_id,
            quic_deadline,
            session_binding.clone(),
            Arc::clone(&state),
            Some(session_id),
            required_capabilities,
            candidate_updates.clone(),
        ),
    )
    .await;
    let quic_fallback_error = match quic_result {
        Ok(Ok((connection, crypto, admission))) => {
            return Ok(ConnectedRoute::Quic {
                connection,
                crypto,
                admission,
            });
        }
        Ok(Err(error)) => error,
        Err(_) => protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "Direct QUIC window elapsed",
            "connect",
            &peer_id,
        ),
    };

    // 2) QUIC 未胜出：用窗口剩余预算跑 generic（TCP/WS）候选。
    let direct_deadline = started + connect_window;
    let remaining = direct_deadline.saturating_duration_since(Instant::now());
    let generic_result = tokio::time::timeout(
        remaining,
        OutboundGenericConnector::connect_generic_candidates(
            generic_candidates,
            identity,
            expected_peer_public_key,
            peer_id.clone(),
            session_binding,
            state,
            session_id,
            required_capabilities,
            allow_websocket,
            direct_deadline,
            candidate_updates,
        ),
    )
    .await;
    match generic_result {
        Ok(Ok(route)) => Ok(ConnectedRoute::Generic(route)),
        Ok(Err(_)) => Err(quic_fallback_error),
        Err(_) => Err(protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "Direct connect window elapsed",
            "connect",
            &peer_id,
        )),
    }
}

pub(crate) fn monotonic_candidate_generation() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(1)
        .max(1)
}

/// 为路径选择和诊断对端点进行分类。
pub(crate) fn candidate_kind_for(endpoint: SocketAddr) -> CandidateKind {
    match endpoint.ip() {
        std::net::IpAddr::V4(address)
            if address.is_private() || address.is_loopback() || address.is_link_local() =>
        {
            CandidateKind::Lan
        }
        std::net::IpAddr::V6(address)
            if !address.is_loopback() && !address.is_unicast_link_local() =>
        {
            CandidateKind::PublicIpv6
        }
        _ => CandidateKind::ServerReflexive,
    }
}
