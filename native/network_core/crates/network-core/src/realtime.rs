//! WebRTC realtime Session integration.
//!
//! Realtime media is deliberately a sibling of the ordinary Data Route. This
//! module owns only the native WebRTC peer and signaling revision; keyboard,
//! clipboard, files, Delivery, and Relay recovery remain on their existing
//! QUIC/Relay paths.

use network_protocol::{
    RealtimeSessionState, RealtimeSignalKind, ScreenShareConsentDecision,
    ScreenShareConsentPurpose, ScreenShareConsentV2, ScreenShareMediaKind,
    SendRealtimeSignalCommand, StartRealtimeSessionCommand, StopRealtimeSessionCommand,
};
use network_relay::v2::{
    RealtimeSignal as V2RealtimeSignal, RealtimeSignalKind as V2RealtimeSignalKind,
};
use network_webrtc::{
    run_realtime_io, DescriptionType, IceCandidate, IceServerConfig, RealtimeIoDriver,
    RealtimeIoDriverHandle, RealtimeIoEvent, SessionDescription, WebRtcConfig, WebRtcError,
    WebRtcPeer, MAX_ICE_CANDIDATE_BYTES, MAX_SDP_BYTES,
};
use prost::Message;
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::mpsc;
#[cfg(test)]
use tokio::sync::mpsc::unbounded_channel;

use crate::events::{
    emit_realtime_signal, emit_realtime_snapshot, emit_realtime_state, protocol_error,
    protocol_error_with_peer,
};
use crate::runtime::RuntimeState;
use crate::session::SessionId;

const MAX_REALTIME_SIGNAL_PAYLOAD_BYTES: usize = MAX_SDP_BYTES;
static NEXT_REALTIME_SESSION_GENERATION: AtomicU64 = AtomicU64::new(1);

struct RealtimeSession {
    peer_id: String,
    /// §22：PeerConnection/SDP/ICE 状态绑定在创建它的 ConnectionSession 上，
    /// ConnectionSession 销毁（transport 丢失）即一并销毁 RealtimeSession；
    /// 恢复必须走新的 Resolve → Connection → 重新 signaling → 新 PeerConnection。
    /// `None` 表示创建时该 peer 尚无 ConnectionSession（例如 responder 首个信令
    /// 早于数据连接建立）。
    connection_session_id: Option<SessionId>,
    /// Signaling uses this only for sessions created by the pure state-machine
    /// tests. Runtime sessions keep the peer inside `RealtimeIoDriver` and
    /// access it through `driver` so the socket and sans-I/O peer share one
    /// owner.
    peer: Option<WebRtcPeer>,
    driver: Option<RealtimeIoDriverHandle>,
    revision: u64,
    /// Highest signaling revision authored by the remote peer and accepted
    /// by this Session. It is separate from the local WebRTC state revision:
    /// offer/answer state machines advance those counters independently.
    remote_revision: u64,
    /// Revision of the active ICE generation. The answer advances the
    /// signaling state revision, but trickled candidates still belong to the
    /// offer's ICE generation.
    ice_revision: u64,
    seen_candidates: HashSet<Vec<u8>>,
}

#[derive(Default)]
pub(crate) struct RealtimeManager {
    sessions: HashMap<String, RealtimeSession>,
    /// Generation is owned by the live Realtime manager, not inferred by the
    /// media registry. It changes whenever a new session is inserted for an ID.
    session_generations: HashMap<String, u64>,
}

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

    fn insert_new_session(&mut self, realtime_id: String, session: RealtimeSession) {
        let generation = NEXT_REALTIME_SESSION_GENERATION.fetch_add(1, Ordering::Relaxed);
        self.session_generations
            .insert(realtime_id.clone(), generation);
        self.sessions.insert(realtime_id, session);
    }

    fn insert_existing_session(&mut self, realtime_id: String, session: RealtimeSession) {
        self.session_generations
            .entry(realtime_id.clone())
            .or_insert_with(|| NEXT_REALTIME_SESSION_GENERATION.fetch_add(1, Ordering::Relaxed));
        self.sessions.insert(realtime_id, session);
    }

    fn remove_session(&mut self, realtime_id: &str) -> Option<RealtimeSession> {
        let removed = self.sessions.remove(realtime_id);
        if removed.is_some() {
            self.session_generations.remove(realtime_id);
        }
        removed
    }

    fn session_generation(&self, realtime_id: &str) -> Option<u64> {
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
    fn close_for_connection_session(
        &mut self,
        peer_id: &str,
        session_id: SessionId,
    ) -> Vec<(String, String, u64, u64)> {
        self.close_for_connection_session_with_hook(peer_id, session_id, |_| {})
    }

    /// Variant used by runtime teardown to revoke borrowed media leases before
    /// closing the peer that owns their queues.
    fn close_for_connection_session_with_hook(
        &mut self,
        peer_id: &str,
        session_id: SessionId,
        mut before_peer_close: impl FnMut(&str),
    ) -> Vec<(String, String, u64, u64)> {
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
            closed.push((realtime_id, session.peer_id, close_revision, generation));
        }
        closed
    }
}

