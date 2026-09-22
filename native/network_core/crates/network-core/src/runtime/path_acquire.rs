use std::sync::{Arc, Mutex};

use network_relay::RelayDataClient;

use crate::connect::{PeerId, PeerPathManager};
use crate::errors::CoreNetworkError;
use crate::session::SessionId;

use super::RuntimeState;

impl RuntimeState {
    pub(crate) async fn peer_path_manager(
        &self,
        peer_id: &str,
    ) -> Result<Arc<Mutex<PeerPathManager>>, CoreNetworkError> {
        let peer = PeerId::new(peer_id)?;
        if let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() {
            return Ok(manager);
        }
        let mut managers = self.peer_path_managers.write().await;
        Ok(managers
            .entry(peer_id.to_string())
            .or_insert_with(|| {
                Arc::new(Mutex::new(PeerPathManager::new(
                    peer.clone(),
                    Arc::clone(&self.ready_paths),
                )))
            })
            .clone())
    }

    /// Acquire one explicit business lease from the sole peer path owner.
    /// RuntimeState exposes the lookup boundary; it never stores or returns a
    /// second strong carrier owner.
    pub(crate) async fn acquire_path_lease(
        &self,
        peer_id: &str,
        required_capabilities: u8,
    ) -> Result<crate::connect::PathLease, CoreNetworkError> {
        let _peer_id = PeerId::new(peer_id)?;
        let manager = self
            .peer_path_managers
            .read()
            .await
            .get(peer_id)
            .cloned()
            .ok_or(CoreNetworkError::NoRoute)?;
        let (allow_direct, allow_relay) = self.authorized_route_flags(peer_id).await;
        let manager = manager.lock().expect("peer path manager lock");
        let selected = manager
            .select_with_authorization(required_capabilities, allow_direct, allow_relay)
            .ok_or(CoreNetworkError::NoRoute)?;
        let (acquired, lease) =
            manager.acquire_with_authorization(required_capabilities, allow_direct, allow_relay)?;
        if acquired != selected {
            lease.release();
            return Err(CoreNetworkError::StaleAttempt);
        }
        Ok(lease)
    }

