//! Realtime session creation, removal, and generation ownership.
use super::*;
use crate::events::{
    emit_realtime_signal, emit_realtime_state, protocol_error, RealtimeSessionIdentity,
};
use crate::runtime::RuntimeState;
use network_protocol::{StartRealtimeSessionCommand, StopRealtimeSessionCommand};
use network_webrtc::WebRtcConfig;
use std::sync::atomic::Ordering;

impl RealtimeManager {
    /// Resolves the current native I/O driver only while the caller still owns
    /// this manager lock. Endpoint creation keeps that lock through registry
    /// insertion so a terminal session removal cannot race a new lease into a
    /// dead realtime generation.
    pub(crate) fn media_endpoint_driver(
        &self,
        realtime_id: &str,
        peer_id: &str,
    ) -> Result<(RealtimeIoDriverHandle, u64), crate::realtime_media::RealtimeMediaError> {
        let Some(session) = self.sessions.get(realtime_id) else {
            return Err(crate::realtime_media::RealtimeMediaError::UnknownRealtimeSession);
        };
        if session.peer_id != peer_id {
            return Err(crate::realtime_media::RealtimeMediaError::PeerMismatch);
        }
        let generation = self
            .session_generations
            .get(realtime_id)
            .copied()
            .ok_or(crate::realtime_media::RealtimeMediaError::StaleGeneration)?;
        let driver = session
            .driver
            .clone()
            .ok_or(crate::realtime_media::RealtimeMediaError::DriverUnavailable)?;
        Ok((driver, generation))
    }

    pub(crate) fn insert_new_session(&mut self, realtime_id: String, session: RealtimeSession) {
        let generation = NEXT_REALTIME_SESSION_GENERATION.fetch_add(1, Ordering::Relaxed);
        self.session_generations
            .insert(realtime_id.clone(), generation);
        self.sessions.insert(realtime_id, session);
    }

    pub(crate) fn insert_existing_session(
        &mut self,
        realtime_id: String,
        session: RealtimeSession,
    ) {
        self.session_generations
            .entry(realtime_id.clone())
            .or_insert_with(|| NEXT_REALTIME_SESSION_GENERATION.fetch_add(1, Ordering::Relaxed));
        self.sessions.insert(realtime_id, session);
    }

    pub(crate) fn remove_session(&mut self, realtime_id: &str) -> Option<RealtimeSession> {
        let removed = self.sessions.remove(realtime_id);
        if removed.is_some() {
            self.session_generations.remove(realtime_id);
        }
        removed
    }

    pub(crate) fn session_generation(&self, realtime_id: &str) -> Option<u64> {
        self.session_generations.get(realtime_id).copied()
    }

    /// Installs a live driver for the network-ffi C-ABI success-path test
    /// without exposing the session owner to production callers. The helper is
    /// compiled only when the network-ffi test-support feature is enabled.
    #[cfg(feature = "ffi-test-support")]
    pub(crate) fn insert_ffi_test_driver_session(
        &mut self,
        realtime_id: String,
        peer_id: String,
        driver: RealtimeIoDriverHandle,
    ) -> u64 {
        let generation_id = realtime_id.clone();
        self.insert_new_session(
            realtime_id,
            RealtimeSession {
                peer_id,
                shared_session_instance_id: new_shared_session_instance_id(),
                connection_session_id: None,
                peer: None,
                driver: Some(driver),
                revision: 1,
                remote_revision: 0,
                ice_revision: 1,
                seen_candidates: HashSet::new(),
            },
        );
        self.session_generations
            .get(&generation_id)
            .copied()
            .expect("inserted realtime generation")
    }

    /// Close every WebRTC peer before the runtime supervisor joins its tasks.
    pub(crate) fn close_all(&mut self) {
        for binding in self.provisional.values_mut() {
            binding.state = ProvisionalBindingState::Terminal;
        }
        self.provisional.clear();
        self.provisional_requests.clear();
        self.wake_provisional_expiry();
        for (_, mut session) in self.sessions.drain() {
            let _ = with_session_peer(&mut session, WebRtcPeer::close);
        }
        self.session_generations.clear();
    }

    /// §22：ConnectionSession 销毁（transport 丢失）时关闭绑定在该 ConnectionSession
    /// 上的所有 RealtimeSession——移除注册、销毁 WebRTC peer。返回
    /// `(realtime_id, peer_id, close_revision, generation)`，供调用方取消
    /// supervised I/O 任务并发出 Closed 事件。
    #[cfg(test)]
    pub(crate) fn close_for_connection_session(
        &mut self,
        peer_id: &str,
        session_id: SessionId,
    ) -> Vec<(String, String, u64, u64, String)> {
        self.close_for_connection_session_with_hook(peer_id, session_id, |_| {})
    }