struct OutboundSignal {
    realtime_id: String,
    peer_id: String,
    kind: RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
}

/// 一条已解码的入站 WebRTC 信令。v1 信封（revision 内嵌）与 v2 控制面帧
/// （revision 独立字段）在进入状态机前都归一化为该三元组。
struct InboundSignal {
    kind: RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
}

struct SignalOutcome {
    peer_id: String,
    revision: u64,
    generation: u64,
    state: RealtimeSessionState,
    outbound: Option<OutboundSignal>,
}

pub(crate) async fn start_session(
    state: Arc<RuntimeState>,
    command: StartRealtimeSessionCommand,
) -> Result<(), network_protocol::NetworkError> {
    start_session_with_config(state, command, runtime_webrtc_config()).await
}

async fn start_session_with_config(
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
            generation,
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
        generation,
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
        generation,
        None,
    );
    Ok(())
}

pub(crate) async fn send_signal_command(
    state: &RuntimeState,
    command: SendRealtimeSignalCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    validate_peer(state, &command.peer_id).await?;
    let kind = RealtimeSignalKind::try_from(command.kind).map_err(|_| {
        realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "invalid WebRTC signal kind",
            "send_realtime_signal",
            &command.peer_id,
        )
    })?;
    validate_signal(kind, command.revision, &command.payload)?;
    if kind == RealtimeSignalKind::ScreenShareConsent {
        validate_screen_share_consent(&command.payload, &command.realtime_id, None).map_err(
            |error| {
                realtime_error(
                    network_protocol::NetworkErrorCode::InvalidArgument,
                    error.to_string(),
                    "send_realtime_signal",
                    &command.peer_id,
                )
            },
        )?;
    }
    let (session_peer_id, session_revision, ice_revision) = {
        let sessions = state.realtime.lock().await;
        let Some(session) = sessions.sessions.get(&command.realtime_id) else {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "realtime session does not exist",
                "send_realtime_signal",
                &command.peer_id,
            ));
        };
        (
            session.peer_id.clone(),
            session.revision,
            session.ice_revision,
        )
    };
    let revision_is_valid = if kind == RealtimeSignalKind::ScreenShareConsent {
        // Consent has its own action_revision and shared-session freshness
        // checks. The outer realtime revision is only a positive relay
        // correlation value and must not be confused with signaling ordering.
        command.revision > 0
    } else if kind == RealtimeSignalKind::IceCandidate {
        command.revision == ice_revision
    } else {
        command.revision > session_revision
    };
    if session_peer_id != command.peer_id || !revision_is_valid {
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "stale or mismatched realtime signaling revision",
            "send_realtime_signal",
            &command.peer_id,
        ));
    }
    let outbound = OutboundSignal {
        realtime_id: command.realtime_id.clone(),
        peer_id: command.peer_id.clone(),
        kind,
        revision: command.revision,
        payload: command.payload,
    };
    send_signal(state, &outbound).await?;
    emit_realtime_signal(
        &state.event_tx,
        &outbound.realtime_id,
        &outbound.peer_id,
        outbound.kind as i32,
        outbound.revision,
        outbound.payload,
    );
    Ok(())
}

/// v2 控制面信令入口（§17/§22：WebRTC signaling 经 Relay Control Plane）。
/// `RealtimeSignal` 帧携带独立 `revision` 与原始 payload（无 v1 信封）。冻结 wire
/// 不携带 sender 字段；接收端只能使用已经建立的 `realtime_id → peer_id` 会话绑定，
/// 未知会话直接拒绝，不能把 `target_device_id` 冒充远端身份。
pub(crate) async fn handle_v2_realtime_signal(
    state: &Arc<RuntimeState>,
    signal: &V2RealtimeSignal,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let peer_id = state
        .realtime
        .lock()
        .await
        .sessions
        .get(&signal.realtime_id)
        .map(|session| session.peer_id.clone())
        .ok_or_else(|| boxed_message("v2 WebRTC signal has no established peer binding"))?;
    if peer_id.is_empty() {
        return Err(boxed_message(
            "v2 WebRTC signal has an empty established peer binding",
        ));
    }
    let kind = RealtimeSignalKind::try_from(signal.kind)
        .map_err(|_| boxed_message("invalid v2 WebRTC signal kind"))?;
    handle_realtime_signal(
        state,
        kind,
        &signal.realtime_id,
        &peer_id,
        signal.revision,
        signal.payload.clone(),
    )
    .await
}

