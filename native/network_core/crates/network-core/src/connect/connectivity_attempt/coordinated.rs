use super::*;

impl ConnectivityAttemptCoordinator {
    pub(super) async fn connect_after_preflight<'a>(
        &self,
        request: CoordinatedConnectContext<'a>,
    ) -> Result<(), ProtocolError> {
        let CoordinatedConnectContext {
            peer_id,
            capability,
            command_id,
            connect_deadline,
            state,
            endpoint,
            identity,
            peer,
            authorization,
            control,
            ready_presence_ttl,
            local_epoch,
            local_revision,
            local_snapshot,
        } = request;

        // Reserve the local ConnectionSession before the atomic Resolve → Offer
        // transaction.  ConnectivityOffer carries no target, so every request
        // that reaches the Offer boundary must already have a local attempt
        // owner; reuse and concurrent-admission decisions must return before it.
        // A concurrent connect is observed rather than merged into the local
        // attempt. If that admission becomes stale or cannot retry, perform
        // one fresh ownership/Stage-B evaluation before returning failure.
        let mut re_evaluated_in_progress = false;
        let session_id = loop {
            match state.begin_connect(peer_id, capability).await {
                ConnectDecision::AlreadyConnected(session_id) => {
                    self.finish_reuse(peer_id, session_id).await;
                    return Ok(());
                }
                ConnectDecision::CapabilityMismatch(_) => {
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "existing connection does not satisfy this path capability",
                        "connect",
                        peer_id,
                    ));
                }
                ConnectDecision::Started(session_id) => break session_id,
                ConnectDecision::InProgress(session_id) => {
                    // Do not merge this request into Session state. Wait for
                    // the existing attempt, then evaluate this request against
                    // the route it actually produced. This branch is before
                    // Resolve/Offer, so it cannot orphan a coordination ticket.
                    let retry_admission = loop {
                        let changed = state.path_change_notified();
                        tokio::pin!(changed);
                        if state.connection_sessions.current_session_id(peer_id).await
                            != Some(session_id)
                        {
                            break true;
                        }
                        if state.path_is_connected(peer_id).await {
                            let supported =
                                state.path_supports_capability(peer_id, capability).await;
                            if !supported {
                                return Err(protocol_error_with_peer(
                                    NetworkErrorCode::NoRoute,
                                    "existing route does not satisfy this path capability",
                                    "connect",
                                    peer_id,
                                ));
                            }
                            self.finish_reuse(peer_id, session_id).await;
                            return Ok(());
                        }
                        if !state
                            .path_admission_can_retry(peer_id, Some(session_id))
                            .await
                        {
                            break true;
                        }
                        if Instant::now() >= connect_deadline {
                            return Err(protocol_error_with_peer(
                                NetworkErrorCode::Timeout,
                                "shared connection attempt exceeded the connect budget",
                                "connect",
                                peer_id,
                            ));
                        }
                        changed.await;
                    };
                    if retry_admission && !re_evaluated_in_progress {
                        re_evaluated_in_progress = true;
                        continue;
                    }
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "shared connection attempt did not produce a route",
                        "connect",
                        peer_id,
                    ));
                }
            }
        };
        let mut session_cleanup = SessionCleanupGuard::new(Arc::clone(&state), peer_id, session_id);

        self.set_stage(ConnectivityAttemptState::Resolving);
        let (attempt_id, coordination) = match self
            .begin_stage_b_transaction(
                Arc::clone(&control),
                StageBTransactionRequest {
                    peer_id: peer_id.to_string(),
                    initiator_device_id: identity.device_id.clone(),
                    initiator_runtime_epoch: local_epoch.clone(),
                    initiator_revision: local_revision,
                    initiator_snapshot: local_snapshot,
                    connect_deadline,
                },
            )
            .await
        {
            Ok(result) => result,
            Err(error) => {
                state.fail_session(peer_id, session_id).await;
                return Err(error);
            }
        };
        let resolved = match ConnectivityStageEligibility::ready_peer_from_coordination(
            &coordination.resolved,
            peer_id,
        ) {
            Ok(resolved) => resolved,
            Err(error) => {
                state.fail_session(peer_id, session_id).await;
                return Err(error);
            }
        };
        self.set_stage(ConnectivityAttemptState::Resolved);
        CandidateSnapshotPolicy::update_remote_candidate_cache(
            &state,
            peer_id,
            CandidateSnapshotPolicy::resolved_snapshot(&resolved),
            ready_presence_ttl,
        )
        .await;

        let remote_epoch = CandidateSnapshotPolicy::resolved_runtime_epoch(&resolved);

        // Resolve remains authoritative for epoch/index reconciliation, but
        // the Offer is already committed and this coordinator owns a fresh
        // local Session. Never turn this point back into a reuse return path.
        if let Some(obsolete) = state
            .ready_session_index
            .take_obsolete(peer_id, &remote_epoch)
        {
            tracing::info!(
                peer_id = %peer_id,
                session = ?obsolete.session_id,
                "remote runtime epoch changed; retiring obsolete ready index entry"
            );
            // `Started(session_id)` means the current admission was empty when
            // ownership was acquired. Retire only an exact stale admission if
            // one still exists; do not close the current path or invalidate the
            // PeerSupervisor that owns this coordinator.
            if obsolete.session_id != session_id {
                state
                    .retire_session_without_transport(peer_id, obsolete.session_id)
                    .await;
            }
        }

        // -----------------------------------------------------------------
        // 2. Create ConnectivityAttempt（§12）+ COORDINATING（§14）。
        // -----------------------------------------------------------------
        self.set_stage(ConnectivityAttemptState::Coordinating);
        // 一次性 ConnectivityAttempt（§12）：candidate 完全 attempt-scoped。
        // - `local_candidates`：本端已 gather 的候选（用于信令/供对端直连）。
        // - `remote_candidates`：Resolve 返回的对端候选（§14 服务器附带 A 当前
        //   Discovery 给 B）+ 手工配置 endpoint。
        // Direct 的**连接目标**是 remote_candidates；本端候选绝不加入连接目标。
        let attempt_started_at = SystemTime::now();
        let mut attempt = ConnectivityAttempt::with_connect_window(
            attempt_id.clone(),
            peer_id.to_string(),
            CandidateSnapshotPolicy::nat_runtime_epoch(&local_epoch),
            attempt_started_at,
            DIRECT_CONNECT_WINDOW,
        )
        .with_local_candidates(
            CandidateSnapshotPolicy::collect_local_candidates(state.clone()).await,
        );
        let initial_remote_candidates =
            CandidateSnapshotPolicy::resolved_candidates(&resolved, &peer);
        if let Err(error) = attempt.apply_remote_candidates(
            CandidateSnapshotPolicy::resolved_snapshot(&resolved).and_then(|snapshot| {
                snapshot
                    .runtime_epoch
                    .as_ref()
                    .map(CandidateSnapshotPolicy::nat_runtime_epoch)
            }),
            CandidateSnapshotPolicy::resolved_snapshot(&resolved)
                .map(|snapshot| u64::from(snapshot.revision))
                .unwrap_or(0),
            initial_remote_candidates,
        ) {
            state.fail_session(peer_id, session_id).await;
            return Err(protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                format!("invalid remote candidate snapshot: {error}"),
                "connect",
                peer_id,
            ));
        }
        let _ = attempt.set_state(network_nat::ConnectivityAttemptState::Resolved);
        let preserved_direct_candidates = attempt
            .remote_candidates()
            .iter()
            .filter(|candidate| candidate.interface_name == "peer-configured")
            .cloned()
            .collect::<Vec<_>>();
        let attempt = Arc::new(Mutex::new(attempt));
        {
            let mut attempt_state = attempt.lock().await;
            let _ = attempt_state.set_state(network_nat::ConnectivityAttemptState::Coordinating);
        }

        // 发 offer 的异步任务：不阻塞 Direct 窗口（§14 双方 simultaneous checks）。
        let candidate_updates = match self.spawn_coordination(
            coordination,
            peer_id.to_string(),
            attempt_id.clone(),
            Arc::clone(&attempt),
            preserved_direct_candidates,
            ready_presence_ttl,
        ) {
            Ok(candidate_updates) => candidate_updates,
            Err(error) => {
                state.fail_session(peer_id, session_id).await;
                return Err(error);
            }
        };
        let remote_candidates = attempt.lock().await.remote_candidates().to_vec();
        let _ = attempt
            .lock()
            .await
            .set_state(network_nat::ConnectivityAttemptState::Connecting);

        // -----------------------------------------------------------------
        // 5. DIRECT_CONNECTING（§15）：Direct First 4s。
        // -----------------------------------------------------------------
        self.set_stage(ConnectivityAttemptState::DirectConnecting);
        let direct_result = tokio::time::timeout(
            DIRECT_CONNECT_WINDOW,
            connect_direct_or_generic(DirectRouteAttempt {
                state: Arc::clone(&state),
                endpoint,
                candidates: remote_candidates,
                identity,
                expected_peer_public_key: peer.identity_public_key,
                peer_id: peer_id.to_string(),
                session_binding: session_id.wire_key(),
                session_id,
                attempt_id: attempt_id.clone(),
                connect_window: DIRECT_CONNECT_WINDOW,
                required_capabilities: capability,
                allow_websocket: capability == crate::connect::CAPABILITY_RELIABLE_MESSAGE,
                candidate_updates,
            }),
        )
        .await;

        let route = match direct_result {
            Ok(Ok(route)) => Ok(route),
            Ok(Err(error)) => {
                tracing::debug!(
                    peer_id = %peer_id,
                    attempt_id = %attempt_id,
                    error = %error.message,
                    "direct first failed; falling back to relay"
                );
                Err(error)
            }
            Err(_) => {
                tracing::debug!(
                    peer_id = %peer_id,
                    attempt_id = %attempt_id,
                    "direct first window elapsed; falling back to relay"
                );
                Err(protocol_error_with_peer(
                    NetworkErrorCode::Timeout,
                    "Direct connect window elapsed",
                    "connect",
                    peer_id,
                ))
            }
        };

        match route {
            // Direct 成功：挂载 Session → CONNECTED_DIRECT。
            Ok(route) => {
                let _ = attempt
                    .lock()
                    .await
                    .set_state(network_nat::ConnectivityAttemptState::Succeeded);
                let admission = match self.attach_direct_route(peer_id, route).await {
                    Ok(admission) => admission,
                    Err(error) => {
                        state.fail_session(peer_id, session_id).await;
                        return Err(error);
                    }
                };
                let final_remote_epoch = attempt
                    .lock()
                    .await
                    .remote_runtime_epoch()
                    .map(CandidateSnapshotPolicy::runtime_epoch_from_nat)
                    .or_else(|| remote_epoch.clone());
                self.register_current(
                    Arc::clone(&state),
                    peer_id,
                    &final_remote_epoch,
                    admission.session_id,
                )
                .await;
                self.set_stage(ConnectivityAttemptState::ConnectedDirect);
                session_cleanup.disarm();
                Ok(())
            }
            // Direct 失败：DIRECT_FAILED → RELAY_RESERVING → RELAY_CONNECTING（§15/§37）。
            Err(direct_error) => {
                let _ = attempt
                    .lock()
                    .await
                    .set_state(network_nat::ConnectivityAttemptState::Expired);
                self.set_stage(ConnectivityAttemptState::DirectFailed);
                if let Some(command_id) = command_id {
                    emit_route_attempt_changed(
                        &state.event_tx,
                        peer_id,
                        &attempt_id,
                        command_id,
                        RouteAttemptPhase::DirectFailed,
                        RouteType::QuicDirect,
                        Some(direct_error.clone()),
                    );
                }
                if !authorization.is_some_and(|authorization| authorization.relay) {
                    state.fail_session(peer_id, session_id).await;
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "relay route is not authorized",
                        "connect",
                        peer_id,
                    ));
                }
                if !ConnectivityStageEligibility::relay_fallback_is_eligible(
                    &resolved,
                    capability,
                    peer.e2ee_policy,
                    connect_deadline,
                ) {
                    state.fail_session(peer_id, session_id).await;
                    return Err(direct_error);
                }
                if let Some(command_id) = command_id {
                    emit_route_attempt_changed(
                        &state.event_tx,
                        peer_id,
                        &attempt_id,
                        command_id,
                        RouteAttemptPhase::RelayFallbackStarted,
                        RouteType::Relay,
                        Some(direct_error.clone()),
                    );
                }
                match self
                    .connect_relay_fallback(
                        peer_id,
                        session_id,
                        &peer,
                        &attempt_id,
                        capability,
                        connect_deadline,
                    )
                    .await
                {
                    Ok(admission) => {
                        if let Some(command_id) = command_id {
                            emit_route_attempt_changed(
                                &state.event_tx,
                                peer_id,
                                &attempt_id,
                                command_id,
                                RouteAttemptPhase::RelayConnected,
                                RouteType::Relay,
                                None,
                            );
                        }
                        let final_remote_epoch = attempt
                            .lock()
                            .await
                            .remote_runtime_epoch()
                            .map(CandidateSnapshotPolicy::runtime_epoch_from_nat)
                            .or_else(|| remote_epoch.clone());
                        self.register_current(
                            Arc::clone(&state),
                            peer_id,
                            &final_remote_epoch,
                            admission.session_id,
                        )
                        .await;
                        self.set_stage(ConnectivityAttemptState::ConnectedRelay);
                        session_cleanup.disarm();
                        Ok(())
                    }
                    Err(relay_error) => {
                        if let Some(command_id) = command_id {
                            emit_route_attempt_changed(
                                &state.event_tx,
                                peer_id,
                                &attempt_id,
                                command_id,
                                RouteAttemptPhase::RelayFailed,
                                RouteType::Relay,
                                Some(relay_error.clone()),
                            );
                        }
                        state.fail_session(peer_id, session_id).await;
                        tracing::warn!(
                            peer_id = %peer_id,
                            relay_error = %relay_error.message,
                            "Relay fallback failed; reporting the direct error"
                        );
                        // §40：direct timeout + relay failure → 报告 Direct 错误。
                        Err(direct_error)
                    }
                }
            }
        }
    }
}
