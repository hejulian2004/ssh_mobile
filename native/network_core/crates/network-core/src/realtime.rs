//! WebRTC realtime Session integration.
//!
//! Realtime media is deliberately a sibling of the ordinary Data Route. This
//! module owns only the native WebRTC peer and signaling revision; keyboard,
//! clipboard, files, Delivery, and Relay recovery remain on their existing
//! QUIC/Relay paths.

use network_protocol::{
    ClaimIncomingRealtimeOfferCommand, DiscardIncomingRealtimeOfferCommand, RealtimeSessionState,
    RealtimeSignalEnvelope, RealtimeSignalKind, RejectIncomingRealtimeOfferCommand,
    ScreenShareConsentDecision, ScreenShareConsentPurpose, ScreenShareConsentV2,
    ScreenShareMediaKind, SendRealtimeSignalCommand, StartRealtimeSessionCommand,
    StopRealtimeSessionCommand,
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
use rand::RngCore;
use std::collections::{HashMap, HashSet, VecDeque};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::mpsc;
#[cfg(test)]
use tokio::sync::mpsc::unbounded_channel;

use crate::events::{
    emit_realtime_signal, emit_realtime_snapshot, emit_realtime_state, protocol_error,
    protocol_error_with_peer, RealtimeSessionIdentity,
};
use crate::runtime::RuntimeState;
use crate::session::SessionId;

const MAX_REALTIME_SIGNAL_PAYLOAD_BYTES: usize = MAX_SDP_BYTES;
const SCREEN_SHARE_CONSENT_MAX_LIFETIME_MS: u64 = 120_000;
const SCREEN_SHARE_CONSENT_ALLOWED_FUTURE_SKEW_MS: u64 = 30_000;
pub(crate) const MAX_PROVISIONAL_ICE_CANDIDATES: usize = 128;
pub(crate) const MAX_PROVISIONAL_ICE_CANDIDATE_BYTES: usize = MAX_ICE_CANDIDATE_BYTES;
pub(crate) const MAX_PROVISIONAL_ICE_TOTAL_BYTES: usize = 256 * 1024;
pub(crate) const MAX_PROVISIONAL_BINDING_LIFETIME_MS: u64 = 120_000;
const MAX_PROVISIONAL_OPERATIONS: usize = 32;
static NEXT_REALTIME_SESSION_GENERATION: AtomicU64 = AtomicU64::new(1);

struct RealtimeSession {
    peer_id: String,
    /// Cross-device identity for the current realtime session instance. This
    /// is carried in the signaling envelope and consent metadata; it is
    /// deliberately separate from the process-local native generation.
    shared_session_instance_id: String,
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ProvisionalBindingState {
    Pending,
    Claiming,
    Claimed,
    Terminal,
}

struct ProvisionalIceCandidate {
    revision: u64,
    payload: Vec<u8>,
}

/// Native-only responder state. The binding deliberately keeps raw Offer/ICE
/// and the claim token out of Dart until a user-facing REQUEST has paired with
/// the authenticated Offer.
struct ProvisionalScreenShareBinding {
    offer_id: String,
    claim_token: String,
    authenticated_peer_id: String,
    realtime_id: String,
    shared_session_instance_id: String,
    offer_revision: u64,
    offer_payload: Vec<u8>,
    ice_candidates: VecDeque<ProvisionalIceCandidate>,
    ice_total_bytes: usize,
    request: Option<ScreenShareConsentV2>,
    binding_expires_at_ms: u64,
    effective_expires_at_ms: u64,
    published_to_app: bool,
    state: ProvisionalBindingState,
}

impl ProvisionalScreenShareBinding {
    fn is_expired(&self, now_ms: u64) -> bool {
        now_ms >= self.binding_expires_at_ms || now_ms >= self.effective_expires_at_ms
    }

    fn push_ice(
        &mut self,
        revision: u64,
        payload: Vec<u8>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if revision != self.offer_revision {
            return Err(boxed_message("stale provisional ICE revision"));
        }
        if payload.len() > MAX_PROVISIONAL_ICE_CANDIDATE_BYTES {
            return Err(boxed_message("provisional ICE candidate is outside bounds"));
        }
        if self.ice_candidates.len() >= MAX_PROVISIONAL_ICE_CANDIDATES
            || self.ice_total_bytes.saturating_add(payload.len()) > MAX_PROVISIONAL_ICE_TOTAL_BYTES
        {
            return Err(boxed_message("provisional ICE queue is outside bounds"));
        }
        if self
            .ice_candidates
            .iter()
            .any(|candidate| candidate.revision == revision && candidate.payload == payload)
        {
            return Err(boxed_message("replayed provisional ICE candidate"));
        }
        self.ice_total_bytes = self.ice_total_bytes.saturating_add(payload.len());
        self.ice_candidates
            .push_back(ProvisionalIceCandidate { revision, payload });
        Ok(())
    }
}

#[derive(Default)]
pub(crate) struct RealtimeManager {
    sessions: HashMap<String, RealtimeSession>,
    provisional: HashMap<String, ProvisionalScreenShareBinding>,
    provisional_requests: HashMap<String, ProvisionalPendingRequest>,
    /// Generation is owned by the live Realtime manager, not inferred by the
    /// media registry. It changes whenever a new session is inserted for an ID.
    session_generations: HashMap<String, u64>,
}

struct ProvisionalPendingRequest {
    authenticated_peer_id: String,
    shared_session_instance_id: String,
    request: ScreenShareConsentV2,
    expires_at_ms: u64,
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
    ) -> Vec<(String, String, u64, u64, String)> {
        self.close_for_connection_session_with_hook(peer_id, session_id, |_| {})
    }

    /// Variant used by runtime teardown to revoke borrowed media leases before
    /// closing the peer that owns their queues.
    fn close_for_connection_session_with_hook(
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

struct OutboundSignal {
    realtime_id: String,
    peer_id: String,
    shared_session_instance_id: String,
    kind: RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
}

/// 一条已解码的入站 WebRTC 信令。v1 信封（revision 内嵌）与 v2 控制面帧
/// （revision 独立字段）在进入状态机前都归一化为该三元组。
struct InboundSignal {
    shared_session_instance_id: String,
    kind: RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
}

struct SignalOutcome {
    peer_id: String,
    shared_session_instance_id: String,
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

/// Atomically promotes one metadata-paired provisional binding into the exact
/// responder generation registered by the SDK. The binding remains `Claiming`
/// while the Answer is sent so late ICE can continue entering the same
/// protected queue; only after that queue is drained is it committed as a
/// formal session.
pub(crate) async fn claim_incoming_offer(
    state: Arc<RuntimeState>,
    command: ClaimIncomingRealtimeOfferCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    validate_peer(&state, &command.peer_id).await?;
    let now_ms = crate::events::unix_timestamp_ms().max(0) as u64;
    let (offer, offer_revision, queued_ice, shared_session_instance_id) = {
        let mut manager = state.realtime.lock().await;
        prune_provisional_bindings(&mut manager, now_ms);
        let Some(binding) = manager.provisional.get_mut(&command.realtime_id) else {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "incoming realtime offer does not exist",
                "claim_incoming_realtime_offer",
                &command.peer_id,
            ));
        };
        if binding.claim_token != command.claim_token
            || binding.authenticated_peer_id != command.peer_id
            || !matches!(binding.state, ProvisionalBindingState::Pending)
            || binding.request.is_none()
        {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "incoming realtime offer claim is stale or incomplete",
                "claim_incoming_realtime_offer",
                &command.peer_id,
            ));
        }
        binding.state = ProvisionalBindingState::Claiming;
        let queued_ice = binding.ice_candidates.drain(..).collect::<Vec<_>>();
        binding.ice_total_bytes = 0;
        (
            binding.offer_payload.clone(),
            binding.offer_revision,
            queued_ice,
            binding.shared_session_instance_id.clone(),
        )
    };
    let driver = match create_io_driver(&state, runtime_webrtc_config()).await {
        Ok(driver) => driver.into_handle(),
        Err(error) => {
            let mut manager = state.realtime.lock().await;
            if let Some(mut binding) = manager.provisional.remove(&command.realtime_id) {
                binding.state = ProvisionalBindingState::Terminal;
            }
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::IoError,
                error.to_string(),
                "claim_incoming_realtime_offer",
                &command.peer_id,
            ));
        }
    };
    let connection_session_id = state
        .connection_sessions
        .current_session_id(&command.peer_id)
        .await;
    let outcome = {
        let mut manager = state.realtime.lock().await;
        let binding_valid = manager
            .provisional
            .get(&command.realtime_id)
            .is_some_and(|binding| {
                binding.claim_token == command.claim_token
                    && matches!(binding.state, ProvisionalBindingState::Claiming)
            });
        if !binding_valid {
            if let Ok(mut driver) = driver.lock() {
                let _ = driver.close();
            }
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::StaleOperation,
                "incoming realtime offer claim was superseded",
                "claim_incoming_realtime_offer",
                &command.peer_id,
            ));
        }
        let outcome = apply_signal_with_driver(
            &mut manager,
            &command.realtime_id,
            &command.peer_id,
            InboundSignal {
                shared_session_instance_id: shared_session_instance_id.clone(),
                kind: RealtimeSignalKind::WebRtcOffer,
                revision: offer_revision,
                payload: offer,
            },
            Some(driver.clone()),
            connection_session_id,
        );
        let outcome = match outcome {
            Ok(outcome) => outcome,
            Err(error) => {
                drop(manager);
                rollback_incoming_claim(
                    &state,
                    &command.realtime_id,
                    &command.peer_id,
                    &command.claim_token,
                    &driver,
                )
                .await;
                return Err(realtime_error(
                    network_protocol::NetworkErrorCode::IoError,
                    error.to_string(),
                    "claim_incoming_realtime_offer",
                    &command.peer_id,
                ));
            }
        };
        for candidate in queued_ice {
            if let Err(error) = apply_signal_with_driver(
                &mut manager,
                &command.realtime_id,
                &command.peer_id,
                InboundSignal {
                    shared_session_instance_id: shared_session_instance_id.clone(),
                    kind: RealtimeSignalKind::IceCandidate,
                    revision: candidate.revision,
                    payload: candidate.payload,
                },
                None,
                None,
            ) {
                drop(manager);
                rollback_incoming_claim(
                    &state,
                    &command.realtime_id,
                    &command.peer_id,
                    &command.claim_token,
                    &driver,
                )
                .await;
                return Err(realtime_error(
                    network_protocol::NetworkErrorCode::IoError,
                    error.to_string(),
                    "claim_incoming_realtime_offer",
                    &command.peer_id,
                ));
            }
        }
        outcome
    };

    let cleanup_driver = Arc::clone(&driver);
    if state
        .task_supervisor
        .spawn_session(
            realtime_task_key(&command.realtime_id),
            "realtime-io",
            run_realtime_session_io(
                Arc::clone(&state),
                command.realtime_id.clone(),
                command.peer_id.clone(),
                driver,
            ),
        )
        .is_none()
    {
        rollback_incoming_claim(
            &state,
            &command.realtime_id,
            &command.peer_id,
            &command.claim_token,
            &cleanup_driver,
        )
        .await;
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::Cancelled,
            "runtime task supervisor is stopping",
            "claim_incoming_realtime_offer",
            &command.peer_id,
        ));
    }
    let Some(answer) = outcome.outbound else {
        state
            .task_supervisor
            .cancel_session(&realtime_task_key(&command.realtime_id))
            .await;
        rollback_incoming_claim(
            &state,
            &command.realtime_id,
            &command.peer_id,
            &command.claim_token,
            &cleanup_driver,
        )
        .await;
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::IoError,
            "incoming realtime claim produced no Answer",
            "claim_incoming_realtime_offer",
            &command.peer_id,
        ));
    };
    if let Err(error) = send_signal(&state, &answer).await {
        state
            .task_supervisor
            .cancel_session(&realtime_task_key(&command.realtime_id))
            .await;
        rollback_incoming_claim(
            &state,
            &command.realtime_id,
            &command.peer_id,
            &command.claim_token,
            &cleanup_driver,
        )
        .await;
        return Err(error);
    }

    let mut late_ice_failed = None;
    {
        let mut manager = state.realtime.lock().await;
        let queued_late = manager
            .provisional
            .get_mut(&command.realtime_id)
            .filter(|binding| binding.claim_token == command.claim_token)
            .map(|binding| {
                let queued = binding.ice_candidates.drain(..).collect::<Vec<_>>();
                binding.ice_total_bytes = 0;
                queued
            })
            .unwrap_or_default();
        for candidate in queued_late {
            if let Err(error) = apply_signal_with_driver(
                &mut manager,
                &command.realtime_id,
                &command.peer_id,
                InboundSignal {
                    shared_session_instance_id: shared_session_instance_id.clone(),
                    kind: RealtimeSignalKind::IceCandidate,
                    revision: candidate.revision,
                    payload: candidate.payload,
                },
                None,
                None,
            ) {
                late_ice_failed = Some(error);
                break;
            }
        }
        if late_ice_failed.is_none() {
            if let Some(binding) = manager.provisional.get_mut(&command.realtime_id) {
                binding.state = ProvisionalBindingState::Claimed;
            }
            manager.provisional.remove(&command.realtime_id);
        }
    }
    if let Some(error) = late_ice_failed {
        state
            .task_supervisor
            .cancel_session(&realtime_task_key(&command.realtime_id))
            .await;
        rollback_incoming_claim(
            &state,
            &command.realtime_id,
            &command.peer_id,
            &command.claim_token,
            &cleanup_driver,
        )
        .await;
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::IoError,
            error.to_string(),
            "claim_incoming_realtime_offer",
            &command.peer_id,
        ));
    }
    emit_realtime_signal(
        &state.event_tx,
        &answer.realtime_id,
        &answer.peer_id,
        answer.kind as i32,
        answer.revision,
        answer.payload,
    );
    emit_realtime_state(
        &state.event_tx,
        &command.realtime_id,
        &command.peer_id,
        RealtimeSessionState::Negotiating as i32,
        outcome.revision,
        RealtimeSessionIdentity::new(outcome.generation, &outcome.shared_session_instance_id),
        None,
    );
    Ok(())
}