/// WebRTC signaling 协商核心：v1 / v2 两条入站路径共用。
///
/// 入站 Offer 在没有 RealtimeSession 时会创建一个新的 responder 会话；该会话按
/// §22 绑定到发起方当前 ConnectionSession（`connection_session_id`），transport 丢失
/// 时随 ConnectionSession 一并销毁。`outcome.outbound`（Answer / restart Offer / ICE）
/// 经 v2 控制面回发。
async fn handle_realtime_signal(
    state: &Arc<RuntimeState>,
    kind: RealtimeSignalKind,
    realtime_id: &str,
    peer_id: &str,
    revision: u64,
    payload: Vec<u8>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    validate_realtime_id(realtime_id).map_err(boxed_protocol_error)?;
    validate_peer(state, peer_id)
        .await
        .map_err(boxed_protocol_error)?;
    validate_signal(kind, revision, &payload).map_err(boxed_protocol_error)?;

    // Screen-share consent is authenticated control metadata, not a WebRTC
    // description. Keep it on the existing Realtime control route while
    // avoiding any PeerConnection mutation or state transition. The payload
    // carries the shared-session and action-revision guards used by the
    // business layer.
    if kind == RealtimeSignalKind::ScreenShareConsent {
        validate_screen_share_consent(&payload, realtime_id, Some(peer_id))?;
        emit_realtime_signal(
            &state.event_tx,
            realtime_id,
            peer_id,
            kind as i32,
            revision,
            payload,
        );
        return Ok(());
    }

    if kind == RealtimeSignalKind::WebRtcClose {
        let generation = {
            let mut manager = state.realtime.lock().await;
            close_remote_realtime_session(state, &mut manager, realtime_id, peer_id, revision)?
        };
        state
            .task_supervisor
            .cancel_session(&realtime_task_key(realtime_id))
            .await;
        emit_realtime_signal(
            &state.event_tx,
            realtime_id,
            peer_id,
            kind as i32,
            revision,
            payload,
        );
        emit_realtime_state(
            &state.event_tx,
            realtime_id,
            peer_id,
            RealtimeSessionState::Closed as i32,
            revision,
            generation,
            None,
        );
        return Ok(());
    }

    let pending_driver = if kind == RealtimeSignalKind::WebRtcOffer
        && !state
            .realtime
            .lock()
            .await
            .sessions
            .contains_key(realtime_id)
    {
        Some(
            create_io_driver(state, runtime_webrtc_config())
                .await
                .map_err(|error| boxed_message(error.to_string()))?
                .into_handle(),
        )
    } else {
        None
    };
    // §22：responder 新建会话时绑定当前 ConnectionSession；后续 transport 丢失据此
    // 关闭 RealtimeSession。
    let connection_session_id = state.connection_sessions.current_session_id(peer_id).await;

    let pending_driver_for_spawn = pending_driver.clone();
    let outcome = {
        let mut manager = state.realtime.lock().await;
        apply_signal_with_driver(
            &mut manager,
            realtime_id,
            peer_id,
            InboundSignal {
                kind,
                revision,
                payload: payload.clone(),
            },
            pending_driver,
            connection_session_id,
        )?
    };

    let driver_to_spawn = if let Some(pending_driver) = pending_driver_for_spawn {
        let sessions = state.realtime.lock().await;
        sessions.sessions.get(realtime_id).and_then(|session| {
            session
                .driver
                .as_ref()
                .filter(|driver| Arc::ptr_eq(driver, &pending_driver))
                .cloned()
        })
    } else {
        None
    };
    let driver_for_cleanup = driver_to_spawn.clone();
    let mut spawned_io = false;
    if let Some(driver) = driver_to_spawn {
        let cleanup_driver = Arc::clone(&driver);
        if state
            .task_supervisor
            .spawn_session(
                realtime_task_key(realtime_id),
                "realtime-io",
                run_realtime_session_io(
                    Arc::clone(state),
                    realtime_id.to_owned(),
                    peer_id.to_owned(),
                    driver,
                ),
            )
            .is_none()
        {
            let removed = {
                let mut sessions = state.realtime.lock().await;
                let removed = take_realtime_session_if_owned(
                    &mut sessions,
                    realtime_id,
                    peer_id,
                    &cleanup_driver,
                );
                if removed.is_some() {
                    crate::realtime_media::invalidate_realtime(state, realtime_id);
                }
                removed
            };
            if let Some(mut removed) = removed {
                let _ = with_session_peer(&mut removed, WebRtcPeer::close);
            }
            return Err(boxed_message("runtime task supervisor is stopping"));
        }
        spawned_io = true;
    }

    emit_realtime_signal(
        &state.event_tx,
        realtime_id,
        peer_id,
        kind as i32,
        revision,
        payload,
    );
    emit_realtime_state(
        &state.event_tx,
        realtime_id,
        &outcome.peer_id,
        outcome.state as i32,
        outcome.revision,
        outcome.generation,
        None,
    );
    if let Some(outbound) = outcome.outbound {
        if let Err(error) = send_signal(state, &outbound).await {
            if spawned_io {
                state
                    .task_supervisor
                    .cancel_session(&realtime_task_key(realtime_id))
                    .await;
                if let Some(driver) = driver_for_cleanup.as_ref() {
                    remove_realtime_session_if_owned(state, realtime_id, peer_id, driver).await;
                }
            }
            return Err(boxed_protocol_error(error));
        }
        emit_realtime_signal(
            &state.event_tx,
            &outbound.realtime_id,
            &outbound.peer_id,
            outbound.kind as i32,
            outbound.revision,
            outbound.payload,
        );
    }
    Ok(())
}

