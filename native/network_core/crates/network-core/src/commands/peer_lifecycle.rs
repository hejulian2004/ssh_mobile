use std::collections::HashSet;

use network_protocol::{NetworkError as ProtocolError, NetworkErrorCode};

use crate::connect::{PeerId, PeerState};
use crate::events::{protocol_error, protocol_error_with_peer};
use crate::relay;
use crate::runtime::RuntimeState;

pub(crate) fn validate_e2ee_policy(value: i32) -> Result<(), ProtocolError> {
    network_protocol::E2eePolicy::try_from(value)
        .map(|_| ())
        .map_err(|_| protocol_error(NetworkErrorCode::InvalidArgument, "unknown E2EE policy"))
}

pub(crate) async fn remove_peer_v2(
    state: &RuntimeState,
    peer_id: String,
) -> Result<(), ProtocolError> {
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

pub(crate) async fn emit_peer_diagnostics(
    state: &RuntimeState,
    peer_id: String,
) -> Result<(), ProtocolError> {
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
pub(super) async fn close_peer_connection(state: &RuntimeState, peer_id: &str) {
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
pub(super) async fn close_peer_relay_path(state: &RuntimeState, peer_id: &str) {
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
            u32::from(manager.direct_ready().is_some()) + u32::from(manager.relay_ready().is_some())
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
