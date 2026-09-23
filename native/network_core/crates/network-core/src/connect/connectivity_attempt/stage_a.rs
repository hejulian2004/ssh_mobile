use super::*;

impl ConnectivityAttemptCoordinator {
    /// Run the frozen pure-direct Stage A.  The method returns `true` only after
    /// a route has been attached and registered; a failed race retires its
    /// temporary Session and lets the caller enter Stage B.
    pub(super) async fn try_stage_a_direct(
        &self,
        peer_id: &str,
        peer: &crate::runtime::PeerConfig,
        endpoint: quinn::Endpoint,
        identity: Arc<network_identity::DeviceIdentity>,
        capability: u8,
    ) -> Result<bool, ProtocolError> {
        if !self
            .state
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return Ok(false);
        }
        if self
            .state
            .has_ready_direct_path_for_capability(peer_id, capability)
            .await
        {
            return Ok(true);
        }

        let (candidates, remote_epoch) = {
            let caches = self.state.remote_candidate_cache.read().await;
            CandidateSnapshotPolicy::stage_a_direct_candidates(
                caches.get(peer_id),
                peer,
                Instant::now(),
            )
        };
        if candidates.is_empty() {
            return Ok(false);
        }

        let (session_id, owns_session) = match self
            .state
            .connection_sessions
            .current_session_id(peer_id)
            .await
        {
            Some(session_id) => (session_id, false),
            None => match self.state.begin_connect(peer_id, capability).await {
                ConnectDecision::Started(session_id) => (session_id, true),
                ConnectDecision::AlreadyConnected(session_id) => (session_id, false),
                ConnectDecision::CapabilityMismatch(_) => return Ok(false),
                ConnectDecision::InProgress(_) => return Ok(false),
            },
        };
        self.set_stage(ConnectivityAttemptState::DirectConnecting);
        let (candidate_update_tx, candidate_updates) = watch::channel(None);
        drop(candidate_update_tx);
        let attempt_id = new_attempt_id();
        let direct_result = tokio::time::timeout(
            STAGE_A_CONNECT_BUDGET,
            connect_direct_or_generic(DirectRouteAttempt {
                state: Arc::clone(&self.state),
                endpoint,
                candidates,
                identity,
                expected_peer_public_key: peer.identity_public_key,
                peer_id: peer_id.to_string(),
                session_binding: session_id.wire_key(),
                session_id,
                attempt_id,
                connect_window: STAGE_A_CONNECT_BUDGET,
                required_capabilities: capability,
                allow_websocket: capability == crate::connect::CAPABILITY_RELIABLE_MESSAGE,
                candidate_updates,
            }),
        )
        .await;
        match direct_result {
            Ok(Ok(route)) => {
                let admission = match self.attach_direct_route(peer_id, route).await {
                    Ok(admission) => admission,
                    Err(error) => {
                        if owns_session {
                            self.state.fail_session(peer_id, session_id).await;
                        }
                        return Err(error);
                    }
                };
                self.register_current(
                    Arc::clone(&self.state),
                    peer_id,
                    &remote_epoch,
                    admission.session_id,
                )
                .await;
                self.set_stage(ConnectivityAttemptState::ConnectedDirect);
                Ok(true)
            }
            Ok(Err(error)) => {
                if owns_session {
                    self.state.fail_session(peer_id, session_id).await;
                }
                tracing::debug!(peer_id = %peer_id, error = %error.message, "pure direct Stage A failed");
                Ok(false)
            }
            Err(_) => {
                if owns_session {
                    self.state.fail_session(peer_id, session_id).await;
                }
                tracing::debug!(peer_id = %peer_id, "pure direct Stage A window elapsed");
                Ok(false)
            }
        }
    }
}