#[cfg(test)]
fn apply_signal(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    kind: RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
) -> Result<SignalOutcome, Box<dyn std::error::Error + Send + Sync>> {
    apply_signal_with_driver(
        manager,
        realtime_id,
        peer_id,
        InboundSignal {
            kind,
            revision,
            payload,
        },
        None,
        None,
    )
}

/// Removes a remotely closed session only after its immutable signal binding
/// has been checked. The generation is captured before removal because the
/// manager drops the generation map entry together with the session. Callers
/// own the returned session and must invalidate any borrowed media endpoints
/// before closing its native peer.
fn take_remote_closed_session(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    revision: u64,
) -> Result<(RealtimeSession, u64), Box<dyn std::error::Error + Send + Sync>> {
    let Some(session) = manager.sessions.get(realtime_id) else {
        return Err(boxed_message("realtime session does not exist"));
    };
    if session.peer_id != peer_id {
        return Err(boxed_message("realtime signal peer does not match session"));
    }
    if revision <= session.remote_revision {
        return Err(boxed_message("stale realtime signaling revision"));
    }
    let generation = manager
        .session_generation(realtime_id)
        .ok_or_else(|| boxed_message("realtime session generation missing"))?;
    let session = manager
        .remove_session(realtime_id)
        .ok_or_else(|| boxed_message("realtime session does not exist"))?;
    Ok((session, generation))
}

/// Applies a valid remote-close transition in one synchronous ownership scope.
/// Keeping the large WebRTC session out of the async signal handler's state
/// machine avoids retaining it across the task-supervisor await below.
fn close_remote_realtime_session(
    state: &RuntimeState,
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    revision: u64,
) -> Result<u64, Box<dyn std::error::Error + Send + Sync>> {
    let (mut session, generation) =
        take_remote_closed_session(manager, realtime_id, peer_id, revision)?;
    crate::realtime_media::invalidate_realtime(state, realtime_id);
    let _ = with_session_peer(&mut session, WebRtcPeer::close);
    Ok(generation)
}