async fn rollback_incoming_claim(
    state: &RuntimeState,
    realtime_id: &str,
    peer_id: &str,
    claim_token: &str,
    driver: &RealtimeIoDriverHandle,
) {
    let removed = {
        let mut manager = state.realtime.lock().await;
        if manager.provisional.get(realtime_id).is_some_and(|binding| {
            binding.claim_token == claim_token && binding.state == ProvisionalBindingState::Claiming
        }) {
            if let Some(mut binding) = manager.provisional.remove(realtime_id) {
                binding.state = ProvisionalBindingState::Terminal;
            }
        }
        let removed = take_realtime_session_if_owned(&mut manager, realtime_id, peer_id, driver);
        if removed.is_some() {
            crate::realtime_media::invalidate_realtime(state, realtime_id);
        }
        removed
    };
    if let Some(mut session) = removed {
        let _ = with_session_peer(&mut session, WebRtcPeer::close);
    } else if let Ok(mut driver) = driver.lock() {
        let _ = driver.close();
    }
}

pub(crate) async fn reject_incoming_offer(
    state: &RuntimeState,
    command: RejectIncomingRealtimeOfferCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    validate_peer(state, &command.peer_id).await?;
    let (request, shared_session_instance_id, offer_revision) = {
        let mut manager = state.realtime.lock().await;
        prune_provisional_bindings(
            &mut manager,
            crate::events::unix_timestamp_ms().max(0) as u64,
        );
        let Some(binding) = manager.provisional.get(&command.realtime_id) else {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "incoming realtime offer does not exist",
                "reject_incoming_realtime_offer",
                &command.peer_id,
            ));
        };
        if binding.claim_token != command.claim_token
            || binding.authenticated_peer_id != command.peer_id
            || !matches!(binding.state, ProvisionalBindingState::Pending)
        {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "incoming realtime offer rejection is stale",
                "reject_incoming_realtime_offer",
                &command.peer_id,
            ));
        }
        let request = binding.request.clone().ok_or_else(|| {
            realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "incoming realtime request is incomplete",
                "reject_incoming_realtime_offer",
                &command.peer_id,
            )
        })?;
        let shared_session_instance_id = binding.shared_session_instance_id.clone();
        let offer_revision = binding.offer_revision;
        (request, shared_session_instance_id, offer_revision)
    };
    let identity = state
        .lifecycle
        .identity
        .read()
        .await
        .clone()
        .ok_or_else(|| {
            realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "local realtime identity is unavailable",
                "reject_incoming_realtime_offer",
                &command.peer_id,
            )
        })?;
    let now_ms = crate::events::unix_timestamp_ms().max(0) as u64;
    let mut reject = request;
    reject.issued_at_ms = now_ms;
    reject.expires_at_ms = reject
        .expires_at_ms
        .min(now_ms.saturating_add(SCREEN_SHARE_CONSENT_MAX_LIFETIME_MS));
    reject.decision = ScreenShareConsentDecision::Reject as i32;
    reject.sender_peer_id = identity.device_id.clone();
    reject.action_revision = 1;
    let payload = reject.encode_to_vec();
    validate_screen_share_consent(
        &payload,
        &command.realtime_id,
        None,
        Some(&shared_session_instance_id),
    )
    .map_err(|error| {
        realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            error.to_string(),
            "reject_incoming_realtime_offer",
            &command.peer_id,
        )
    })?;
    let outbound = OutboundSignal {
        realtime_id: command.realtime_id.clone(),
        peer_id: command.peer_id.clone(),
        shared_session_instance_id,
        kind: RealtimeSignalKind::ScreenShareConsent,
        revision: offer_revision.max(1),
        payload,
    };
    {
        let mut manager = state.realtime.lock().await;
        let exact_pending = manager
            .provisional
            .get(&command.realtime_id)
            .is_some_and(|binding| {
                binding.claim_token == command.claim_token
                    && binding.authenticated_peer_id == command.peer_id
                    && binding.state == ProvisionalBindingState::Pending
            });
        if !exact_pending {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::StaleOperation,
                "incoming realtime offer rejection was superseded",
                "reject_incoming_realtime_offer",
                &command.peer_id,
            ));
        }
        if let Some(binding) = manager.provisional.get_mut(&command.realtime_id) {
            binding.state = ProvisionalBindingState::Claiming;
        }
    }
    if let Err(error) = send_signal(state, &outbound).await {
        let mut manager = state.realtime.lock().await;
        if manager
            .provisional
            .get(&command.realtime_id)
            .is_some_and(|binding| {
                binding.claim_token == command.claim_token
                    && binding.state == ProvisionalBindingState::Claiming
            })
        {
            if let Some(mut binding) = manager.provisional.remove(&command.realtime_id) {
                binding.state = ProvisionalBindingState::Terminal;
            }
        }
        return Err(error);
    }
    emit_realtime_signal(
        &state.event_tx,
        &outbound.realtime_id,
        &outbound.peer_id,
        outbound.kind as i32,
        outbound.revision,
        outbound.payload,
    );
    let mut manager = state.realtime.lock().await;
    if manager
        .provisional
        .get(&command.realtime_id)
        .is_some_and(|binding| {
            binding.claim_token == command.claim_token
                && binding.state == ProvisionalBindingState::Claiming
        })
    {
        if let Some(mut binding) = manager.provisional.remove(&command.realtime_id) {
            binding.state = ProvisionalBindingState::Terminal;
        }
    }
    Ok(())
}

