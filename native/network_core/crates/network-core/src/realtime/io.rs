//! Realtime I/O drivers, task ownership, and session removal.
use super::*;
use crate::events::{emit_realtime_snapshot, emit_realtime_state, RealtimeSessionIdentity};
use crate::runtime::RuntimeState;
use network_webrtc::{
    run_realtime_io, IceServerConfig, RealtimeIoDriver, RealtimeIoEvent, WebRtcConfig, WebRtcError,
};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use tokio::sync::mpsc;

pub(crate) fn with_session_peer<T>(
    session: &mut RealtimeSession,
    operation: impl FnOnce(&mut WebRtcPeer) -> Result<T, WebRtcError>,
) -> Result<T, WebRtcError> {
    if let Some(driver) = session.driver.as_ref() {
        let mut driver = driver
            .lock()
            .map_err(|_| WebRtcError::Io("realtime I/O driver mutex was poisoned".to_owned()))?;
        return operation(driver.peer_mut());
    }
    if let Some(peer) = session.peer.as_mut() {
        return operation(peer);
    }
    Err(WebRtcError::Io(
        "realtime session has no WebRTC peer owner".to_owned(),
    ))
}

pub(crate) fn runtime_webrtc_config() -> WebRtcConfig {
    let turn_urls = std::env::var("SSH_MOBILE_TURN_SERVERS")
        .ok()
        .or_else(|| std::env::var("SSH_MOBILE_TURN_URL").ok());
    runtime_webrtc_config_from_values(
        turn_urls,
        std::env::var("SSH_MOBILE_TURN_USERNAME").ok(),
        std::env::var("SSH_MOBILE_TURN_CREDENTIAL").ok(),
        std::env::var("SSH_MOBILE_TURN_RELAY_ONLY").ok(),
    )
}

pub(crate) fn runtime_webrtc_config_from_values(
    turn_urls: Option<String>,
    username: Option<String>,
    credential: Option<String>,
    relay_only: Option<String>,
) -> WebRtcConfig {
    let mut config = WebRtcConfig::default();
    let turn_urls = turn_urls.unwrap_or_default();
    if !turn_urls.trim().is_empty() {
        let username = username.unwrap_or_default();
        let credential = credential.unwrap_or_default();
        config.ice_servers = turn_urls
            .split(',')
            .map(str::trim)
            .filter(|url| !url.is_empty())
            .map(|url| IceServerConfig::turn(url, &username, &credential))
            .collect();
        config.relay_only = matches!(
            relay_only.as_deref(),
            Some("1" | "true" | "TRUE" | "yes" | "YES")
        );
    }
    config
}

pub(crate) async fn create_io_driver(
    state: &RuntimeState,
    config: WebRtcConfig,
) -> Result<RealtimeIoDriver, WebRtcError> {
    let bind_ip = state
        .lifecycle
        .endpoint
        .read()
        .await
        .as_ref()
        .and_then(|endpoint| endpoint.local_addr().ok().map(|address| address.ip()))
        .unwrap_or(IpAddr::V4(Ipv4Addr::LOCALHOST));
    let bind_addr = SocketAddr::new(bind_ip, 0);
    let advertised_ip = (!bind_ip.is_unspecified()).then_some(bind_ip);
    // Generic Realtime sessions stay media-neutral. Phase 2 screen sharing
    // configures the dedicated H.264 transceiver at the explicit screen-track
    // integration point instead of changing every DataChannel SDP.
    let peer = WebRtcPeer::new(config)?;
    RealtimeIoDriver::bind_with_advertised_ip(peer, bind_addr, advertised_ip).await
}

pub(crate) fn realtime_task_key(realtime_id: &str) -> String {
    format!("realtime:{realtime_id}")
}

