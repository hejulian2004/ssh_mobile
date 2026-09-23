use super::*;

impl ConnectivityAttemptCoordinator {
    /// Direct 成功后挂载 Session（连接 Session 同生命周期，§18）。
    pub(crate) async fn attach_direct_route(
        &self,
        peer_id: &str,
        route: ConnectedRoute,
    ) -> Result<ConnectionAdmissionLease, ProtocolError> {
        let state = Arc::clone(&self.state);
        match route {
            ConnectedRoute::Quic {
                connection,
                crypto,
                admission,
            } => {
                let session_id = admission.session_id;
                let profile =
                    crate::connection::ConnectionProfile::for_route(RouteType::QuicDirect)
                        .expect("QUIC direct route has a composed profile");
                if !state
                    .candidate_supports_required(peer_id, session_id, profile)
                    .await
                {
                    connection.close(VarInt::from_u32(0), b"candidate lacks requested capability");
                    state
                        .release_claimed_session(
                            peer_id,
                            session_id,
                            &crypto.remote_session_binding,
                        )
                        .await;
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "QUIC route does not satisfy the requested capability",
                        "connect",
                        peer_id,
                    ));
                }
                if install_admitted_crypto(&state, peer_id, &admission, &crypto)
                    .await
                    .is_err()
                {
                    connection.close(VarInt::from_u32(0), b"application E2EE install failed");
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::AuthenticationFailed,
                        "application E2EE handshake was not accepted",
                        "connect",
                        peer_id,
                    ));
                }
                let _previous_route = match state
                    .attach_connection_for_session(
                        peer_id,
                        Some(session_id),
                        connection.clone(),
                        RouteType::QuicDirect,
                    )
                    .await
                {
                    Ok(previous_route) => previous_route,
                    Err(_) => {
                        state.crypto.remove_session(peer_id, &session_id.wire_key());
                        state
                            .release_claimed_session(
                                peer_id,
                                session_id,
                                &crypto.remote_session_binding,
                            )
                            .await;
                        return Err(protocol_error_with_peer(
                            NetworkErrorCode::Cancelled,
                            "connection completed after Session was closed",
                            "connect",
                            peer_id,
                        ));
                    }
                };
                if state.connection_sessions.current_session_id(peer_id).await != Some(session_id) {
                    state.crypto.remove_session(peer_id, &session_id.wire_key());
                    state
                        .release_claimed_session(
                            peer_id,
                            session_id,
                            &crypto.remote_session_binding,
                        )
                        .await;
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::Cancelled,
                        "connection completed after Session was closed",
                        "connect",
                        peer_id,
                    ));
                }
                emit_peer_state(
                    &state.event_tx,
                    peer_id,
                    PeerConnectionState::Connected,
                    RouteType::QuicDirect,
                    None,
                );
                emit_route_changed(
                    &state.event_tx,
                    peer_id,
                    RouteType::QuicDirect,
                    connection.remote_address(),
                    connection.rtt().as_millis().min(u32::MAX as u128) as u32,
                    0.0,
                );
                crate::channel::recover_session(Arc::clone(&state), peer_id.to_string()).await;
                // §19：业务状态（Transfer）不属于 Session；每条新连接都尝试恢复暂停传输
                // （ResumeTransfer(transfer_id)，按 transfer_id + peer_id 领取）。
                crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.to_string())
                    .await;
                crate::peer::ConnectionReceiverSupervisor::spawn_session_receivers(
                    Arc::clone(&state),
                    peer_id.to_string(),
                    connection,
                    session_id,
                );
                Ok(admission)
            }
            ConnectedRoute::Generic(generic) => {
                let mut scope = generic.scope;
                let profile = scope
                    .profile()
                    .expect("supervised GenericRoute scope has a profile");
                let admission = generic.admission;
                let session_id = admission.session_id;
                if !state
                    .candidate_supports_required(peer_id, session_id, profile)
                    .await
                {
                    scope.close().await;
                    state
                        .release_claimed_session(
                            peer_id,
                            session_id,
                            &generic.crypto.remote_session_binding,
                        )
                        .await;
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "generic route does not satisfy the requested capability",
                        "connect",
                        peer_id,
                    ));
                }
                if install_admitted_crypto(&state, peer_id, &admission, &generic.crypto)
                    .await
                    .is_err()
                {
                    scope.close().await;
                    state.fail_session(peer_id, session_id).await;
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::AuthenticationFailed,
                        "application E2EE handshake was not accepted",
                        "connect",
                        peer_id,
                    ));
                }
                let _previous_route = match state
                    .attach_generic_route_for_session(peer_id, Some(session_id), &mut scope)
                    .await
                {
                    Ok(previous_route) => previous_route,
                    Err(_) => {
                        scope.close().await;
                        state.crypto.remove_session(peer_id, &session_id.wire_key());
                        state
                            .release_claimed_session(
                                peer_id,
                                session_id,
                                &generic.crypto.remote_session_binding,
                            )
                            .await;
                        return Err(protocol_error_with_peer(
                            NetworkErrorCode::Cancelled,
                            "generic connection completed after Session was closed",
                            "connect",
                            peer_id,
                        ));
                    }
                };
                emit_peer_state_profile(
                    &state.event_tx,
                    peer_id,
                    PeerConnectionState::Connected,
                    Some(profile),
                    None,
                );
                emit_route_changed_profile(
                    &state.event_tx,
                    peer_id,
                    Some(profile),
                    generic.endpoint,
                    0,
                    0.0,
                );
                crate::channel::recover_session(Arc::clone(&state), peer_id.to_string()).await;
                crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.to_string())
                    .await;
                Ok(admission)
            }
        }
    }
}