    /// Variant used by runtime teardown to revoke borrowed media leases before
    /// closing the peer that owns their queues.
    pub(crate) fn close_for_connection_session_with_hook(
        &mut self,
        peer_id: &str,
        session_id: SessionId,
        mut before_peer_close: impl FnMut(&str),
    ) -> Vec<(String, String, u64, u64, String)> {
        let provisional_peers = self
            .provisional
            .iter()
            .filter(|(_, binding)| binding.authenticated_peer_id == peer_id)
            .map(|(realtime_id, _)| realtime_id.clone())
            .collect::<Vec<_>>();
        for realtime_id in provisional_peers {
            if let Some(mut binding) = self.provisional.remove(&realtime_id) {
                binding.state = ProvisionalBindingState::Terminal;
            }
        }
        self.provisional_requests
            .retain(|_, request| request.authenticated_peer_id != peer_id);
        self.wake_provisional_expiry();
        let mut closed = Vec::new();
        let matching = self
            .sessions
            .iter()
            .filter(|(_, session)| {
                session.peer_id == peer_id && session.connection_session_id == Some(session_id)
            })
            .map(|(realtime_id, _)| realtime_id.clone())
            .collect::<Vec<_>>();
        for realtime_id in matching {
            let generation = self.session_generation(&realtime_id).unwrap_or_default();
            let Some(mut session) = self.remove_session(&realtime_id) else {
                continue;
            };
            let close_revision = session.revision.saturating_add(1);
            before_peer_close(&realtime_id);
            let _ = with_session_peer(&mut session, WebRtcPeer::close);
            closed.push((
                realtime_id,
                session.peer_id,
                close_revision,
                generation,
                session.shared_session_instance_id,
            ));
        }
        closed
    }
}

pub(crate) async fn start_session(
    state: Arc<RuntimeState>,
    command: StartRealtimeSessionCommand,
) -> Result<(), network_protocol::NetworkError> {
    start_session_with_config(state, command, runtime_webrtc_config()).await
}

pub(crate) async fn start_session_with_config(
    state: Arc<RuntimeState>,
    command: StartRealtimeSessionCommand,
    config: WebRtcConfig,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    validate_peer(&state, &command.peer_id).await?;

    // §22：重复启动同一 realtime session 必须在绑定任何 I/O 资源（UDP socket、
    // data channel）之前拒绝——否则错误路径会丢弃一个已绑定 socket 的驱动而不
    // 确定性关闭（泄漏）。这里先做快速检查；下面持锁插入前还会二次确认（并发
    // 下两次 start_session 都可能通过本次检查）。
    if state
        .realtime
        .lock()
        .await
        .sessions
        .contains_key(&command.realtime_id)
    {
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "realtime session already exists",
            "start_realtime",
            &command.peer_id,
        ));
    }

    let mut driver = create_io_driver(&state, config).await.map_err(|error| {
        realtime_error(
            network_protocol::NetworkErrorCode::IoError,
            error.to_string(),
            "start_realtime",
            &command.peer_id,
        )
    })?;
    driver
        .peer_mut()
        .create_data_channel("ssh-mobile-realtime", Default::default())
        .map_err(|error| {
            realtime_error(
                network_protocol::NetworkErrorCode::IoError,
                error.to_string(),
                "create_webrtc_data_channel",
                &command.peer_id,
            )
        })?;
    let offer = driver.peer_mut().create_offer().map_err(|error| {
        realtime_error(
            network_protocol::NetworkErrorCode::IoError,
            error.to_string(),
            "create_webrtc_offer",
            &command.peer_id,
        )
    })?;
    let revision = driver.peer_mut().signaling_revision();
    let driver = driver.into_handle();
    let realtime_id = command.realtime_id;
    let peer_id = command.peer_id;
    let shared_session_instance_id = new_shared_session_instance_id();
    // §22：PeerConnection 绑定在创建它的 ConnectionSession 上（transport 丢失时
    // 随 ConnectionSession 一并销毁）。创建时若尚无数据连接，绑定为 None。
    let connection_session_id = state.connection_sessions.current_session_id(&peer_id).await;
    let mut sessions = state.realtime.lock().await;
    if sessions.sessions.contains_key(&realtime_id) {
        // 并发下两次 start_session 都通过了开头的提前检查：这里在持锁下二次确认。
        // 若已被并发调用占用，必须显式 close 刚创建/绑定的驱动，保证 socket 与
        // peer 被确定性释放（绝不静默丢弃）。
        if let Ok(mut driver) = driver.lock() {
            let _ = driver.close();
        }
        drop(sessions);
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "realtime session already exists",
            "start_realtime",
            &peer_id,
        ));
    }
    sessions.insert_new_session(
        realtime_id.clone(),
        RealtimeSession {
            peer_id: peer_id.clone(),
            shared_session_instance_id: shared_session_instance_id.clone(),
            connection_session_id,
            peer: None,
            driver: Some(driver.clone()),
            revision,
            remote_revision: 0,
            ice_revision: revision,
            seen_candidates: HashSet::new(),
        },
    );
    let generation = sessions
        .session_generation(&realtime_id)
        .expect("inserted realtime generation");
    drop(sessions);

    let outbound = OutboundSignal {
        realtime_id: realtime_id.clone(),
        peer_id: peer_id.clone(),
        shared_session_instance_id: shared_session_instance_id.clone(),
        kind: RealtimeSignalKind::WebRtcOffer,
        revision,
        payload: offer.sdp.into_bytes(),
    };
    if let Err(error) = send_signal(&state, &outbound).await {
        let removed = {
            let mut sessions = state.realtime.lock().await;
            let removed =
                take_realtime_session_if_owned(&mut sessions, &realtime_id, &peer_id, &driver);
            if removed.is_some() {
                crate::realtime_media::invalidate_realtime(&state, &realtime_id);
            }
            removed
        };
        if let Some(mut removed) = removed {
            let _ = with_session_peer(&mut removed, WebRtcPeer::close);
        }
        emit_realtime_state(
            &state.event_tx,
            &realtime_id,
            &peer_id,
            RealtimeSessionState::Failed as i32,
            revision,
            RealtimeSessionIdentity::new(generation, &shared_session_instance_id),
            Some(error.clone()),
        );
        return Err(error);
    }
    if state
        .task_supervisor
        .spawn_session(
            realtime_task_key(&realtime_id),
            "realtime-io",
            run_realtime_session_io(
                state.clone(),
                realtime_id.clone(),
                peer_id.clone(),
                driver.clone(),
            ),
        )
        .is_none()
    {
        let removed = {
            let mut sessions = state.realtime.lock().await;
            let removed =
                take_realtime_session_if_owned(&mut sessions, &realtime_id, &peer_id, &driver);
            if removed.is_some() {
                crate::realtime_media::invalidate_realtime(&state, &realtime_id);
            }
            removed
        };
        if let Some(mut removed) = removed {
            let _ = with_session_peer(&mut removed, WebRtcPeer::close);
        } else if let Ok(mut driver) = driver.lock() {
            let _ = driver.close();
        }
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::Cancelled,
            "runtime task supervisor is stopping",
            "start_realtime",
            &peer_id,
        ));
    }
    emit_realtime_state(
        &state.event_tx,
        &realtime_id,
        &peer_id,
        RealtimeSessionState::Negotiating as i32,
        revision,
        RealtimeSessionIdentity::new(generation, &shared_session_instance_id),
        None,
    );
    emit_realtime_signal(
        &state.event_tx,
        &realtime_id,
        &peer_id,
        RealtimeSignalKind::WebRtcOffer as i32,
        revision,
        outbound.payload,
    );
    Ok(())
}