pub(crate) async fn discard_incoming_offer(
    state: &RuntimeState,
    command: DiscardIncomingRealtimeOfferCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    validate_peer(state, &command.peer_id).await?;
    let mut manager = state.realtime.lock().await;
    let Some(binding) = manager.provisional.get(&command.realtime_id) else {
        return Ok(());
    };
    if binding.claim_token != command.claim_token
        || binding.authenticated_peer_id != command.peer_id
    {
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "incoming realtime offer discard is stale",
            "discard_incoming_realtime_offer",
            &command.peer_id,
        ));
    }
    if let Some(mut binding) = manager.provisional.remove(&command.realtime_id) {
        binding.state = ProvisionalBindingState::Terminal;
    }
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
    let (session_peer_id, session_shared_session_instance_id, session_revision, ice_revision) = {
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
            session.shared_session_instance_id.clone(),
            session.revision,
            session.ice_revision,
        )
    };
    if kind == RealtimeSignalKind::ScreenShareConsent {
        validate_screen_share_consent(
            &command.payload,
            &command.realtime_id,
            None,
            Some(&session_shared_session_instance_id),
        )
        .map_err(|error| {
            realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                error.to_string(),
                "send_realtime_signal",
                &command.peer_id,
            )
        })?;
    }
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
        shared_session_instance_id: session_shared_session_instance_id,
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
/// `RealtimeSignal` 帧携带独立 `revision`，payload 是 native-owned envelope；
/// envelope 把信令绑定到跨设备共享的 session instance，而不是 process-local
/// native generation。新 Relay V2 帧携带由 Relay 写入的 authenticated source；
/// 已绑定 session 仍兼容 source 缺省的旧 Relay，未知 session 则必须有 source。
pub(crate) async fn handle_v2_realtime_signal(
    state: &Arc<RuntimeState>,
    signal: &V2RealtimeSignal,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let bound_peer_id = state
        .realtime
        .lock()
        .await
        .sessions
        .get(&signal.realtime_id)
        .map(|session| session.peer_id.clone());
    let source_peer_id = signal.source_device_id.trim();
    if !source_peer_id.is_empty() {
        validate_peer(state, source_peer_id)
            .await
            .map_err(boxed_protocol_error)?;
        if bound_peer_id
            .as_deref()
            .is_some_and(|bound| bound != source_peer_id)
        {
            return Err(boxed_message(
                "v2 WebRTC signal source does not match session binding",
            ));
        }
    }
    let peer_id = bound_peer_id
        .clone()
        .or_else(|| (!source_peer_id.is_empty()).then(|| source_peer_id.to_owned()))
        .ok_or_else(|| boxed_message("v2 WebRTC signal has no authenticated source"))?;
    if peer_id.is_empty() {
        return Err(boxed_message(
            "v2 WebRTC signal has an empty established peer binding",
        ));
    }
    let (shared_session_instance_id, payload) = decode_realtime_signal_payload(&signal.payload)
        .map_err(|error| boxed_message(error.to_string()))?;
    let kind = RealtimeSignalKind::try_from(signal.kind)
        .map_err(|_| boxed_message("invalid v2 WebRTC signal kind"))?;
    if bound_peer_id.is_none() {
        return handle_provisional_realtime_signal(
            state,
            kind,
            &signal.realtime_id,
            &peer_id,
            signal.revision,
            shared_session_instance_id,
            payload,
        )
        .await;
    }
    handle_realtime_signal(
        state,
        kind,
        &signal.realtime_id,
        &peer_id,
        signal.revision,
        shared_session_instance_id,
        payload,
    )
    .await
}

