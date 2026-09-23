use std::sync::Arc;

use network_relay::RelayDataClient;

use crate::connect::PathHandle;
use crate::session::SessionId;

use super::RuntimeState;

impl RuntimeState {
    /// Hard-close only the physical projections owned by `session_id`.
    ///
    /// `PeerPathManager` is the carrier owner and can hold independent Direct
    /// and Relay paths.  The projection index supplies the session binding;
    /// the manager handle check prevents a stale coordinator from closing a
    /// newer path that reused the same topology slot.
    pub(crate) async fn close_transport_path_for_session(
        &self,
        peer_id: &str,
        session_id: SessionId,
    ) -> bool {
        let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() else {
            return false;
        };

        // The projection store returns a snapshot. We deliberately do not
        // hold the synchronous path-manager lock across this await; manager
        // handles are rechecked immediately before close.
        let handles = self
            .path_projections
            .handles_for_session(peer_id, session_id)
            .await;
        let direct_handle = handles.direct;
        let relay_handle = handles.relay;

        let (direct_closed, relay_closed) = {
            let mut manager = manager.lock().expect("peer path manager lock");
            let direct_closed = direct_handle.as_ref().is_some_and(|expected| {
                if manager.direct_ready() == Some(expected) {
                    manager.hard_close_direct();
                    true
                } else {
                    false
                }
            });
            let relay_closed = relay_handle.as_ref().is_some_and(|expected| {
                if manager.relay_ready() == Some(expected) {
                    manager.hard_close_relay();
                    true
                } else {
                    false
                }
            });
            (direct_closed, relay_closed)
        };
        if !direct_closed && !relay_closed {
            return false;
        }

        self.close_inactive_streams(peer_id).await;
        if let Ok(mut recovery) = self.direct_recovery.lock() {
            if direct_closed {
                recovery
                    .entry(peer_id.to_string())
                    .or_default()
                    .mark_direct_unavailable();
            }
            if relay_closed {
                recovery
                    .entry(peer_id.to_string())
                    .or_default()
                    .mark_relay_lost();
            }
        }

        self.path_projections
            .remove_closed_for_session(
                peer_id,
                session_id,
                direct_handle.as_ref().filter(|_| direct_closed),
                relay_handle.as_ref().filter(|_| relay_closed),
            )
            .await;
        self.notify_path_changed();
        true
    }

    pub(crate) async fn close_transport_path(&self, peer_id: &str) -> Option<PathHandle> {
        let manager = self.peer_path_managers.write().await.remove(peer_id);
        let first = self.path_projections.remove_peer(peer_id).await;
        self.direct_recovery
            .lock()
            .expect("recovery policy lock")
            .remove(peer_id);
        if let Some(manager) = manager {
            manager.lock().expect("peer path manager lock").hard_close();
        }
        self.notify_path_changed();
        first
    }

    pub(crate) async fn close_relay_path(
        &self,
        peer_id: &str,
        data: Option<&Arc<RelayDataClient>>,
    ) -> Option<PathHandle> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let relay_handle = {
            let mut manager = manager.lock().expect("peer path manager lock");
            let closed = manager.close_ready_relay(data)?;
            if let Ok(mut recovery) = self.direct_recovery.lock() {
                if let Some(policy) = recovery.get_mut(peer_id) {
                    policy.mark_relay_lost();
                }
            }
            closed
        };
        self.cleanup_closed_path(peer_id, &relay_handle).await;
        Some(relay_handle)
    }

    pub(crate) async fn close_direct_path(
        &self,
        peer_id: &str,
        route_id: Option<crate::connection::GenericRouteId>,
    ) -> Option<PathHandle> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let direct_handle = {
            let mut manager = manager.lock().expect("peer path manager lock");
            let closed = manager.close_ready_direct(route_id)?;
            if let Ok(mut recovery) = self.direct_recovery.lock() {
                if let Some(policy) = recovery.get_mut(peer_id) {
                    policy.mark_direct_unavailable();
                }
            }
            closed
        };
        self.cleanup_closed_path(peer_id, &direct_handle).await;
        Some(direct_handle)
    }

    pub(crate) async fn close_direct_path_for_connection(
        &self,
        peer_id: &str,
        connection: &quinn::Connection,
    ) -> Option<PathHandle> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let direct_handle = {
            let mut manager = manager.lock().expect("peer path manager lock");
            let closed = manager.close_ready_direct_connection(connection)?;
            if let Ok(mut recovery) = self.direct_recovery.lock() {
                if let Some(policy) = recovery.get_mut(peer_id) {
                    policy.mark_direct_unavailable();
                }
            }
            closed
        };
        self.cleanup_closed_path(peer_id, &direct_handle).await;
        Some(direct_handle)
    }

    pub(crate) async fn close_all_relay_paths(&self) {
        let peers = self
            .peer_path_managers
            .read()
            .await
            .iter()
            .filter(|(_, manager)| {
                manager
                    .lock()
                    .expect("peer path manager lock")
                    .relay_ready()
                    .is_some()
            })
            .map(|(peer_id, _)| peer_id.clone())
            .collect::<Vec<_>>();
        for peer_id in peers {
            let _ = self.close_relay_path(&peer_id, None).await;
        }
    }

    pub(crate) async fn close_all_transport_paths(&self) {
        let peers = self
            .peer_path_managers
            .read()
            .await
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        for peer_id in peers {
            let _ = self.close_transport_path(&peer_id).await;
        }
    }

    /// Finish asynchronous cleanup for one exact closed path.
    ///
    /// Keep an empty manager registered: a concurrent publisher may already
    /// hold a clone of that manager outside the map lock. Only explicit peer
    /// transport close and runtime shutdown remove the manager registration.
    pub(crate) async fn cleanup_closed_path(&self, peer_id: &str, handle: &PathHandle) {
        self.close_inactive_streams(peer_id).await;
        self.path_projections.remove_handle(peer_id, handle).await;
        self.notify_path_changed();
    }

    #[cfg(test)]
    pub(crate) async fn close_path_for_test(&self, peer_id: &str) {
        let session_id = self.connection_sessions.current_session_id(peer_id).await;
        if self.close_direct_path(peer_id, None).await.is_some() {
            if let Some(session_id) = session_id {
                if self
                    .connection_sessions
                    .retire_session(peer_id, session_id)
                    .await
                {
                    self.cancel_session_tasks(peer_id, session_id).await;
                    if let Ok(supervisor) = self.peer_supervisors.get_or_create(peer_id) {
                        supervisor.path_lost();
                    }
                    crate::events::emit_peer_state(
                        &self.event_tx,
                        peer_id,
                        network_protocol::PeerConnectionState::Disconnected,
                        network_protocol::RouteType::Unspecified,
                        None,
                    );
                }
            }
        }
    }
}
