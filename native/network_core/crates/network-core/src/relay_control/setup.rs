use super::*;

/// 连接原生 Relay v2 控制面并启动事件消费者（§31 `RelayControlClient`）。
pub(crate) async fn configure_relay_for_state(
    state: Arc<RuntimeState>,
    command: ConfigureRelayCommand,
) -> Result<(), ProtocolError> {
    stop_relay_reconnect_task(&state).await;
    // 新的 ConfigureRelayCommand 携带新凭据，重置过期标记并清空旧配置。
    state
        .relay
        .credential_stale
        .store(false, std::sync::atomic::Ordering::Release);
    state.relay.config.write().await.take();
    disconnect_relay_data(state.as_ref()).await;
    let device_id = state
        .lifecycle
        .identity
        .read()
        .await
        .as_ref()
        .map(|identity| identity.device_id.clone())
        .ok_or_else(|| {
            protocol_error(
                NetworkErrorCode::InvalidArgument,
                "runtime must be configured before Relay",
            )
        })?;
    let signing_seed: [u8; 32] = command.relay_signing_seed.try_into().map_err(|_| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "Relay signing seed must contain 32 bytes",
        )
    })?;
    let config = RelayReconnectConfig {
        relay_url: command.relay_url,
        credential: command.relay_credential,
        signing_seed,
    };
    *state.relay.config.write().await = Some(config.clone());
    if let Err(error) = setup_v2_control_plane(&state, &device_id, &config).await {
        // 控制面 socket 未建立：发布类型化 Failed（不伪造 Connected），Dart 据此
        // 提示或重新下发 ConfigureRelayCommand（凭据过期/冲突时携带类型化错误）。
        crate::events::emit_relay_state(
            &state.event_tx,
            network_protocol::RelayConnectionState::Failed,
            Some(error.clone()),
        );
        return Err(error);
    }
    crate::events::emit_relay_state(
        &state.event_tx,
        network_protocol::RelayConnectionState::Connected,
        None,
    );
    // transport-network v2：控制连接建立后发布完整 Discovery Snapshot（§8/§9）。
    crate::discovery::spawn_control_connected(&state);
    Arc::clone(&state).resume_relay_transfers().await;
    Ok(())
}

/// transport-network v2：建立 `/v2/control` 控制面客户端并启动事件消费者。
///
/// 失败时返回类型化错误。凭据过期/身份冲突是终态错误：标记 `relay_credential_stale`
/// 并停止重连（现有 stale 守卫随后生效），等待 Dart 下发新 ConfigureRelayCommand 后
/// 恢复；其余传输错误仍走既有退避重连。
pub(crate) async fn setup_v2_control_plane(
    state: &Arc<RuntimeState>,
    device_id: &str,
    config: &RelayReconnectConfig,
) -> Result<(), ProtocolError> {
    let previous_ready_presence_ttl = state
        .relay
        .control
        .read()
        .await
        .as_ref()
        .and_then(|control| control.ready_presence_ttl());
    let mut control = match RelayControlClient::new(
        config.relay_url.clone(),
        device_id.to_string(),
        config.credential.clone(),
        config.signing_seed,
    ) {
        Ok(control) => control,
        Err(error) => {
            tracing::warn!(error = %error, "Relay v2 control client creation failed");
            return Err(relay_connect_protocol_error(&error, "setup_control_plane"));
        }
    };
    if let Err(error) = control.connect().await {
        tracing::warn!(error = %error, "Relay v2 control client connect failed");
        if matches!(
            error,
            RelayError::CredentialExpired(_) | RelayError::IdentityConflict(_)
        ) {
            // 终态认证错误：凭据已失效，盲目重连只会复用无效凭据；等待 Dart 下发
            // 新 ConfigureRelayCommand（configure 入口会重置该标记）。
            state
                .relay
                .credential_stale
                .store(true, std::sync::atomic::Ordering::Release);
        } else {
            schedule_relay_reconnect(Arc::clone(state));
        }
        return Err(relay_connect_protocol_error(&error, "setup_control_plane"));
    }
    let ready_presence_ttl = control.ready_presence_ttl();
    clear_remote_candidate_cache_if_ready_ttl_changed(
        state,
        previous_ready_presence_ttl,
        ready_presence_ttl,
    )
    .await;
    let events = control.take_events().map_err(|error| {
        tracing::warn!(error = %error, "Relay v2 control events were already consumed");
        relay_connect_protocol_error(&error, "setup_control_plane")
    })?;
    let control = Arc::new(control);
    *state.relay.control.write().await = Some(control.clone());
    let supervisor = Arc::clone(&state.task_supervisor);
    let state = Arc::clone(state);
    let _ = supervisor.spawn_runtime("relay-v2-control-events", async move {
        consume_control_events(state, control, events).await;
    });
    Ok(())
}