/// Handles signals for a realtime ID that has not yet been accepted locally.
///
/// This path is deliberately native-only. An Offer and its trickled ICE are
/// retained in a bounded provisional binding, while the typed REQUEST is held
/// separately until both halves can be paired. No responder PeerConnection,
/// Answer, formal SDK session, or media resource is created here.
async fn handle_provisional_realtime_signal(
    state: &Arc<RuntimeState>,
    kind: RealtimeSignalKind,
    realtime_id: &str,
    authenticated_peer_id: &str,
    revision: u64,
    shared_session_instance_id: String,
    payload: Vec<u8>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    validate_realtime_id(realtime_id).map_err(boxed_protocol_error)?;
    validate_shared_session_instance_id(&shared_session_instance_id)?;
    validate_peer(state, authenticated_peer_id)
        .await
        .map_err(boxed_protocol_error)?;
    validate_signal(kind, revision, &payload).map_err(boxed_protocol_error)?;

    let now_ms = crate::events::unix_timestamp_ms().max(0) as u64;
    let mut publish: Option<(
        String,
        String,
        String,
        String,
        String,
        u64,
        ScreenShareConsentV2,
    )> = None;
    let mut manager = state.realtime.lock().await;
    prune_provisional_bindings(&mut manager, now_ms);

    match kind {
        RealtimeSignalKind::WebRtcOffer => {
            let sdp = String::from_utf8(payload.clone())
                .map_err(|error| boxed_message(error.to_string()))?;
            SessionDescription::new(DescriptionType::Offer, sdp)
                .map_err(|error| boxed_message(error.to_string()))?;
            if let Some(existing) = manager.provisional.get(realtime_id) {
                if existing.authenticated_peer_id == authenticated_peer_id
                    && existing.shared_session_instance_id == shared_session_instance_id
                    && existing.offer_revision == revision
                    && existing.offer_payload == payload
                {
                    return Ok(());
                }
                return Err(boxed_message("conflicting provisional realtime Offer"));
            }
            if manager.provisional.len() >= MAX_PROVISIONAL_OPERATIONS {
                return Err(boxed_message("too many provisional realtime operations"));
            }
            let binding_expires_at_ms = now_ms.saturating_add(MAX_PROVISIONAL_BINDING_LIFETIME_MS);
            let mut binding = ProvisionalScreenShareBinding {
                offer_id: new_shared_session_instance_id(),
                claim_token: new_shared_session_instance_id(),
                authenticated_peer_id: authenticated_peer_id.to_owned(),
                realtime_id: realtime_id.to_owned(),
                shared_session_instance_id: shared_session_instance_id.clone(),
                offer_revision: revision,
                offer_payload: payload,
                ice_candidates: VecDeque::new(),
                ice_total_bytes: 0,
                request: None,
                binding_expires_at_ms,
                effective_expires_at_ms: binding_expires_at_ms,
                published_to_app: false,
                state: ProvisionalBindingState::Pending,
            };
            if let Some(pending) = manager.provisional_requests.remove(realtime_id) {
                if pending.authenticated_peer_id == authenticated_peer_id
                    && pending.shared_session_instance_id == shared_session_instance_id
                {
                    binding.effective_expires_at_ms =
                        binding_expires_at_ms.min(pending.expires_at_ms);
                    binding.request = Some(pending.request);
                } else {
                    manager
                        .provisional_requests
                        .insert(realtime_id.to_owned(), pending);
                }
            }
            let should_publish = binding.request.is_some();
            if let Some(request) = binding.request.as_ref() {
                publish = Some((
                    binding.offer_id.clone(),
                    binding.claim_token.clone(),
                    binding.realtime_id.clone(),
                    binding.authenticated_peer_id.clone(),
                    binding.shared_session_instance_id.clone(),
                    binding.effective_expires_at_ms,
                    request.clone(),
                ));
            }
            binding.published_to_app = should_publish;
            manager.provisional.insert(realtime_id.to_owned(), binding);
        }
        RealtimeSignalKind::IceCandidate => {
            let Some(binding) = manager.provisional.get_mut(realtime_id) else {
                return Err(boxed_message("provisional realtime Offer is missing"));
            };
            if binding.authenticated_peer_id != authenticated_peer_id
                || binding.shared_session_instance_id != shared_session_instance_id
                || matches!(
                    binding.state,
                    ProvisionalBindingState::Claimed | ProvisionalBindingState::Terminal
                )
            {
                return Err(boxed_message("provisional ICE binding mismatch"));
            }
            binding.push_ice(revision, payload)?;
        }
        RealtimeSignalKind::ScreenShareConsent => {
            let existing_binding = manager.provisional.get(realtime_id);
            let expected_shared = existing_binding
                .map(|binding| binding.shared_session_instance_id.as_str())
                .unwrap_or(shared_session_instance_id.as_str());
            let consent = validate_screen_share_consent(
                &payload,
                realtime_id,
                Some(authenticated_peer_id),
                Some(expected_shared),
            )?;
            match ScreenShareConsentDecision::try_from(consent.decision)
                .map_err(|_| boxed_message("unknown screen-share consent decision"))?
            {
                ScreenShareConsentDecision::Request => {
                    if consent.action_revision != 1 {
                        return Err(boxed_message(
                            "initial screen-share REQUEST revision is invalid",
                        ));
                    }
                    if let Some(binding) = manager.provisional.get_mut(realtime_id) {
                        if binding.authenticated_peer_id != authenticated_peer_id
                            || binding.shared_session_instance_id
                                != consent.shared_session_instance_id
                            || matches!(
                                binding.state,
                                ProvisionalBindingState::Claimed
                                    | ProvisionalBindingState::Terminal
                            )
                        {
                            return Err(boxed_message("screen-share REQUEST binding mismatch"));
                        }
                        if let Some(existing) = binding.request.as_ref() {
                            if existing.operation_id == consent.operation_id
                                && existing.action_revision == consent.action_revision
                            {
                                return Ok(());
                            }
                            return Err(boxed_message("conflicting provisional REQUEST"));
                        }
                        binding.effective_expires_at_ms =
                            binding.effective_expires_at_ms.min(consent.expires_at_ms);
                        binding.request = Some(consent.clone());
                        if !binding.published_to_app {
                            binding.published_to_app = true;
                            publish = Some((
                                binding.offer_id.clone(),
                                binding.claim_token.clone(),
                                binding.realtime_id.clone(),
                                binding.authenticated_peer_id.clone(),
                                binding.shared_session_instance_id.clone(),
                                binding.effective_expires_at_ms,
                                consent,
                            ));
                        }
                    } else {
                        if manager.provisional_requests.len() >= MAX_PROVISIONAL_OPERATIONS {
                            return Err(boxed_message("too many provisional realtime operations"));
                        }
                        if let Some(existing) = manager.provisional_requests.get(realtime_id) {
                            if existing.authenticated_peer_id == authenticated_peer_id
                                && existing.shared_session_instance_id
                                    == consent.shared_session_instance_id
                                && existing.request.operation_id == consent.operation_id
                            {
                                return Ok(());
                            }
                            return Err(boxed_message("conflicting provisional REQUEST"));
                        }
                        manager.provisional_requests.insert(
                            realtime_id.to_owned(),
                            ProvisionalPendingRequest {
                                authenticated_peer_id: authenticated_peer_id.to_owned(),
                                shared_session_instance_id: consent
                                    .shared_session_instance_id
                                    .clone(),
                                expires_at_ms: consent.expires_at_ms,
                                request: consent,
                            },
                        );
                    }
                }
                ScreenShareConsentDecision::Cancel => {
                    let matches_binding =
                        manager.provisional.get(realtime_id).is_some_and(|binding| {
                            binding.authenticated_peer_id == authenticated_peer_id
                                && binding.shared_session_instance_id
                                    == consent.shared_session_instance_id
                                && binding.request.as_ref().is_some_and(|request| {
                                    request.operation_id == consent.operation_id
                                })
                        });
                    if matches_binding {
                        if let Some(mut binding) = manager.provisional.remove(realtime_id) {
                            binding.state = ProvisionalBindingState::Terminal;
                        }
                    } else if manager.provisional.get(realtime_id).is_some_and(|binding| {
                        binding.authenticated_peer_id == authenticated_peer_id
                            && binding.shared_session_instance_id
                                == consent.shared_session_instance_id
                            && binding.request.is_none()
                    }) {
                        if let Some(mut binding) = manager.provisional.remove(realtime_id) {
                            binding.state = ProvisionalBindingState::Terminal;
                        }
                    } else if manager
                        .provisional_requests
                        .get(realtime_id)
                        .is_some_and(|request| {
                            request.authenticated_peer_id == authenticated_peer_id
                                && request.shared_session_instance_id
                                    == consent.shared_session_instance_id
                                && request.request.operation_id == consent.operation_id
                        })
                    {
                        manager.provisional_requests.remove(realtime_id);
                    } else {
                        return Err(boxed_message("screen-share CANCEL binding does not match"));
                    }
                }
                ScreenShareConsentDecision::Accept
                | ScreenShareConsentDecision::Reject
                | ScreenShareConsentDecision::Unspecified => {
                    return Err(boxed_message(
                        "only screen-share REQUEST/CANCEL is valid before claim",
                    ));
                }
            }
        }
        RealtimeSignalKind::WebRtcClose => {
            if manager.provisional.get(realtime_id).is_some_and(|binding| {
                binding.authenticated_peer_id == authenticated_peer_id
                    && binding.shared_session_instance_id == shared_session_instance_id
            }) {
                if let Some(mut binding) = manager.provisional.remove(realtime_id) {
                    binding.state = ProvisionalBindingState::Terminal;
                }
            }
            if manager
                .provisional_requests
                .get(realtime_id)
                .is_some_and(|request| {
                    request.authenticated_peer_id == authenticated_peer_id
                        && request.shared_session_instance_id == shared_session_instance_id
                })
            {
                manager.provisional_requests.remove(realtime_id);
            }
        }
        RealtimeSignalKind::WebRtcAnswer | RealtimeSignalKind::IceRestart => {
            return Err(boxed_message(
                "Answer or ICE restart is not valid before incoming claim",
            ));
        }
        RealtimeSignalKind::Unspecified => {
            return Err(boxed_message(
                "unsupported provisional realtime signal kind",
            ));
        }
    }
    drop(manager);
    if let Some((offer_id, claim_token, realtime_id, peer_id, shared_id, expires, request)) =
        publish
    {
        crate::events::emit_realtime_incoming_session_offer(
            &state.event_tx,
            &offer_id,
            &claim_token,
            &realtime_id,
            &peer_id,
            &shared_id,
            expires,
            &request,
        );
    }
    Ok(())
}