    /// Acquire the current Relay path for Relay-only business I/O. Generic
    /// path selection prefers Direct and therefore cannot preserve Relay
    /// reservation identity for these operations.
    pub(crate) async fn acquire_relay_path_lease(
        &self,
        peer_id: &str,
        required_capabilities: u8,
    ) -> Result<crate::connect::PathLease, CoreNetworkError> {
        let _peer_id = PeerId::new(peer_id)?;
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Relay)
            .await
        {
            return Err(CoreNetworkError::NoRoute);
        }
        let manager = self
            .peer_path_managers
            .read()
            .await
            .get(peer_id)
            .cloned()
            .ok_or(CoreNetworkError::NoRoute)?;
        let lease = manager
            .lock()
            .expect("peer path manager lock")
            .acquire_relay(required_capabilities)?;
        Ok(lease)
    }

    /// Acquire the lease for the exact QUIC carrier that delivered an inbound
    /// stream. Inbound work must not silently move to whichever path happens
    /// to be preferred after the frame was received.
    pub(crate) async fn acquire_path_lease_for_connection(
        &self,
        peer_id: &str,
        connection: &quinn::Connection,
        required_capabilities: u8,
    ) -> Result<crate::connect::PathLease, CoreNetworkError> {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return Err(CoreNetworkError::NoRoute);
        }
        self.acquire_matching_path_lease(peer_id, required_capabilities, |lease| {
            lease
                .connection()
                .is_some_and(|candidate| candidate.stable_id() == connection.stable_id())
        })
        .await
    }

    /// Acquire the lease for the exact generic route that delivered an
    /// inbound frame. The route id is the generic carrier identity, not a
    /// current-path selection hint.
    pub(crate) async fn acquire_path_lease_for_generic_route(
        &self,
        peer_id: &str,
        route_id: crate::connection::GenericRouteId,
        required_capabilities: u8,
    ) -> Result<crate::connect::PathLease, CoreNetworkError> {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return Err(CoreNetworkError::NoRoute);
        }
        self.acquire_matching_path_lease(peer_id, required_capabilities, |lease| {
            match lease.stream_carrier() {
                Some(crate::connect::StreamCarrier::Generic(handle)) => handle.id() == route_id,
                #[cfg(test)]
                Some(crate::connect::StreamCarrier::GenericTest(handle)) => handle.id() == route_id,
                _ => false,
            }
        })
        .await
    }

    /// Acquire the lease for the exact Relay data client that delivered an
    /// inbound frame. Relay data clients are compared by identity because a
    /// new reservation may exist while an old one is still draining.
    pub(crate) async fn acquire_path_lease_for_relay_data(
        &self,
        peer_id: &str,
        data: &Arc<RelayDataClient>,
        required_capabilities: u8,
    ) -> Result<crate::connect::PathLease, CoreNetworkError> {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Relay)
            .await
        {
            return Err(CoreNetworkError::NoRoute);
        }
        self.acquire_matching_path_lease(peer_id, required_capabilities, |lease| {
            lease
                .relay_data()
                .is_some_and(|candidate| Arc::ptr_eq(&candidate, data))
        })
        .await
    }

    async fn acquire_matching_path_lease<F>(
        &self,
        peer_id: &str,
        required_capabilities: u8,
        matches: F,
    ) -> Result<crate::connect::PathLease, CoreNetworkError>
    where
        F: Fn(&crate::connect::PathLease) -> bool,
    {
        let _peer_id = PeerId::new(peer_id)?;
        let manager = self
            .peer_path_managers
            .read()
            .await
            .get(peer_id)
            .cloned()
            .ok_or(CoreNetworkError::NoRoute)?;
        let handles = {
            let manager = manager.lock().expect("peer path manager lock");
            let mut handles = Vec::new();
            if let Some(handle) = manager.direct_ready().cloned() {
                handles.push(handle);
            }
            if let Some(handle) = manager.relay_ready().cloned() {
                handles.push(handle);
            }
            handles
        };
        for handle in handles {
            if handle.capability_mask() & required_capabilities != required_capabilities {
                continue;
            }
            let projection = manager
                .lock()
                .expect("peer path manager lock")
                .projection(&handle);
            let Some(projection) = projection else {
                continue;
            };
            let Ok(lease) = projection.acquire() else {
                continue;
            };
            if matches(&lease) {
                return Ok(lease);
            }
            lease.release();
        }
        Err(CoreNetworkError::NoRoute)
    }

    /// Ensure one business capability through the peer supervisor. This path
    /// starts the supervisor mailbox worker but never enables maintenance;
    /// only an explicit ConnectPeer intent may do that.
    pub(crate) async fn ensure_business_path(
        state: Arc<Self>,
        peer_id: &str,
        command_id: &str,
        class: network_protocol::CommunicationClass,
        required_capabilities: u8,
    ) -> Result<SessionId, CoreNetworkError> {
        if let Some(session_id) = state.connection_sessions.current_session_id(peer_id).await {
            if state
                .acquire_path_lease(peer_id, required_capabilities)
                .await
                .is_ok()
            {
                return Ok(session_id);
            }
        }

        let supervisor = state.peer_supervisors.get_or_create(peer_id)?;
        let intent = state.peer_supervisors.start_business(
            Arc::clone(&state),
            peer_id,
            command_id.to_string(),
            class,
        )?;
        match intent.completion().await {
            Ok(Ok(crate::connect::PeerState::Online)) => {
                let session_id = state
                    .connection_sessions
                    .current_session_id(peer_id)
                    .await
                    .ok_or(CoreNetworkError::NoRoute)?;
                if state
                    .acquire_path_lease(peer_id, required_capabilities)
                    .await
                    .is_err()
                {
                    supervisor.path_lost();
                    return Err(CoreNetworkError::NoRoute);
                }
                Ok(session_id)
            }
            Ok(Ok(_)) | Ok(Err(CoreNetworkError::NoRoute)) => Err(CoreNetworkError::NoRoute),
            Ok(Err(error)) => Err(error),
            Err(_) => Err(CoreNetworkError::Cancelled),
        }
    }
}