pub(crate) async fn stop_session(
    state: &RuntimeState,
    command: StopRealtimeSessionCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    let session = {
        let mut sessions = state.realtime.lock().await;
        let generation = sessions
            .session_generation(&command.realtime_id)
            .unwrap_or_default();
        let session = sessions.remove_session(&command.realtime_id);
        if session.is_some() {
            crate::realtime_media::invalidate_realtime(state, &command.realtime_id);
        }
        session.map(|session| (session, generation))
    };
    let Some((mut session, generation)) = session else {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "realtime session does not exist",
        ));
    };
    let close_revision = session.revision.saturating_add(1);
    state
        .task_supervisor
        .cancel_session(&realtime_task_key(&command.realtime_id))
        .await;
    let _ = with_session_peer(&mut session, WebRtcPeer::close);
    let outbound = OutboundSignal {
        realtime_id: command.realtime_id.clone(),
        peer_id: session.peer_id.clone(),
        shared_session_instance_id: session.shared_session_instance_id.clone(),
        kind: RealtimeSignalKind::WebRtcClose,
        revision: close_revision,
        payload: b"close".to_vec(),
    };
    if let Err(error) = send_signal(state, &outbound).await {
        tracing::debug!(error = %error.message, "failed to send WebRTC close signal");
    }
    emit_realtime_state(
        &state.event_tx,
        &command.realtime_id,
        &session.peer_id,
        RealtimeSessionState::Closed as i32,
        close_revision,
        RealtimeSessionIdentity::new(generation, &session.shared_session_instance_id),
        None,
    );
    Ok(())
}

/// Observe whether a peer has a live Realtime session before an environment
/// reprobe.  Environment changes are discovery invalidations, not Realtime
/// close events; the coordinator can use this owner-side hook to preserve a
/// healthy PeerConnection while it refreshes Direct candidates.  A genuine
/// transport loss still goes through [`close_realtime_sessions_for_session`]
/// and creates a fresh Realtime session on the next explicit request.
pub(crate) async fn preserve_for_environment_reprobe(state: &RuntimeState, peer_id: &str) -> bool {
    state
        .realtime
        .lock()
        .await
        .sessions
        .values()
        .any(|session| session.peer_id == peer_id)
}