fn apply_signal_with_driver(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    signal: InboundSignal,
    pending_driver: Option<RealtimeIoDriverHandle>,
    connection_session_id: Option<SessionId>,
) -> Result<SignalOutcome, Box<dyn std::error::Error + Send + Sync>> {
    let InboundSignal {
        kind,
        revision,
        payload,
    } = signal;
    if kind == RealtimeSignalKind::WebRtcClose {
        let (mut session, generation) =
            take_remote_closed_session(manager, realtime_id, peer_id, revision)?;
        let _ = with_session_peer(&mut session, WebRtcPeer::close);
        return Ok(SignalOutcome {
            peer_id: peer_id.to_string(),
            revision,
            generation,
            state: RealtimeSessionState::Closed,
            outbound: None,
        });
    }

    if let Some(session) = manager.sessions.get(realtime_id) {
        if session.peer_id != peer_id {
            return Err(boxed_message("realtime signal peer does not match session"));
        }
        match kind {
            RealtimeSignalKind::IceCandidate => {
                if revision != session.ice_revision {
                    return Err(boxed_message("stale realtime ICE generation"));
                }
                if session.seen_candidates.contains(&payload) {
                    return Err(boxed_message("replayed realtime ICE candidate"));
                }
            }
            _ if revision <= session.remote_revision => {
                return Err(boxed_message("stale realtime signaling revision"));
            }
            _ => {}
        }
    }

    match kind {
        RealtimeSignalKind::WebRtcOffer => {
            let had_generation = manager.session_generations.contains_key(realtime_id);
            let existing = manager.sessions.remove(realtime_id);
            let had_existing = existing.is_some();
            let mut session = match existing {
                Some(session) => session,
                None => match pending_driver {
                    Some(driver) => RealtimeSession {
                        peer_id: peer_id.to_string(),
                        connection_session_id,
                        peer: None,
                        driver: Some(driver),
                        revision: 0,
                        remote_revision: 0,
                        ice_revision: 0,
                        seen_candidates: HashSet::new(),
                    },
                    None => RealtimeSession {
                        peer_id: peer_id.to_string(),
                        connection_session_id,
                        peer: Some(
                            WebRtcPeer::new(WebRtcConfig::default())
                                .expect("validated default WebRTC configuration"),
                        ),
                        driver: None,
                        revision: 0,
                        remote_revision: 0,
                        ice_revision: 0,
                        seen_candidates: HashSet::new(),
                    },
                },
            };
            let description = match String::from_utf8(payload)
                .map_err(|error| boxed_message(error.to_string()))
                .and_then(|sdp| {
                    SessionDescription::new(DescriptionType::Offer, sdp)
                        .map_err(|error| boxed_message(error.to_string()))
                }) {
                Ok(description) => description,
                Err(error) => {
                    if had_existing {
                        manager.insert_existing_session(realtime_id.to_string(), session);
                    }
                    return Err(error);
                }
            };
            if let Err(error) =
                with_session_peer(&mut session, |peer| peer.accept_remote_offer(description))
            {
                if had_existing {
                    manager.insert_existing_session(realtime_id.to_string(), session);
                }
                return Err(boxed_message(error.to_string()));
            }
            let answer = match with_session_peer(&mut session, WebRtcPeer::create_answer) {
                Ok(answer) => answer,
                Err(error) => {
                    if had_existing {
                        manager.insert_existing_session(realtime_id.to_string(), session);
                    }
                    return Err(boxed_message(error.to_string()));
                }
            };
            let answer_revision = with_session_peer(&mut session, |peer| {
                Ok::<_, WebRtcError>(peer.signaling_revision())
            })
            .map_err(|error| boxed_message(error.to_string()))?
            .max(revision);
            session.revision = answer_revision;
            session.remote_revision = revision;
            session.ice_revision = revision;
            session.seen_candidates.clear();
            let peer_id = session.peer_id.clone();
            if had_existing || had_generation {
                manager.insert_existing_session(realtime_id.to_string(), session);
            } else {
                manager.insert_new_session(realtime_id.to_string(), session);
            }
            let generation = manager
                .session_generation(realtime_id)
                .ok_or_else(|| boxed_message("realtime session generation missing"))?;
            Ok(SignalOutcome {
                peer_id: peer_id.clone(),
                revision: answer_revision,
                generation,
                state: RealtimeSessionState::Negotiating,
                outbound: Some(OutboundSignal {
                    realtime_id: realtime_id.to_string(),
                    peer_id,
                    kind: RealtimeSignalKind::WebRtcAnswer,
                    revision: answer_revision,
                    payload: answer.sdp.into_bytes(),
                }),
            })
        }
        RealtimeSignalKind::WebRtcAnswer => {
            let generation = manager.session_generation(realtime_id).unwrap_or_default();
            let session = manager
                .sessions
                .get_mut(realtime_id)
                .ok_or_else(|| boxed_message("realtime session does not exist"))?;
            let description =
                SessionDescription::new(DescriptionType::Answer, String::from_utf8(payload)?)?;
            with_session_peer(&mut *session, |peer| peer.accept_remote_answer(description))?;
            session.revision = with_session_peer(&mut *session, |peer| {
                Ok::<_, WebRtcError>(peer.signaling_revision())
            })?
            .max(revision);
            session.remote_revision = revision;
            Ok(SignalOutcome {
                peer_id: session.peer_id.clone(),
                revision: session.revision,
                generation,
                state: RealtimeSessionState::Connected,
                outbound: None,
            })
        }
        RealtimeSignalKind::IceCandidate => {
            let generation = manager.session_generation(realtime_id).unwrap_or_default();
            let session = manager
                .sessions
                .get_mut(realtime_id)
                .ok_or_else(|| boxed_message("realtime session does not exist"))?;
            let candidate =
                IceCandidate::new(String::from_utf8(payload.clone())?, None, None, None)?;
            with_session_peer(&mut *session, |peer| {
                peer.add_remote_ice_candidate(candidate)
            })?;
            session.seen_candidates.insert(payload);
            Ok(SignalOutcome {
                peer_id: session.peer_id.clone(),
                revision: session.revision,
                generation,
                state: RealtimeSessionState::Negotiating,
                outbound: None,
            })
        }
        RealtimeSignalKind::IceRestart => {
            let generation = manager.session_generation(realtime_id).unwrap_or_default();
            let session = manager
                .sessions
                .get_mut(realtime_id)
                .ok_or_else(|| boxed_message("realtime session does not exist"))?;
            with_session_peer(&mut *session, WebRtcPeer::restart_ice)?;
            let offer = with_session_peer(&mut *session, WebRtcPeer::create_offer)?;
            session.revision = with_session_peer(&mut *session, |peer| {
                Ok::<_, WebRtcError>(peer.signaling_revision())
            })?
            .max(revision);
            session.remote_revision = revision;
            session.ice_revision = session.revision;
            session.seen_candidates.clear();
            Ok(SignalOutcome {
                peer_id: session.peer_id.clone(),
                revision: session.revision,
                generation,
                state: RealtimeSessionState::Restarting,
                outbound: Some(OutboundSignal {
                    realtime_id: realtime_id.to_string(),
                    peer_id: session.peer_id.clone(),
                    kind: RealtimeSignalKind::WebRtcOffer,
                    revision: session.revision,
                    payload: offer.sdp.into_bytes(),
                }),
            })
        }
        RealtimeSignalKind::ScreenShareConsent => Err(boxed_message(
            "screen-share consent must be handled before WebRTC state transitions",
        )),
        RealtimeSignalKind::Unspecified | RealtimeSignalKind::WebRtcClose => {
            Err(boxed_message("unsupported WebRTC signal kind"))
        }
    }
}