/// 消费 Relay v2 控制面异步事件（presence hints / inbound ConnectivityOffer /
/// IncomingRelayReservation / RealtimeSignal / Disconnected）。
pub(crate) async fn consume_control_events(
    state: Arc<RuntimeState>,
    control: Arc<RelayControlClient>,
    mut events: mpsc::Receiver<ControlEvent>,
) {
    while let Some(event) = events.recv().await {
        match event {
            ControlEvent::PresenceHintSnapshot(snapshot) => {
                for peer in &snapshot.peers {
                    if peer.online && peer.revision != 0 {
                        if let Some(epoch) = peer.runtime_epoch.as_ref() {
                            invalidate_remote_candidate_cache_for_epoch(
                                &state,
                                &peer.device_id,
                                epoch,
                            )
                            .await;
                        }
                    }
                }
                let online = snapshot
                    .peers
                    .iter()
                    .map(|peer| {
                        let generation = u64::from(peer.revision);
                        (peer.device_id.clone(), generation)
                    })
                    .collect::<Vec<_>>();
                let dropped = state.presence_hints.reconcile_snapshot(&online);
                for device_id in &dropped {
                    emit_peer_presence_changed(
                        &state.event_tx,
                        device_id,
                        0,
                        PeerPresenceState::Offline,
                    );
                }
                emit_peer_presence_snapshot(
                    &state.event_tx,
                    snapshot
                        .peers
                        .iter()
                        .map(|peer| PeerPresenceChangedEvent {
                            peer_id: peer.device_id.clone(),
                            generation: u64::from(peer.revision),
                            state: PeerPresenceState::Online as i32,
                        })
                        .collect(),
                );
            }
            ControlEvent::PeerAvailableHint(hint) => {
                if hint.revision != 0 {
                    if let Some(epoch) = hint.runtime_epoch.as_ref() {
                        invalidate_remote_candidate_cache_for_epoch(&state, &hint.device_id, epoch)
                            .await;
                    } else {
                        tracing::debug!(
                            peer_id = %hint.device_id,
                            revision = hint.revision,
                            "ignored available hint without runtime_epoch for candidate invalidation"
                        );
                    }
                } else {
                    tracing::debug!(
                        peer_id = %hint.device_id,
                        "ignored available hint with zero revision for candidate invalidation"
                    );
                }
                let generation = u64::from(hint.revision);
                state
                    .presence_hints
                    .mark_online(&hint.device_id, generation);
                emit_peer_presence_changed(
                    &state.event_tx,
                    &hint.device_id,
                    generation,
                    PeerPresenceState::Online,
                );
            }
            ControlEvent::PeerUnavailableHint(hint) => {
                state.presence_hints.mark_offline(&hint.device_id);
                emit_peer_presence_changed(
                    &state.event_tx,
                    &hint.device_id,
                    0,
                    PeerPresenceState::Offline,
                );
            }
            ControlEvent::ConnectivityOffer(offer) => {
                // 应答方视角（§14）：先回送 Answer，再在同一个 attempt window
                // 向 initiator_snapshot 中的候选发起认证检查；本端 accept loop
                // 同时继续接收发起方打进来的 QUIC Initial。
                if let Some(identity) = state.lifecycle.identity.read().await.clone() {
                    let (epoch, revision, snapshot) = local_discovery_tuple(&state).await;
                    let _ = control
                        .send_connectivity_answer(
                            &offer,
                            true,
                            &identity.device_id,
                            epoch,
                            revision,
                            snapshot,
                        )
                        .await;
                    spawn_responder_connectivity_checks(Arc::clone(&state), offer);
                }
            }
            ControlEvent::IncomingRelayReservation(reservation) => {
                // §25：应答方收到 reservation 后连接 /v2/relay/{reservation_id}，
                // 建立数据面客户端并启动事件循环（crypto 握手 + 文件/流/消息）。
                connect_incoming_relay_data(&state, reservation).await;
            }
            ControlEvent::RealtimeSignal(signal) => {
                // §17/§22：WebRTC 信令经 v2 Relay Control Plane；入站帧路由到
                // RealtimeManager 做 Offer/Answer/ICE 协商。
                if let Err(error) =
                    crate::realtime::handle_v2_realtime_signal(&state, &signal).await
                {
                    tracing::debug!(
                        realtime_id = %signal.realtime_id,
                        error = %error,
                        "rejected v2 WebRTC signaling control"
                    );
                }
            }
            ControlEvent::Disconnected { reason } => {
                tracing::debug!(reason, "Relay v2 control disconnected");
                // 意外断开：先取走控制面 sink 再调度重连，否则重连循环第一处守卫
                // （relay_control.is_some()）会立即 break——死 client 仍占位，
                // setup_v2_control_plane 永远不会被再次调用，Discovery / Resolve /
                // reserve_relay / Realtime 信令持续失效。
                state.relay.control.write().await.take();
                schedule_relay_reconnect(Arc::clone(&state));
                break;
            }
            _ => {}
        }
    }
}