fn prune_provisional_bindings(manager: &mut RealtimeManager, now_ms: u64) {
    let expired = manager
        .provisional
        .iter()
        .filter(|(_, binding)| binding.is_expired(now_ms))
        .map(|(realtime_id, _)| realtime_id.clone())
        .collect::<Vec<_>>();
    for realtime_id in expired {
        if let Some(mut binding) = manager.provisional.remove(&realtime_id) {
            binding.state = ProvisionalBindingState::Terminal;
        }
    }
    manager
        .provisional_requests
        .retain(|_, request| request.expires_at_ms > now_ms);
}

/// WebRTC signaling 协商核心 for an already-bound RealtimeSession.
///
/// Unknown-session Offer/ICE never enters this function through the v2 ingress;
/// `handle_provisional_realtime_signal` retains it natively until an explicit
/// incoming claim creates the formal responder generation. `outcome.outbound`
/// (Answer / restart Offer / ICE) is sent back through the v2 control plane.
async fn handle_realtime_signal(
    state: &Arc<RuntimeState>,
    kind: RealtimeSignalKind,
    realtime_id: &str,
    peer_id: &str,
    revision: u64,
    shared_session_instance_id: String,
    payload: Vec<u8>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    validate_realtime_id(realtime_id).map_err(boxed_protocol_error)?;
    validate_shared_session_instance_id(&shared_session_instance_id)?;
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
        let expected_shared = state
            .realtime
            .lock()
            .await
            .sessions
            .get(realtime_id)
            .map(|session| session.shared_session_instance_id.clone());
        validate_screen_share_consent(
            &payload,
            realtime_id,
            Some(peer_id),
            expected_shared.as_deref(),
        )?;
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
            close_remote_realtime_session(
                state,
                &mut manager,
                realtime_id,
                peer_id,
                revision,
                &shared_session_instance_id,
            )?
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
            RealtimeSessionIdentity::new(generation, &shared_session_instance_id),
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
                shared_session_instance_id,
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
        RealtimeSessionIdentity::new(outcome.generation, &outcome.shared_session_instance_id),
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
            shared_session_instance_id: manager
                .sessions
                .get(realtime_id)
                .map(|session| session.shared_session_instance_id.clone())
                .unwrap_or_else(new_shared_session_instance_id),
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
    shared_session_instance_id: &str,
) -> Result<(RealtimeSession, u64), Box<dyn std::error::Error + Send + Sync>> {
    let Some(session) = manager.sessions.get(realtime_id) else {
        return Err(boxed_message("realtime session does not exist"));
    };
    if session.peer_id != peer_id {
        return Err(boxed_message("realtime signal peer does not match session"));
    }
    if session.shared_session_instance_id != shared_session_instance_id {
        return Err(boxed_message(
            "realtime signal session instance does not match session",
        ));
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
    shared_session_instance_id: &str,
) -> Result<u64, Box<dyn std::error::Error + Send + Sync>> {
    let (mut session, generation) = take_remote_closed_session(
        manager,
        realtime_id,
        peer_id,
        revision,
        shared_session_instance_id,
    )?;
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
        shared_session_instance_id,
        kind,
        revision,
        payload,
    } = signal;
    validate_shared_session_instance_id(&shared_session_instance_id)?;
    if kind == RealtimeSignalKind::WebRtcClose {
        let (mut session, generation) = take_remote_closed_session(
            manager,
            realtime_id,
            peer_id,
            revision,
            &shared_session_instance_id,
        )?;
        let _ = with_session_peer(&mut session, WebRtcPeer::close);
        return Ok(SignalOutcome {
            peer_id: peer_id.to_string(),
            shared_session_instance_id,
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
        if session.shared_session_instance_id != shared_session_instance_id {
            return Err(boxed_message(
                "realtime signal session instance does not match session",
            ));
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
                        shared_session_instance_id: shared_session_instance_id.clone(),
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
                        shared_session_instance_id: shared_session_instance_id.clone(),
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
                shared_session_instance_id: shared_session_instance_id.clone(),
                revision: answer_revision,
                generation,
                state: RealtimeSessionState::Negotiating,
                outbound: Some(OutboundSignal {
                    realtime_id: realtime_id.to_string(),
                    peer_id,
                    shared_session_instance_id: shared_session_instance_id.clone(),
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
                shared_session_instance_id: session.shared_session_instance_id.clone(),
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
                shared_session_instance_id: session.shared_session_instance_id.clone(),
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
                shared_session_instance_id: session.shared_session_instance_id.clone(),
                revision: session.revision,
                generation,
                state: RealtimeSessionState::Restarting,
                outbound: Some(OutboundSignal {
                    realtime_id: realtime_id.to_string(),
                    peer_id: session.peer_id.clone(),
                    shared_session_instance_id: session.shared_session_instance_id.clone(),
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

async fn forward_local_candidate(
    state: &RuntimeState,
    realtime_id: &str,
    peer_id: &str,
    candidate: IceCandidate,
) {
    let (session_peer_id, shared_session_instance_id, revision) = {
        let sessions = state.realtime.lock().await;
        let Some(session) = sessions.sessions.get(realtime_id) else {
            return;
        };
        (
            session.peer_id.clone(),
            session.shared_session_instance_id.clone(),
            session.ice_revision,
        )
    };
    if session_peer_id != peer_id {
        return;
    }
    let payload = candidate.candidate.into_bytes();
    let outbound = OutboundSignal {
        realtime_id: realtime_id.to_owned(),
        peer_id: peer_id.to_owned(),
        shared_session_instance_id,
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

const SHARED_SESSION_INSTANCE_ID_BYTES: usize = 16;
const SHARED_SESSION_INSTANCE_ID_HEX_LEN: usize = SHARED_SESSION_INSTANCE_ID_BYTES * 2;

fn new_shared_session_instance_id() -> String {
    let mut bytes = [0_u8; SHARED_SESSION_INSTANCE_ID_BYTES];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

fn validate_shared_session_instance_id(
    id: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if id.len() != SHARED_SESSION_INSTANCE_ID_HEX_LEN
        || id != id.to_ascii_lowercase()
        || hex::decode(id).map_or(true, |bytes| {
            bytes.len() != SHARED_SESSION_INSTANCE_ID_BYTES
        })
    {
        return Err(boxed_message(
            "shared_session_instance_id must be 32 lowercase hexadecimal characters",
        ));
    }
    Ok(())
}

fn encode_realtime_signal_payload(
    shared_session_instance_id: &str,
    payload: &[u8],
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    validate_shared_session_instance_id(shared_session_instance_id)?;
    let encoded = RealtimeSignalEnvelope {
        shared_session_instance_id: shared_session_instance_id.to_owned(),
        payload: payload.to_vec(),
    }
    .encode_to_vec();
    if encoded.len() > MAX_REALTIME_SIGNAL_PAYLOAD_BYTES {
        return Err(boxed_message("realtime signal envelope is outside bounds"));
    }
    Ok(encoded)
}

fn decode_realtime_signal_payload(
    payload: &[u8],
) -> Result<(String, Vec<u8>), Box<dyn std::error::Error + Send + Sync>> {
    if payload.is_empty() || payload.len() > MAX_REALTIME_SIGNAL_PAYLOAD_BYTES {
        return Err(boxed_message("realtime signal envelope is outside bounds"));
    }
    let envelope = RealtimeSignalEnvelope::decode(payload)
        .map_err(|error| boxed_message(format!("malformed realtime signal envelope: {error}")))?;
    validate_shared_session_instance_id(&envelope.shared_session_instance_id)?;
    if envelope.payload.len() > MAX_REALTIME_SIGNAL_PAYLOAD_BYTES {
        return Err(boxed_message("realtime signal payload is outside bounds"));
    }
    Ok((envelope.shared_session_instance_id, envelope.payload))
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
    expected_shared_session_instance_id: Option<&str>,
) -> Result<ScreenShareConsentV2, Box<dyn std::error::Error + Send + Sync>> {
    validate_screen_share_consent_at(
        payload,
        expected_realtime_id,
        expected_sender_peer_id,
        expected_shared_session_instance_id,
        crate::events::unix_timestamp_ms().max(0) as u64,
    )
}

#[cfg_attr(not(test), allow(dead_code))]
fn validate_screen_share_consent_at(
    payload: &[u8],
    expected_realtime_id: &str,
    expected_sender_peer_id: Option<&str>,
    expected_shared_session_instance_id: Option<&str>,
    now_ms: u64,
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
    validate_shared_session_instance_id(&consent.shared_session_instance_id)?;
    if let Some(expected) = expected_shared_session_instance_id {
        if consent.shared_session_instance_id != expected {
            return Err(boxed_message(
                "screen-share consent session instance does not match signal",
            ));
        }
    }
    if consent.issued_at_ms == 0
        || consent.expires_at_ms <= consent.issued_at_ms
        || consent.expires_at_ms.saturating_sub(consent.issued_at_ms)
            > SCREEN_SHARE_CONSENT_MAX_LIFETIME_MS
    {
        return Err(boxed_message("screen-share consent expiration is invalid"));
    }
    if consent.issued_at_ms > now_ms.saturating_add(SCREEN_SHARE_CONSENT_ALLOWED_FUTURE_SKEW_MS)
        || consent.expires_at_ms <= now_ms
    {
        return Err(boxed_message("screen-share consent is not fresh"));
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
    let payload =
        encode_realtime_signal_payload(&signal.shared_session_instance_id, &signal.payload)
            .map_err(|error| {
                realtime_error(
                    network_protocol::NetworkErrorCode::InvalidArgument,
                    error.to_string(),
                    "send_realtime_signal",
                    &signal.peer_id,
                )
            })?;
    let kind = to_v2_signal_kind(signal.kind);
    control
        .signal_webrtc_wire_kind(
            &signal.realtime_id,
            &signal.peer_id,
            kind,
            signal.revision,
            &payload,
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