pub(crate) async fn run_realtime_session_io(
    state: Arc<RuntimeState>,
    realtime_id: String,
    peer_id: String,
    driver: RealtimeIoDriverHandle,
) {
    let (event_tx, mut event_rx) = mpsc::channel(network_webrtc::REALTIME_IO_EVENT_CAPACITY);
    let session_driver = Arc::clone(&driver);
    let io = run_realtime_io(driver, event_tx);
    tokio::pin!(io);
    loop {
        tokio::select! {
            result = &mut io => {
                if let Err(error) = result {
                    let revision = session_revision(&state, &realtime_id).await;
                    let generation = session_generation(&state, &realtime_id).await;
                    let shared_session_instance_id =
                        session_shared_session_instance_id(&state, &realtime_id).await;
                    emit_realtime_state(
                        &state.event_tx,
                        &realtime_id,
                        &peer_id,
                        RealtimeSessionState::Failed as i32,
                        revision,
                        RealtimeSessionIdentity::new(generation, &shared_session_instance_id),
                        Some(realtime_error(
                            network_protocol::NetworkErrorCode::IoError,
                            error.to_string(),
                            "realtime_io",
                            &peer_id,
                        )),
                    );
                }
                remove_realtime_session_if_owned(
                    &state,
                    &realtime_id,
                    &peer_id,
                    &session_driver,
                )
                .await;
                break;
            }
            event = event_rx.recv() => {
                let Some(event) = event else { break; };
                if handle_io_event(&state, &realtime_id, &peer_id, event).await {
                    remove_realtime_session_if_owned(
                        &state,
                        &realtime_id,
                        &peer_id,
                        &session_driver,
                    )
                    .await;
                    break;
                }
            }
        }
    }
}

pub(crate) async fn handle_io_event(
    state: &RuntimeState,
    realtime_id: &str,
    peer_id: &str,
    event: RealtimeIoEvent,
) -> bool {
    match event {
        RealtimeIoEvent::LocalIceCandidate(candidate) => {
            forward_local_candidate(state, realtime_id, peer_id, candidate).await;
            false
        }
        RealtimeIoEvent::PeerConnected => {
            let revision = session_revision(state, realtime_id).await;
            let generation = session_generation(state, realtime_id).await;
            let shared_session_instance_id =
                session_shared_session_instance_id(state, realtime_id).await;
            emit_realtime_state(
                &state.event_tx,
                realtime_id,
                peer_id,
                RealtimeSessionState::Connected as i32,
                revision,
                RealtimeSessionIdentity::new(generation, &shared_session_instance_id),
                None,
            );
            // Session 稳定后发布完整快照；订阅方在 delta 状态之后看到一致快照。
            emit_realtime_snapshot(
                &state.event_tx,
                realtime_id,
                peer_id,
                RealtimeSessionState::Connected as i32,
                revision,
                RealtimeSessionIdentity::new(generation, &shared_session_instance_id),
                None,
            );
            false
        }
        RealtimeIoEvent::PeerDisconnected
        | RealtimeIoEvent::PeerFailed
        | RealtimeIoEvent::IceFailed => {
            let generation = session_generation(state, realtime_id).await;
            let shared_session_instance_id =
                session_shared_session_instance_id(state, realtime_id).await;
            emit_realtime_state(
                &state.event_tx,
                realtime_id,
                peer_id,
                RealtimeSessionState::Failed as i32,
                session_revision(state, realtime_id).await,
                RealtimeSessionIdentity::new(generation, &shared_session_instance_id),
                Some(realtime_error(
                    network_protocol::NetworkErrorCode::IoError,
                    "WebRTC peer connection terminated",
                    "realtime_io",
                    peer_id,
                )),
            );
            true
        }
        RealtimeIoEvent::DataChannelMessage {
            channel_id,
            is_string,
            payload,
        } => {
            tracing::debug!(
                realtime_id,
                peer_id,
                channel_id,
                is_string,
                payload_bytes = payload.len(),
                "WebRTC data channel payload received by native realtime owner"
            );
            false
        }
        RealtimeIoEvent::IceConnected
        | RealtimeIoEvent::DataChannelOpened(_)
        | RealtimeIoEvent::DataChannelClosed(_) => false,
    }
}

pub(crate) fn take_realtime_session_if_owned(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    driver: &RealtimeIoDriverHandle,
) -> Option<RealtimeSession> {
    let owns_driver = manager.sessions.get(realtime_id).is_some_and(|session| {
        session.peer_id == peer_id
            && session
                .driver
                .as_ref()
                .is_some_and(|candidate| Arc::ptr_eq(candidate, driver))
    });
    owns_driver
        .then(|| manager.remove_session(realtime_id))
        .flatten()
}

