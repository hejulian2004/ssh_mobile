use super::*;

/// 断开原生 Relay 数据面客户端，并发布类型化最终状态。
pub(crate) async fn disconnect_relay(state: &RuntimeState) -> Result<(), ProtocolError> {
    stop_relay_reconnect_task(state).await;
    state.relay.config.write().await.take();
    disconnect_relay_data(state).await;
    state.relay.control.write().await.take();
    crate::events::emit_relay_state(
        &state.event_tx,
        network_protocol::RelayConnectionState::Disconnected,
        None,
    );
    Ok(())
}

/// 取走并断开全部 reservation 数据面客户端。
pub(crate) async fn disconnect_relay_data(state: &RuntimeState) {
    state.close_all_relay_paths().await;
    // 断开全部 reservation：清理所有对端的 Relay 状态。
    cleanup_relay_state(state, None).await;
}

/// 只在控制面 socket 意外结束时启动一个共享重连任务；显式 DisconnectRelay 会先
/// 清除配置，因此不会被这个后台任务重新拉起。
pub(crate) fn schedule_relay_reconnect(state: Arc<RuntimeState>) {
    if state
        .relay
        .reconnect_active
        .swap(true, std::sync::atomic::Ordering::AcqRel)
    {
        return;
    }
    if state
        .relay
        .credential_stale
        .load(std::sync::atomic::Ordering::Acquire)
    {
        // 凭据已被判定过期/冲突，盲目重连只会复用失效凭据；等待 Dart 下发新的
        // ConfigureRelayCommand 后再恢复。
        state
            .relay
            .reconnect_active
            .store(false, std::sync::atomic::Ordering::Release);
        return;
    }
    let reconnect_state = Arc::clone(&state);
    let task_id = state
        .task_supervisor
        .spawn_runtime("relay-reconnect", async move {
            let mut backoff = crate::runtime::RECONNECT_INITIAL_BACKOFF;
            loop {
                tokio::time::sleep(backoff).await;
                if reconnect_state
                    .relay
                    .credential_stale
                    .load(std::sync::atomic::Ordering::Acquire)
                {
                    break;
                }
                let Some(config) = reconnect_state.relay.config.read().await.clone() else {
                    break;
                };
                let Some(device_id) = reconnect_state
                    .lifecycle
                    .identity
                    .read()
                    .await
                    .as_ref()
                    .map(|identity| identity.device_id.clone())
                else {
                    break;
                };
                if reconnect_state.relay.control.read().await.is_some() {
                    break;
                }
                reconnect_state.relay.control.write().await.take();
                match setup_v2_control_plane(&reconnect_state, &device_id, &config).await {
                    Ok(()) => {
                        crate::discovery::spawn_control_connected(&reconnect_state);
                        crate::events::emit_relay_state(
                            &reconnect_state.event_tx,
                            network_protocol::RelayConnectionState::Connected,
                            None,
                        );
                        Arc::clone(&reconnect_state).resume_relay_transfers().await;
                        break;
                    }
                    Err(error)
                        if reconnect_state
                            .relay
                            .credential_stale
                            .load(std::sync::atomic::Ordering::Acquire) =>
                    {
                        // 凭据过期/冲突：停止重连并发布类型化 Failed（现有 stale 守卫
                        // 随后生效），Dart 据此下发新的 ConfigureRelayCommand。
                        crate::events::emit_relay_state(
                            &reconnect_state.event_tx,
                            network_protocol::RelayConnectionState::Failed,
                            Some(error),
                        );
                        break;
                    }
                    Err(error) => {
                        tracing::debug!(error = ?error, "Relay reconnect attempt failed");
                        backoff = std::cmp::min(
                            backoff.saturating_mul(2),
                            crate::runtime::RECONNECT_MAX_BACKOFF,
                        );
                    }
                }
            }
            reconnect_state
                .relay
                .reconnect_active
                .store(false, std::sync::atomic::Ordering::Release);
            if let Ok(mut task) = reconnect_state.relay.reconnect_task.lock() {
                task.take();
            }
        });
    if let Some(task_id) = task_id {
        if let Ok(mut task) = state.relay.reconnect_task.lock() {
            *task = Some(task_id);
        }
    } else {
        state
            .relay
            .reconnect_active
            .store(false, std::sync::atomic::Ordering::Release);
    }
}

pub(crate) async fn stop_relay_reconnect_task(state: &RuntimeState) {
    state
        .relay
        .reconnect_active
        .store(false, std::sync::atomic::Ordering::Release);
    let task_id = state
        .relay
        .reconnect_task
        .lock()
        .ok()
        .and_then(|mut task| task.take());
    if let Some(task_id) = task_id {
        state.task_supervisor.cancel_task(task_id).await;
    }
}

/// 将 Relay connect 失败映射为类型化协议错误。凭据过期/身份冲突是终态错误，
/// 其余仍走通用的 Relay 传输错误。
pub(crate) fn relay_connect_protocol_error(error: &RelayError, operation: &str) -> ProtocolError {
    match error {
        RelayError::CredentialExpired(_) => protocol_error_with_retry(
            NetworkErrorCode::CredentialExpired,
            error.to_string(),
            operation,
            None,
            RetryDisposition::RefreshCredentialThenRetry,
            0,
        ),
        RelayError::IdentityConflict(_) => protocol_error_with_retry(
            NetworkErrorCode::IdentityConflict,
            error.to_string(),
            operation,
            None,
            RetryDisposition::NoRetry,
            0,
        ),
        _ => protocol_error_with_context(
            NetworkErrorCode::RelayError,
            error.to_string(),
            operation,
            None,
        ),
    }
}
