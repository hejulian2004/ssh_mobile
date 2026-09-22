use super::*;

impl ConnectivityAttemptCoordinator {
    /// Relay 回退：DIRECT_FAILED → RELAY_RESERVING → RELAY_CONNECTING → CONNECTED_RELAY。
    ///
    /// - RELAY_RESERVING（§25/§31）：经 v2 控制面 `reserve_relay` 请求 reservation。
    /// - RELAY_CONNECTING（§25）：连接 `/v2/relay/{reservation_id}` 数据面
    ///   （`RelayDataClient`），在其上完成 Relay E2EE 握手后挂载 ConnectionSession。
    pub(super) async fn connect_relay_fallback(
        &self,
        peer_id: &str,
        session_id: SessionId,
        peer: &crate::runtime::PeerConfig,
        attempt_id: &str,
        capability: u8,
        connect_deadline: Instant,
    ) -> Result<ConnectionAdmissionLease, ProtocolError> {
        let state = Arc::clone(&self.state);

        let reserve_budget = connect_deadline
            .saturating_duration_since(Instant::now())
            .min(RELAY_RESERVE_TIMEOUT);
        if reserve_budget.is_zero() {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "Relay reservation budget elapsed",
                "connect",
                peer_id,
            ));
        }

        // RELAY_RESERVING：reserve_relay 经 v2 控制面路由（§31 reserveRelay）。
        self.set_stage(ConnectivityAttemptState::RelayReserving);
        let reservation = {
            let control = state.relay.control.read().await.clone().ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::RelayError,
                    "Relay control plane is unavailable",
                    "connect",
                    peer_id,
                )
            })?;
            if !control.is_usable().await {
                return Err(protocol_error_with_peer(
                    NetworkErrorCode::RelayError,
                    "Relay control plane is not connected",
                    "connect",
                    peer_id,
                ));
            }
            match tokio::time::timeout(
                reserve_budget,
                control.reserve_relay(
                    attempt_id.to_string(),
                    peer_id.to_string(),
                    crate::connect::RELAY_RESERVATION_LIFETIME_S,
                ),
            )
            .await
            {
                Ok(Ok(reservation)) => {
                    tracing::debug!(
                        peer_id = %peer_id,
                        attempt_id = %attempt_id,
                        reservation_id = %reservation.reservation_id,
                        "relay reservation acquired"
                    );
                    reservation
                }
                Ok(Err(error)) => {
                    tracing::warn!(peer_id = %peer_id, error = %error, "relay reservation failed");
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::RelayError,
                        format!("Relay reservation failed: {error}"),
                        "connect",
                        peer_id,
                    ));
                }
                Err(_) => {
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::Timeout,
                        "Relay reservation timed out",
                        "connect",
                        peer_id,
                    ));
                }
            }
        };

        // RELAY_CONNECTING（§25）：连接 reservation 数据面并启动事件循环。
        self.set_stage(ConnectivityAttemptState::RelayConnecting);
        let data =
            match crate::relay::connect_initiator_relay_data(&state, peer_id, reservation).await {
                Ok(data) => data,
                Err(error) => {
                    state.fail_session(peer_id, session_id).await;
                    return Err(error);
                }
            };
        let crypto_identity = state
            .lifecycle
            .identity
            .read()
            .await
            .clone()
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::InvalidArgument,
                    "runtime identity is unavailable",
                    "connect",
                    peer_id,
                )
            })?;
        let (crypto, admission) = match crate::peer::establish_relay_crypto(
            &state,
            Arc::clone(&data),
            peer_id,
            session_id,
            crypto_identity,
            peer.identity_public_key,
        )
        .await
        {
            Ok(crypto) => crypto,
            Err(error) => {
                state.fail_session(peer_id, session_id).await;
                return Err(error);
            }
        };
        let session_id = admission.session_id;
        let relay_profile = crate::connection::ConnectionProfile::for_route(RouteType::Relay)
            .expect("Relay route has a composed profile");
        if !state
            .candidate_supports(peer_id, session_id, relay_profile, capability)
            .await
        {
            state
                .release_claimed_session(peer_id, session_id, &crypto.remote_session_binding)
                .await;
            return Err(protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "Relay route does not satisfy the requested capability",
                "connect",
                peer_id,
            ));
        }
        if install_admitted_crypto(&state, peer_id, &admission, &crypto)
            .await
            .is_err()
        {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                "Relay application E2EE handshake was not accepted",
                "connect",
                peer_id,
            ));
        }
        let attached = state
            .mark_relay_route_connected(peer_id, session_id, Some(data))
            .await;
        if !attached {
            state.crypto.remove_session(peer_id, &session_id.wire_key());
            return Err(protocol_error_with_peer(
                NetworkErrorCode::Cancelled,
                "Relay route completed after Session was closed",
                "connect",
                peer_id,
            ));
        }
        // PathHandshakeV2 may have completed while the Relay event loop was
        // still able to receive frames. Publish business admission only after
        // the initiator's Relay route is attached to its Session.
        state
            .relay
            .relay_path_ready
            .write()
            .await
            .insert(peer_id.to_string());
        emit_peer_state(
            &state.event_tx,
            peer_id,
            PeerConnectionState::Connected,
            RouteType::Relay,
            None,
        );
        crate::channel::recover_session(Arc::clone(&state), peer_id.to_string()).await;
        // §19：业务状态（Transfer）不属于 Session；每条新连接都尝试恢复暂停传输。
        crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.to_string()).await;
        Ok(admission)
    }
}