pub(crate) async fn remove_realtime_session_if_owned(
    state: &RuntimeState,
    realtime_id: &str,
    peer_id: &str,
    driver: &RealtimeIoDriverHandle,
) {
    let removed = {
        let mut sessions = state.realtime.lock().await;
        let removed = take_realtime_session_if_owned(&mut sessions, realtime_id, peer_id, driver);
        if removed.is_some() {
            crate::realtime_media::invalidate_realtime(state, realtime_id);
        }
        removed
    };
    if let Some(mut session) = removed {
        let _ = with_session_peer(&mut session, WebRtcPeer::close);
    }
}

/// Removes a session selected only by its immutable peer binding.
///
/// Runtime I/O teardown must use [`remove_realtime_session_if_owned`] so a
/// late event from an older driver cannot remove a replacement generation.
#[cfg(test)]
pub(crate) async fn remove_realtime_session(
    state: &RuntimeState,
    realtime_id: &str,
    peer_id: &str,
) {
    let removed = {
        let mut sessions = state.realtime.lock().await;
        let should_remove = sessions
            .sessions
            .get(realtime_id)
            .is_some_and(|session| session.peer_id == peer_id);
        let removed = should_remove
            .then(|| sessions.remove_session(realtime_id))
            .flatten();
        if removed.is_some() {
            crate::realtime_media::invalidate_realtime(state, realtime_id);
        }
        removed
    };
    if let Some(mut session) = removed {
        let _ = with_session_peer(&mut session, WebRtcPeer::close);
    }
}

/// §22：ConnectionSession 销毁（transport 丢失 / 显式断开 / 被新连接替换）时关闭
/// 绑定在它上面的所有 RealtimeSession。旧 RealtimeSession 发出 `Closed` 事件并被移除；
/// 用户/feature 可重新请求，manager 会经新的 Resolve → Connection → signaling 建立
/// 全新的 PeerConnection——绝不透明恢复旧 PeerConnection 对象。
pub(crate) async fn close_realtime_sessions_for_session(
    state: &RuntimeState,
    peer_id: &str,
    session_id: SessionId,
) {
    let closed = {
        let mut manager = state.realtime.lock().await;
        // Keep session removal and endpoint invalidation in one ownership
        // scope. Endpoint creation holds this same RealtimeManager lock while
        // registering its lease; revoking before the peer close also prevents
        // a concurrent endpoint operation from enqueueing into a terminal
        // native queue while the driver is being shut down.
        manager.close_for_connection_session_with_hook(peer_id, session_id, |realtime_id| {
            crate::realtime_media::invalidate_realtime(state, realtime_id);
        })
    };
    for (realtime_id, session_peer_id, close_revision, generation, shared_session_instance_id) in
        closed
    {
        state
            .task_supervisor
            .cancel_session(&realtime_task_key(&realtime_id))
            .await;
        emit_realtime_state(
            &state.event_tx,
            &realtime_id,
            &session_peer_id,
            RealtimeSessionState::Closed as i32,
            close_revision,
            RealtimeSessionIdentity::new(generation, &shared_session_instance_id),
            None,
        );
    }
}

pub(crate) async fn session_revision(state: &RuntimeState, realtime_id: &str) -> u64 {
    state
        .realtime
        .lock()
        .await
        .sessions
        .get(realtime_id)
        .map(|session| session.revision)
        .unwrap_or_default()
}

async fn session_generation(state: &RuntimeState, realtime_id: &str) -> u64 {
    state
        .realtime
        .lock()
        .await
        .session_generation(realtime_id)
        .unwrap_or_default()
}

async fn session_shared_session_instance_id(state: &RuntimeState, realtime_id: &str) -> String {
    state
        .realtime
        .lock()
        .await
        .sessions
        .get(realtime_id)
        .map(|session| session.shared_session_instance_id.clone())
        .unwrap_or_default()
}