fn with_session_peer<T>(
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

fn runtime_webrtc_config() -> WebRtcConfig {
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

fn runtime_webrtc_config_from_values(
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

async fn create_io_driver(
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

fn realtime_task_key(realtime_id: &str) -> String {
    format!("realtime:{realtime_id}")
}

async fn run_realtime_session_io(
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
                    emit_realtime_state(
                        &state.event_tx,
                        &realtime_id,
                        &peer_id,
                        RealtimeSessionState::Failed as i32,
                        revision,
                        generation,
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

async fn handle_io_event(
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
            emit_realtime_state(
                &state.event_tx,
                realtime_id,
                peer_id,
                RealtimeSessionState::Connected as i32,
                revision,
                generation,
                None,
            );
            // Session 稳定后发布完整快照；订阅方在 delta 状态之后看到一致快照。
            emit_realtime_snapshot(
                &state.event_tx,
                realtime_id,
                peer_id,
                RealtimeSessionState::Connected as i32,
                revision,
                generation,
                None,
            );
            false
        }
        RealtimeIoEvent::PeerDisconnected
        | RealtimeIoEvent::PeerFailed
        | RealtimeIoEvent::IceFailed => {
            let generation = session_generation(state, realtime_id).await;
            emit_realtime_state(
                &state.event_tx,
                realtime_id,
                peer_id,
                RealtimeSessionState::Failed as i32,
                session_revision(state, realtime_id).await,
                generation,
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

fn take_realtime_session_if_owned(
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

async fn remove_realtime_session_if_owned(
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
async fn remove_realtime_session(state: &RuntimeState, realtime_id: &str, peer_id: &str) {
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
    for (realtime_id, session_peer_id, close_revision, generation) in closed {
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
            generation,
            None,
        );
    }
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

async fn session_revision(state: &RuntimeState, realtime_id: &str) -> u64 {
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

async fn forward_local_candidate(
    state: &RuntimeState,
    realtime_id: &str,
    peer_id: &str,
    candidate: IceCandidate,
) {
    let (session_peer_id, revision) = {
        let sessions = state.realtime.lock().await;
        let Some(session) = sessions.sessions.get(realtime_id) else {
            return;
        };
        (session.peer_id.clone(), session.ice_revision)
    };
    if session_peer_id != peer_id {
        return;
    }
    let payload = candidate.candidate.into_bytes();
    let outbound = OutboundSignal {
        realtime_id: realtime_id.to_owned(),
        peer_id: peer_id.to_owned(),
        kind: RealtimeSignalKind::IceCandidate,
        revision,
        payload,
    };
    if let Err(error) = send_signal(state, &outbound).await {
        tracing::debug!(peer_id, error = %error.message, "failed to forward WebRTC ICE candidate");
        return;
    }
    emit_realtime_signal(
        &state.event_tx,
        realtime_id,
        peer_id,
        RealtimeSignalKind::IceCandidate as i32,
        revision,
        outbound.payload,
    );
}

async fn validate_peer(
    state: &RuntimeState,
    peer_id: &str,
) -> Result<(), network_protocol::NetworkError> {
    if peer_id.is_empty() || peer_id.len() > 128 || !state.peers.read().await.contains_key(peer_id)
    {
        return Err(protocol_error_with_peer(
            network_protocol::NetworkErrorCode::NoRoute,
            "realtime peer is not registered",
            "realtime",
            peer_id,
        ));
    }
    Ok(())
}

fn validate_realtime_id(id: &str) -> Result<(), network_protocol::NetworkError> {
    if id.len() != 32
        || id != id.to_ascii_lowercase()
        || hex::decode(id).map_or(true, |bytes| bytes.len() != 16)
    {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "realtime_id must be 32 lowercase hexadecimal characters",
        ));
    }
    Ok(())
}

fn validate_signal(
    kind: RealtimeSignalKind,
    revision: u64,
    payload: &[u8],
) -> Result<(), network_protocol::NetworkError> {
    if revision == 0 || payload.len() > MAX_REALTIME_SIGNAL_PAYLOAD_BYTES {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "WebRTC signal revision or payload is outside bounds",
        ));
    }
    if kind == RealtimeSignalKind::IceCandidate && payload.len() > MAX_ICE_CANDIDATE_BYTES {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "ICE candidate payload is outside bounds",
        ));
    }
    if !matches!(
        kind,
        RealtimeSignalKind::WebRtcClose
            | RealtimeSignalKind::IceRestart
            | RealtimeSignalKind::IceCandidate
    ) && payload.is_empty()
    {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "WebRTC signal payload must not be empty",
        ));
    }
    if kind == RealtimeSignalKind::ScreenShareConsent && payload.len() > 4096 {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "screen-share consent payload is outside bounds",
        ));
    }
    Ok(())
}

/// Validates the typed ScreenShareConsentV2 payload at the native control
/// boundary. `expected_sender_peer_id` is supplied for inbound signals where
/// the authenticated realtime binding is authoritative; local outgoing
/// commands perform the structural checks without guessing the sender ID.
fn validate_screen_share_consent(
    payload: &[u8],
    expected_realtime_id: &str,
    expected_sender_peer_id: Option<&str>,
) -> Result<ScreenShareConsentV2, Box<dyn std::error::Error + Send + Sync>> {
    if payload.is_empty() || payload.len() > 4096 {
        return Err(boxed_message(
            "screen-share consent payload is outside bounds",
        ));
    }
    let consent = ScreenShareConsentV2::decode(payload)
        .map_err(|error| boxed_message(format!("malformed screen-share consent: {error}")))?;
    if consent.schema_version != 2 {
        return Err(boxed_message(
            "unsupported screen-share consent schema version",
        ));
    }
    if consent.operation_id.is_empty() || consent.operation_id.len() > 128 {
        return Err(boxed_message(
            "screen-share consent operation_id is outside bounds",
        ));
    }
    if consent.realtime_id != expected_realtime_id {
        return Err(boxed_message(
            "screen-share consent realtime_id does not match signal",
        ));
    }
    if consent.issued_at_ms == 0
        || consent.expires_at_ms <= consent.issued_at_ms
        || consent.expires_at_ms.saturating_sub(consent.issued_at_ms) > 120_000
    {
        return Err(boxed_message("screen-share consent expiration is invalid"));
    }
    if consent.sender_peer_id.is_empty() || consent.sender_peer_id.len() > 128 {
        return Err(boxed_message(
            "screen-share consent sender_peer_id is outside bounds",
        ));
    }
    if let Some(expected) = expected_sender_peer_id {
        if consent.sender_peer_id != expected {
            return Err(boxed_message(
                "screen-share consent sender does not match peer binding",
            ));
        }
    }
    if ScreenShareConsentDecision::try_from(consent.decision)
        .map_err(|_| boxed_message("unknown screen-share consent decision"))?
        == ScreenShareConsentDecision::Unspecified
    {
        return Err(boxed_message(
            "screen-share consent decision is unspecified",
        ));
    }
    if ScreenShareConsentPurpose::try_from(consent.purpose)
        .map_err(|_| boxed_message("unknown screen-share consent purpose"))?
        != ScreenShareConsentPurpose::ScreenShare
    {
        return Err(boxed_message("screen-share consent purpose is unsupported"));
    }
    if ScreenShareMediaKind::try_from(consent.media)
        .map_err(|_| boxed_message("unknown screen-share media kind"))?
        != ScreenShareMediaKind::ScreenVideo
    {
        return Err(boxed_message("screen-share media kind is unsupported"));
    }
    if !consent.requires_acceptance || consent.action_revision == 0 {
        return Err(boxed_message(
            "screen-share consent acceptance/revision is invalid",
        ));
    }
    Ok(consent)
}

/// §22：WebRTC 信令经 v2 Relay Control Plane 路由（`signal_webrtc`），与媒体面
/// (P2P/TURN) 分离。v1 Relay 数据面信令路径已在 Step 11 删除。
async fn send_signal(
    state: &RuntimeState,
    signal: &OutboundSignal,
) -> Result<(), network_protocol::NetworkError> {
    let Some(control) = state.relay.control.read().await.clone() else {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::RelayError,
            "Relay signaling route is unavailable",
        ));
    };
    if !control.is_usable().await {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::RelayError,
            "Relay signaling route is disconnected",
        ));
    }
    let kind = to_v2_signal_kind(signal.kind);
    control
        .signal_webrtc_wire_kind(
            &signal.realtime_id,
            &signal.peer_id,
            kind,
            signal.revision,
            &signal.payload,
        )
        .await
        .map_err(|error| {
            realtime_error(
                network_protocol::NetworkErrorCode::RelayError,
                error.to_string(),
                "send_realtime_signal",
                &signal.peer_id,
            )
        })
}

