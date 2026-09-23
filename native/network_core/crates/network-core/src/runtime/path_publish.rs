use std::sync::Arc;
use std::time::Duration;

use network_relay::RelayDataClient;

use crate::connect::PathHandle;
use crate::errors::CoreNetworkError;
use crate::session::SessionId;

use super::RuntimeState;

impl RuntimeState {
    async fn publish_transport_path(
        &self,
        peer_id: &str,
        session_id: SessionId,
        route: crate::connect::ActiveRoute,
    ) -> Result<Option<PathHandle>, CoreNetworkError> {
        let profile = route.profile();
        if !self.route_is_authorized(peer_id, profile.topology()).await {
            route.close().await;
            return Err(CoreNetworkError::NoRoute);
        }
        let manager = self.peer_path_manager(peer_id).await?;
        let (old_handle, projection) = {
            let mut manager = manager.lock().expect("peer path manager lock");
            let old_handle = match profile.topology() {
                crate::connection::RouteTopology::Direct => manager.direct_ready().cloned(),
                crate::connection::RouteTopology::Relay => manager.relay_ready().cloned(),
            };
            let handle = manager.publish_ready_with_route(route)?;
            let projection = manager
                .projection(&handle)
                .ok_or(CoreNetworkError::StaleAttempt)?;
            (old_handle, projection)
        };
        self.path_projections
            .replace_topology(peer_id, session_id, projection)
            .await;
        let mut recovery = self.direct_recovery.lock().expect("recovery policy lock");
        let policy = recovery.entry(peer_id.to_string()).or_default();
        match profile.topology() {
            crate::connection::RouteTopology::Direct => policy.mark_direct_ready(),
            crate::connection::RouteTopology::Relay => policy.mark_relay_ready(),
        }
        self.notify_path_changed();
        Ok(old_handle)
    }

