use super::*;

/// 应答方收到 `IncomingRelayReservation` 后连接数据面并启动事件循环。
pub(crate) async fn connect_incoming_relay_data(
    state: &Arc<RuntimeState>,
    reservation: network_relay::v2::IncomingRelayReservation,
) {
    if !state
        .route_is_authorized(
            &reservation.initiator_device_id,
            crate::connection::RouteTopology::Relay,
        )
        .await
    {
        tracing::debug!(
            peer_id = %reservation.initiator_device_id,
            reservation_id = %reservation.reservation_id,
            "ignored inbound Relay reservation without peer authorization"
        );
        return;
    }
    let Some(config) = state.relay.config.read().await.clone() else {
        tracing::warn!("incoming relay reservation arrived without a Relay config");
        return;
    };
    let mut data = match RelayDataClient::new(
        reservation.relay_data_endpoint.clone(),
        reservation.reservation_id.clone(),
        reservation.local_token.clone(),
        config.credential.clone(),
        config.signing_seed,
    ) {
        Ok(data) => data,
        Err(error) => {
            tracing::warn!(error = %error, "Relay v2 data client creation failed");
            return;
        }
    };
    if let Err(error) = data.connect_reservation().await {
        tracing::warn!(error = %error, "Relay v2 data client connect failed");
        return;
    }
    let events = match data.take_events() {
        Ok(events) => events,
        Err(error) => {
            tracing::warn!(error = %error, "Relay v2 data events were already consumed");
            return;
        }
    };
    let peer_id = reservation.initiator_device_id.clone();
    let data = Arc::new(data);
    // A newly paired reservation must pass through Noise/E2EE before any
    // business envelope is admitted.  Clear the peer-level projection before
    // replacing the reservation so a stale data client cannot open this one.
    state.relay.relay_path_ready.write().await.remove(&peer_id);
    let supervisor = Arc::clone(&state.task_supervisor);
    let state = Arc::clone(state);
    let _ = supervisor.spawn_runtime("relay-data-events", async move {
        handle_relay_data_events(state, data, events, peer_id).await;
    });
    tracing::info!(
        peer_id = %reservation.initiator_device_id,
        reservation_id = %reservation.reservation_id,
        "relay v2 data plane connected (responder)"
    );
}

/// 建立 reservation 数据面客户端（发起方）并返回事件接收器。
pub(crate) async fn connect_initiator_relay_data(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    reservation: network_relay::v2::RelayReserveResponse,
) -> Result<Arc<RelayDataClient>, ProtocolError> {
    let config = state.relay.config.read().await.clone().ok_or_else(|| {
        protocol_error_with_context(
            NetworkErrorCode::RelayError,
            "Relay is not configured",
            "relay_data_connect",
            None,
        )
    })?;
    let mut data = RelayDataClient::new(
        reservation.relay_data_endpoint,
        reservation.reservation_id,
        reservation.local_token,
        config.credential,
        config.signing_seed,
    )
    .map_err(|error| {
        protocol_error_with_context(
            NetworkErrorCode::RelayError,
            error.to_string(),
            "relay_data_connect",
            None,
        )
    })?;
    data.connect_reservation().await.map_err(|error| {
        protocol_error_with_context(
            NetworkErrorCode::RelayError,
            error.to_string(),
            "relay_data_connect",
            None,
        )
    })?;
    let events = data.take_events().map_err(|error| {
        protocol_error_with_context(
            NetworkErrorCode::RelayError,
            error.to_string(),
            "relay_data_connect",
            None,
        )
    })?;
    let data = Arc::new(data);
    // PairReady belongs to this reservation.  Do not let readiness from a
    // previous reservation authorize business data on the new data client.
    state.relay.relay_path_ready.write().await.remove(peer_id);
    let supervisor = Arc::clone(&state.task_supervisor);
    let state = Arc::clone(state);
    let peer_id = peer_id.to_string();
    let data_for_loop = Arc::clone(&data);
    let _ = supervisor.spawn_runtime("relay-data-events", async move {
        handle_relay_data_events(state, data_for_loop, events, peer_id).await;
    });
    Ok(data)
}

/// 消费 reservation 数据面事件，按信封类型分派到业务处理。
pub(crate) async fn handle_relay_data_events(
    state: Arc<RuntimeState>,
    data: Arc<RelayDataClient>,
    mut events: mpsc::Receiver<DataEvent>,
    peer_id: String,
) {
    while let Some(event) = events.recv().await {
        match event {
            DataEvent::Payload {
                encrypted_payload, ..
            } => {
                if let Err(error) =
                    handle_relay_data_payload(&state, &data, &peer_id, &encrypted_payload).await
                {
                    tracing::debug!(
                        peer_id = %peer_id,
                        error = %error,
                        "rejected relay v2 data envelope"
                    );
                }
            }
            DataEvent::Ack { .. } => {
                // 流控回执：当前文件发送路径不使用显式 Ack 门控，静默忽略。
            }
            DataEvent::Close { reason, detail } => {
                tracing::debug!(peer_id = %peer_id, reason, detail, "relay v2 data closed");
                break;
            }
            DataEvent::Disconnected { reason } => {
                tracing::debug!(peer_id = %peer_id, reason, "relay v2 data disconnected");
                break;
            }
        }
    }
    relay_data_disconnected(state, data, peer_id).await;
}