/// Maps a network-protocol WebRTC signal to its frozen Relay V2 wire number.
///
/// Screen-share consent is defined by Network V2, while Relay V2's descriptor
/// remains frozen.  Its value (6) is intentionally sent as an unknown enum
/// number and forwarded transparently by the Relay control plane.
fn to_v2_signal_kind(kind: RealtimeSignalKind) -> i32 {
    match kind {
        RealtimeSignalKind::WebRtcOffer => V2RealtimeSignalKind::Offer as i32,
        RealtimeSignalKind::WebRtcAnswer => V2RealtimeSignalKind::Answer as i32,
        RealtimeSignalKind::IceCandidate => V2RealtimeSignalKind::IceCandidate as i32,
        RealtimeSignalKind::IceRestart => V2RealtimeSignalKind::IceRestart as i32,
        RealtimeSignalKind::WebRtcClose => V2RealtimeSignalKind::Close as i32,
        RealtimeSignalKind::ScreenShareConsent => 6,
        RealtimeSignalKind::Unspecified => V2RealtimeSignalKind::Unspecified as i32,
    }
}

fn realtime_error(
    code: network_protocol::NetworkErrorCode,
    message: impl Into<String>,
    operation: &str,
    peer_id: &str,
) -> network_protocol::NetworkError {
    protocol_error_with_peer(code, message, operation, peer_id)
}

fn boxed_protocol_error(
    error: network_protocol::NetworkError,
) -> Box<dyn std::error::Error + Send + Sync> {
    boxed_message(error.message)
}

fn boxed_message(message: impl Into<String>) -> Box<dyn std::error::Error + Send + Sync> {
    std::io::Error::new(std::io::ErrorKind::InvalidData, message.into()).into()
}

#[cfg(test)]
#[path = "tests/realtime.rs"]
mod tests;
