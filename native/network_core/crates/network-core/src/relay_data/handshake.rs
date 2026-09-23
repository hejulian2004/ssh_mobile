use super::*;

/// 处理一条数据面 crypto 信封（应答方或等待中的发起方）。
pub(crate) async fn handle_relay_crypto_handshake(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
    session_token: &str,
    peer_id: &str,
    frame_bytes: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if session_token.len() != 32
        || !session_token
            .bytes()
            .all(|value| value.is_ascii_hexdigit() && !value.is_ascii_uppercase())
        || peer_id.is_empty()
        || !state.peers.read().await.contains_key(peer_id)
        || !state
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Relay)
            .await
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay E2EE handshake is not bound to a registered peer",
        )
        .into());
    }
    if state.e2ee_policy(peer_id).await
        != crate::crypto_handshake::path_handshake::E2eePolicy::Required
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay paths require application E2EE",
        )
        .into());
    }
    let key = relay_crypto_key(peer_id, session_token);
    let (step, payload) = crate::crypto_handshake::decode_relay_frame(frame_bytes)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string()))?;
    match step {
        crate::crypto_handshake::RELAY_CRYPTO_RESPONSE
        | crate::crypto_handshake::RELAY_CRYPTO_ROOT_SEED
        | crate::crypto_handshake::RELAY_CRYPTO_ACCEPT => {
            let sender = state
                .relay
                .crypto_waiters
                .read()
                .await
                .get(&key)
                .cloned()
                .ok_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "Relay E2EE response has no active initiator state",
                    )
                })?;
            sender.send((step, payload.to_vec())).await.map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "Relay E2EE initiator is no longer waiting",
                )
            })?;
        }
        crate::crypto_handshake::RELAY_CRYPTO_HELLO => {
            state.relay.crypto_confirmers.lock().await.remove(&key);
            let identity = state
                .lifecycle
                .identity
                .read()
                .await
                .clone()
                .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?;
            let (responder, response) =
                crate::crypto_handshake::RelayResponderHandshake::accept_hello(identity, payload)
                    .map_err(|error| {
                    std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string())
                })?;
            let mut responders = state.relay.crypto_responders.lock().await;
            if responders.len() >= MAX_PENDING_RELAY_CRYPTO_HANDSHAKES
                && !responders.contains_key(&key)
            {
                return Err(std::io::Error::other("Relay E2EE responder queue is full").into());
            }
            responders.insert(key, responder);
            drop(responders);
            let response = crate::crypto_handshake::encode_relay_frame(
                crate::crypto_handshake::RELAY_CRYPTO_RESPONSE,
                &response,
            )
            .map_err(|error| {
                std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string())
            })?;
            // 用原始 frame 编码回传（data 侧负责加 token 前缀）。
            send_relay_crypto_raw(data, session_token, &response).await?;
        }
        crate::crypto_handshake::RELAY_CRYPTO_FINAL => {
            let responder = state
                .relay
                .crypto_responders
                .lock()
                .await
                .remove(&key)
                .ok_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "Relay E2EE final message has no active responder",
                    )
                })?;
            let binding_state = Arc::clone(state);
            let (authenticated_peer_id, confirmer, encrypted_seed) = responder
                .accept_final(
                    payload,
                    &state.trusted_peer_keys,
                    move |authenticated_peer_id, remote_session_binding| {
                        let binding_state = Arc::clone(&binding_state);
                        let authenticated_peer_id = authenticated_peer_id.to_string();
                        let remote_session_binding = remote_session_binding.to_string();
                        async move {
                            let admission = binding_state
                                .admit_authenticated_session(
                                    &authenticated_peer_id,
                                    None,
                                    &remote_session_binding,
                                )
                                .await
                                .map_err(|_| {
                                    crate::crypto_handshake::CryptoHandshakeError::Failed
                                })?;
                            Ok((admission.session_id.wire_key(), admission))
                        }
                    },
                )
                .await
                .map_err(|error| {
                    std::io::Error::new(std::io::ErrorKind::PermissionDenied, error.to_string())
                })?;
            if authenticated_peer_id != peer_id {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "Relay E2EE identity does not match the routed peer",
                )
                .into());
            }
            let mut confirmers = state.relay.crypto_confirmers.lock().await;
            if confirmers.len() >= MAX_PENDING_RELAY_CRYPTO_HANDSHAKES
                && !confirmers.contains_key(&key)
            {
                return Err(std::io::Error::other("Relay E2EE confirmer queue is full").into());
            }
            confirmers.insert(key, confirmer);
            drop(confirmers);
            let root_seed = crate::crypto_handshake::encode_relay_frame(
                crate::crypto_handshake::RELAY_CRYPTO_ROOT_SEED,
                &encrypted_seed,
            )
            .map_err(|error| {
                std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string())
            })?;
            send_relay_crypto_raw(data, session_token, &root_seed).await?;
        }
        crate::crypto_handshake::RELAY_CRYPTO_ROOT_CONFIRM => {
            let confirmer = state
                .relay
                .crypto_confirmers
                .lock()
                .await
                .remove(&key)
                .ok_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "Relay E2EE confirmation has no authenticated responder",
                    )
                })?;
            let (authenticated_peer_id, encrypted_accept, material, admission) =
                confirmer.accept_root_confirm(payload).map_err(|error| {
                    std::io::Error::new(std::io::ErrorKind::PermissionDenied, error.to_string())
                })?;
            if authenticated_peer_id != peer_id {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "Relay E2EE confirmation identity does not match the routed peer",
                )
                .into());
            }
            let accept = crate::crypto_handshake::encode_relay_frame(
                crate::crypto_handshake::RELAY_CRYPTO_ACCEPT,
                &encrypted_accept,
            )
            .map_err(|error| {
                std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string())
            })?;
            send_relay_crypto_raw(data, session_token, &accept).await?;
            // Root/Accept is the complete authenticated Relay admission
            // boundary.  PathHandshakeV2 metadata/proof was already bound to
            // this Noise transcript; no pending responder or second frame is
            // allowed to become a business gate.
            complete_relay_admission(state, data, session_token, peer_id, material, admission)
                .await?;
        }
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "unsupported Relay E2EE handshake step",
            )
            .into());
        }
    }
    Ok(())
}