/// 数据面断开：移除该对端的 reservation 数据客户端并暂停 Relay 传输；会话侧由
/// route 丢失统一处理。只清理断开对端的条目，其他对端的活跃数据连接不受影响。
pub(crate) async fn relay_data_disconnected(
    state: Arc<RuntimeState>,
    data: Arc<RelayDataClient>,
    peer_id: String,
) {
    // The peer path owner is the sole owner of an admitted Relay data client.
    // A close event from a pre-admission/stale client must not tear down a
    // different current route.
    if !state.path_is_current_relay_data(&peer_id, &data).await {
        return;
    }
    // 只清理断开对端的 Relay 状态；其他对端的在途传输原样保留。
    cleanup_relay_state(&state, Some(&peer_id)).await;
    // §18/§35：transport 丢失即销毁 ConnectionSession（Relay route 由其数据客户端
    // 断开驱动）。显式 close 会 emit Disconnected。
    crate::peer::ConnectionReceiverSupervisor::teardown_relay_route(&state, &peer_id, &data).await;
}

pub(crate) fn relay_crypto_key(peer_id: &str, session_token: &str) -> String {
    format!("{peer_id}/{session_token}")
}

/// 清理一次 Relay 数据面断开，但保留可由新连接继续使用的业务状态。
///
/// `TransferManager` 和稳定 `.part` 属于 TransferSession，不属于 Relay 数据面；这里
/// 只丢弃等待中的 oneshot 和打开的文件句柄，绝不取消传输或删除 checkpoint。
/// `peer` 为 `Some` 时只清理该对端的条目（单条 reservation 断开），`None` 表示全部
/// （disconnect_relay_data 断开所有 reservation）。
pub(crate) async fn cleanup_relay_state(state: &RuntimeState, peer: Option<&str>) {
    // relay_active_incoming：按 offer.sender_id 只暂停断开对端的接收传输，其余对端
    // 的活跃接收保持原样。
    let active_ids = {
        let active = state.relay.active_incoming.lock().await;
        match peer {
            Some(peer) => active
                .iter()
                .filter(|(_, incoming)| incoming.offer.sender_id == peer)
                .map(|(transfer_id, _)| transfer_id.clone())
                .collect::<Vec<_>>(),
            None => active.keys().cloned().collect::<Vec<_>>(),
        }
    };
    for transfer_id in active_ids {
        let incoming = state
            .relay
            .active_incoming
            .lock()
            .await
            .remove(&transfer_id);
        if let Some(incoming) = incoming {
            drop(incoming.file);
            if state.transfer.manager.pause_for_network(&transfer_id).await {
                tracing::debug!(
                    transfer_id = %transfer_id,
                    "Relay incoming transfer paused; preserving checkpoint"
                );
            }
        }
    }

    // acceptances/completions 以 transfer_id 为键；按 TransferManager 的 peer 归属
    // 过滤，绝不清掉其他对端的等待者（None = 全部清空）。
    let mut waiter_ids = {
        let mut ids = Vec::new();
        ids.extend(state.relay.acceptances.read().await.keys().cloned());
        ids.extend(state.relay.completions.read().await.keys().cloned());
        ids
    };
    waiter_ids.sort_unstable();
    waiter_ids.dedup();
    if let Some(peer) = peer {
        // 逐条查询 TransferManager 的 peer 归属（snapshot 是 async，不能放在
        // 同步 retain 闭包里）。
        let mut scoped = Vec::new();
        for transfer_id in &waiter_ids {
            if state
                .transfer
                .manager
                .snapshot(transfer_id)
                .await
                .is_some_and(|snapshot| snapshot.peer_id == peer)
            {
                scoped.push(transfer_id.clone());
            }
        }
        waiter_ids = scoped;
    }
    for transfer_id in &waiter_ids {
        state.relay.acceptances.write().await.remove(transfer_id);
        state.relay.completions.write().await.remove(transfer_id);
    }

    // crypto waiters/responders/confirmers 的键是 "{peer_id}/{token}"：按对端前缀清理。
    let crypto_prefix = peer.map(|peer| format!("{peer}/"));
    {
        let mut waiters = state.relay.crypto_waiters.write().await;
        if let Some(prefix) = &crypto_prefix {
            waiters.retain(|key, _| !key.starts_with(prefix.as_str()));
        } else {
            waiters.clear();
        }
    }
    {
        let mut responders = state.relay.crypto_responders.lock().await;
        if let Some(prefix) = &crypto_prefix {
            responders.retain(|key, _| !key.starts_with(prefix.as_str()));
        } else {
            responders.clear();
        }
    }
    {
        let mut confirmers = state.relay.crypto_confirmers.lock().await;
        if let Some(prefix) = &crypto_prefix {
            confirmers.retain(|key, _| !key.starts_with(prefix.as_str()));
        } else {
            confirmers.clear();
        }
    }
    if let Some(peer) = peer {
        state.relay.relay_path_ready.write().await.remove(peer);
    } else {
        state.relay.relay_path_ready.write().await.clear();
    }
}