    pub(crate) async fn has_ready_direct_path(&self, peer_id: &str) -> bool {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return false;
        }
        self.peer_path_managers
            .read()
            .await
            .get(peer_id)
            .is_some_and(|manager| {
                manager
                    .lock()
                    .expect("peer path manager lock")
                    .direct_ready()
                    .is_some()
            })
    }

    /// Return whether an already-ready Direct path satisfies the requested
    /// capability mask.  A ready path with a different capability is not a
    /// successful Stage A reuse candidate.
    pub(crate) async fn has_ready_direct_path_for_capability(
        &self,
        peer_id: &str,
        required_capabilities: u8,
    ) -> bool {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return false;
        }
        self.peer_path_managers
            .read()
            .await
            .get(peer_id)
            .is_some_and(|manager| {
                manager
                    .lock()
                    .expect("peer path manager lock")
                    .direct_ready()
                    .is_some_and(|handle| {
                        handle.capability_mask() & required_capabilities == required_capabilities
                    })
            })
    }

    pub(crate) async fn has_ready_relay_path(&self, peer_id: &str) -> bool {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Relay)
            .await
        {
            return false;
        }
        self.peer_path_managers
            .read()
            .await
            .get(peer_id)
            .is_some_and(|manager| {
                manager
                    .lock()
                    .expect("peer path manager lock")
                    .relay_ready()
                    .is_some()
            })
    }

    pub(crate) fn reset_direct_recovery(&self, peer_id: &str) {
        let mut recovery = self.direct_recovery.lock().expect("recovery policy lock");
        recovery
            .entry(peer_id.to_string())
            .or_default()
            .reset_after_environment_change();
    }

    pub(crate) fn next_direct_recovery_delay(&self, peer_id: &str) -> Option<Duration> {
        self.direct_recovery
            .lock()
            .expect("recovery policy lock")
            .get_mut(peer_id)
            .and_then(crate::discovery::DirectRecoveryPolicy::next_delay)
    }

    pub(crate) async fn arm_direct_probe(
        &self,
        peer_id: &str,
        generation: crate::connect::IntentGeneration,
        budget: Duration,
        required_capabilities: u8,
    ) -> bool {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return false;
        }
        let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() else {
            return false;
        };
        let mut manager = manager.lock().expect("peer path manager lock");
        if manager.direct_probe().is_some() {
            return false;
        }
        manager
            .ensure_direct_probe(generation.get(), required_capabilities, budget)
            .is_ok()
    }

    pub(crate) async fn finish_direct_probe(
        &self,
        peer_id: &str,
        generation: crate::connect::IntentGeneration,
    ) {
        if let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() {
            manager
                .lock()
                .expect("peer path manager lock")
                .finish_direct_probe(generation.get());
        }
    }

    pub(crate) async fn attach_connection_for_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        connection: quinn::Connection,
        route: network_protocol::RouteType,
    ) -> Result<Option<PathHandle>, ()> {
        let topology = crate::connection::ConnectionProfile::for_route(route)
            .map(|profile| profile.topology())
            .ok_or(())?;
        if !self.route_is_authorized(peer_id, topology).await {
            connection.close(quinn::VarInt::from_u32(0), b"route unauthorized");
            return Err(());
        }
        let session_id = match self.connection_sessions.current_session_id(peer_id).await {
            Some(session_id) => {
                if expected_session_id.is_some_and(|expected| expected != session_id) {
                    connection.close(quinn::VarInt::from_u32(0), b"stale physical path");
                    return Err(());
                }
                session_id
            }
            None if expected_session_id.is_some() => {
                connection.close(quinn::VarInt::from_u32(0), b"stale physical path");
                return Err(());
            }
            None => {
                let session_id = SessionId::new();
                self.connection_sessions
                    .register_pending_session(peer_id, session_id)
                    .await
                    .map_err(|_| ())?;
                session_id
            }
        };
        self.publish_transport_path(
            peer_id,
            session_id,
            crate::connect::ActiveRoute::quic(connection, route),
        )
        .await
        .map_err(|_| ())
    }

    pub(crate) async fn attach_generic_route_for_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        scope: &mut crate::connect::GenericRouteScope,
    ) -> Result<Option<PathHandle>, ()> {
        let session_id = self
            .connection_sessions
            .current_session_id(peer_id)
            .await
            .ok_or(())?;
        if expected_session_id.is_some_and(|expected| expected != session_id) {
            return Err(());
        }
        let profile = scope.profile().ok_or(())?;
        if !self.route_is_authorized(peer_id, profile.topology()).await {
            return Err(());
        }
        if self.path_profile(peer_id).await == Some(profile) {
            return Err(());
        }
        let owner = scope.commit_and_take_owner()?;
        self.publish_transport_path(
            peer_id,
            session_id,
            crate::connect::ActiveRoute::generic(owner),
        )
        .await
        .map_err(|_| ())
    }

    pub(crate) async fn mark_relay_route_connected(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        relay: Option<Arc<RelayDataClient>>,
    ) -> bool {
        if self.connection_sessions.current_session_id(peer_id).await != Some(expected_session_id) {
            return false;
        }
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Relay)
            .await
        {
            return false;
        }
        self.publish_transport_path(
            peer_id,
            expected_session_id,
            crate::connect::ActiveRoute::relay(relay),
        )
        .await
        .is_ok()
    }

    pub(crate) async fn path_profile(
        &self,
        peer_id: &str,
    ) -> Option<crate::connection::ConnectionProfile> {
        let (allow_direct, allow_relay) = self.authorized_route_flags(peer_id).await;
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let manager = manager.lock().expect("peer path manager lock");
        match manager.select_with_authorization(0, allow_direct, allow_relay)? {
            crate::connect::PathSelection::Direct => {
                manager.direct_ready().map(PathHandle::profile)
            }
            crate::connect::PathSelection::Relay => manager.relay_ready().map(PathHandle::profile),
        }
    }

    /// Check the currently ready physical paths against a business capability
    /// without allowing the ConnectionSession admission store to answer the
    /// route question.
    pub(crate) async fn path_supports_capability(
        &self,
        peer_id: &str,
        required_capabilities: u8,
    ) -> bool {
        let (allow_direct, allow_relay) = self.authorized_route_flags(peer_id).await;
        let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() else {
            return false;
        };
        let supports = manager
            .lock()
            .expect("peer path manager lock")
            .select_with_authorization(required_capabilities, allow_direct, allow_relay)
            .is_some();
        supports
    }

    pub(crate) async fn path_route(&self, peer_id: &str) -> Option<network_protocol::RouteType> {
        self.path_profile(peer_id)
            .await
            .and_then(|profile| profile.route().to_wire())
    }

    pub(crate) async fn path_relay_data(&self, peer_id: &str) -> Option<Arc<RelayDataClient>> {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Relay)
            .await
        {
            return None;
        }
        let manager = {
            let managers = self.peer_path_managers.read().await;
            managers.get(peer_id).cloned()
        }?;
        let manager = manager.lock().expect("peer path manager lock");
        manager.current_relay_data()
    }

    pub(crate) async fn path_is_current_relay_data(
        &self,
        peer_id: &str,
        data: &Arc<RelayDataClient>,
    ) -> bool {
        self.path_relay_data(peer_id)
            .await
            .is_some_and(|current| Arc::ptr_eq(&current, data))
    }

    pub(crate) async fn path_send_channel_frame_for_lease(
        &self,
        lease: &crate::connect::PathLease,
        relay_token: &str,
        kind: crate::connection::GenericFrameKind,
        payload: &[u8],
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if !lease.is_active() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "path lease inactive",
            )
            .into());
        }
        let result = lease.send_channel_frame(relay_token, kind, payload).await;
        if result.is_ok() && !lease.is_active() {
            return Err(
                std::io::Error::new(std::io::ErrorKind::NotConnected, "path lease lost").into(),
            );
        }
        result
    }

    pub(crate) async fn path_is_connected(&self, peer_id: &str) -> bool {
        let current_session = self.connection_sessions.current_session_id(peer_id).await;
        let Some(session_id) = current_session else {
            return false;
        };
        self.path_projections.has_alive(peer_id, session_id).await
    }

    #[cfg(test)]
    pub(crate) async fn attach_test_generic_route(
        &self,
        peer_id: &str,
        session_id: SessionId,
        handle: crate::connection::GenericRouteHandle,
    ) -> Result<(), ()> {
        self.publish_transport_path(
            peer_id,
            session_id,
            crate::connect::ActiveRoute::generic_test(handle),
        )
        .await
        .map(|_| ())
        .map_err(|_| ())
    }
}