/// Commits the responder after the authenticated Noise Root/Accept exchange.
/// The reservation PairReady gate is owned by RelayDataClient; PathHandshakeV2
/// metadata/proof is transcript-bound inside Noise and never creates a second
/// pending responder or business admission queue.
pub(crate) async fn complete_relay_admission(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
    session_token: &str,
    peer_id: &str,
    material: SessionCryptoMaterial,
    admission: ConnectionAdmissionLease,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let session_id = admission.session_id;
    if state.e2ee_policy(peer_id).await
        != crate::crypto_handshake::path_handshake::E2eePolicy::Required
        || material.e2ee_policy != crate::crypto_handshake::path_handshake::E2eePolicy::Required
    {
        state.fail_session(peer_id, session_id).await;
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay application E2EE policy is not Required",
        )
        .into());
    }
    if material.local_session_binding != session_id.wire_key()
        || material.remote_session_binding != session_token
    {
        state.fail_session(peer_id, session_id).await;
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay E2EE Session/token binding is invalid",
        )
        .into());
    }
    let relay_profile = crate::connection::ConnectionProfile::for_route(RouteType::Relay)
        .expect("Relay route has a composed profile");
    if !state
        .candidate_supports(
            peer_id,
            session_id,
            relay_profile,
            crate::connect::DEFAULT_CONNECTION_CAPABILITY,
        )
        .await
    {
        state.fail_session(peer_id, session_id).await;
        return Err(std::io::Error::other(
            "Relay route no longer satisfies the requested capability",
        )
        .into());
    }
    if state
        .connection_sessions
        .finalize_authenticated_session(peer_id, session_id, &material.remote_session_binding)
        .await
        .is_err()
    {
        state.fail_session(peer_id, session_id).await;
        return Err(std::io::Error::other(
            "Relay Session admission became stale before route commit",
        )
        .into());
    }
    crate::peer::install_admitted_crypto(state, peer_id, &admission, &material).await?;
    if !state
        .mark_relay_route_connected(peer_id, session_id, Some(Arc::clone(data)))
        .await
    {
        state.crypto.remove_session(peer_id, &session_id.wire_key());
        state.fail_session(peer_id, session_id).await;
        return Err(std::io::Error::new(
            std::io::ErrorKind::Interrupted,
            "Relay Session was closed before route commit",
        )
        .into());
    }
    state
        .relay
        .relay_path_ready
        .write()
        .await
        .insert(peer_id.to_string());
    crate::events::emit_peer_state(
        &state.event_tx,
        peer_id,
        network_protocol::PeerConnectionState::Connected,
        RouteType::Relay,
        None,
    );
    crate::channel::recover_session(Arc::clone(state), peer_id.to_string()).await;
    // §19：业务状态（Transfer）不属于 Session；每条新连接都尝试恢复暂停传输。
    Arc::clone(state)
        .resume_transfers_for_peer(peer_id.to_string())
        .await;
    Ok(())
}
