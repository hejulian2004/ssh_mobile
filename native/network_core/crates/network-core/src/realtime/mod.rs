//! WebRTC realtime Session integration.
//!
//! Realtime media is deliberately a sibling of the ordinary Data Route. This
//! module owns only the native WebRTC peer and signaling revision; keyboard,
//! clipboard, files, Delivery, and Relay recovery remain on their existing
//! QUIC/Relay paths.

#[cfg(test)]
use crate::runtime::RuntimeState;
#[cfg(test)]
use network_protocol::{
    ClaimIncomingRealtimeOfferCommand, ScreenShareConsentDecision, ScreenShareConsentPurpose,
    ScreenShareMediaKind, SendRealtimeSignalCommand, StartRealtimeSessionCommand,
    StopRealtimeSessionCommand,
};
use network_protocol::{RealtimeSessionState, RealtimeSignalKind, ScreenShareConsentV2};
#[cfg(test)]
use network_relay::v2::{
    RealtimeSignal as V2RealtimeSignal, RealtimeSignalKind as V2RealtimeSignalKind,
};
#[cfg(test)]
use network_webrtc::{run_realtime_io, RealtimeIoEvent};
use network_webrtc::{RealtimeIoDriverHandle, WebRtcPeer, MAX_ICE_CANDIDATE_BYTES, MAX_SDP_BYTES};
#[cfg(test)]
use prost::Message;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
#[cfg(test)]
use tokio::sync::mpsc;
#[cfg(test)]
use tokio::sync::mpsc::unbounded_channel;
use tokio::sync::Notify;
use tokio::time::Instant;

use crate::session::SessionId;

mod claim;
mod claim_commit;
mod claim_reject;
mod io;
mod provisional;
mod provisional_signal;
mod session;
mod signal;
mod signal_apply;
mod signal_control;
mod wire;

pub(crate) use claim::{
    commit_incoming_claim, exact_claim_responder, exact_claiming_binding, next_claim_close_signal,
    take_provisional_claim,
};
pub(crate) use claim_commit::claim_incoming_offer;
pub(crate) use claim_reject::{discard_incoming_offer, reject_incoming_offer};
pub(crate) use io::{
    close_realtime_sessions_for_session, create_io_driver, realtime_task_key,
    remove_realtime_session_if_owned, run_realtime_session_io, runtime_webrtc_config,
    take_realtime_session_if_owned, with_session_peer,
};
pub(crate) use provisional::{
    ensure_provisional_expiry_worker, provisional_deadline, prune_provisional_bindings,
};
pub(crate) use provisional_signal::handle_provisional_realtime_signal;
pub(crate) use session::{preserve_for_environment_reprobe, start_session, stop_session};
pub(crate) use signal::{handle_realtime_signal, handle_v2_realtime_signal, send_signal_command};
pub(crate) use signal_apply::{apply_signal_with_driver, close_remote_realtime_session};
pub(crate) use signal_control::handle_claiming_control_signal;
pub(crate) use wire::{
    boxed_message, boxed_protocol_error, decode_realtime_signal_payload, forward_local_candidate,
    new_shared_session_instance_id, realtime_error, send_signal, validate_peer,
    validate_realtime_id, validate_screen_share_consent, validate_shared_session_instance_id,
    validate_signal,
};

#[cfg(test)]
pub(crate) use io::{
    handle_io_event, remove_realtime_session, runtime_webrtc_config_from_values, session_revision,
};
#[cfg(test)]
pub(crate) use provisional::run_provisional_expiry_worker;
#[cfg(test)]
pub(crate) use session::start_session_with_config;
#[cfg(test)]
pub(crate) use signal_apply::apply_signal;
#[cfg(test)]
pub(crate) use wire::to_v2_signal_kind;
#[cfg(test)]
pub(crate) use wire::{encode_realtime_signal_payload, validate_screen_share_consent_at};

const MAX_REALTIME_SIGNAL_PAYLOAD_BYTES: usize = MAX_SDP_BYTES;
const SCREEN_SHARE_CONSENT_MAX_LIFETIME_MS: u64 = 120_000;
const SCREEN_SHARE_CONSENT_ALLOWED_FUTURE_SKEW_MS: u64 = 30_000;
pub(crate) const MAX_PROVISIONAL_ICE_CANDIDATES: usize = 128;
pub(crate) const MAX_PROVISIONAL_ICE_CANDIDATE_BYTES: usize = MAX_ICE_CANDIDATE_BYTES;
pub(crate) const MAX_PROVISIONAL_ICE_TOTAL_BYTES: usize = 256 * 1024;
pub(crate) const MAX_PROVISIONAL_BINDING_LIFETIME_MS: u64 = 120_000;
const MAX_PROVISIONAL_OPERATIONS: usize = 32;
const MAX_PROVISIONAL_REPLAY_KEYS_PER_PEER: usize = 256;
const PROVISIONAL_REPLAY_TTL_MS: u64 = 5 * 60 * 1000;
static NEXT_REALTIME_SESSION_GENERATION: AtomicU64 = AtomicU64::new(1);

pub(crate) struct RealtimeSession {
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
    provisional_epoch: u64,
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
    expiry_deadline: Instant,
    published_to_app: bool,
    state: ProvisionalBindingState,
}

pub(crate) struct RealtimeManager {
    sessions: HashMap<String, RealtimeSession>,
    provisional: HashMap<String, ProvisionalScreenShareBinding>,
    provisional_requests: HashMap<String, ProvisionalPendingRequest>,
    provisional_replay_cache: HashMap<String, VecDeque<ProvisionalReplayEntry>>,
    next_provisional_epoch: u64,
    provisional_expiry_wake: Arc<Notify>,
    provisional_expiry_worker_started: bool,
    /// Generation is owned by the live Realtime manager, not inferred by the
    /// media registry. It changes whenever a new session is inserted for an ID.
    session_generations: HashMap<String, u64>,
}

struct ProvisionalPendingRequest {
    provisional_epoch: u64,
    authenticated_peer_id: String,
    shared_session_instance_id: String,
    request: ScreenShareConsentV2,
    expires_at_ms: u64,
    expiry_deadline: Instant,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub(crate) struct ProvisionalReplayKey {
    sender_peer_id: String,
    target_device_id: String,
    realtime_id: String,
    operation_id: String,
    decision: i32,
    action_revision: u64,
}

struct ProvisionalReplayEntry {
    key: ProvisionalReplayKey,
    expires_at_ms: u64,
}

impl Default for RealtimeManager {
    fn default() -> Self {
        Self {
            sessions: HashMap::new(),
            provisional: HashMap::new(),
            provisional_requests: HashMap::new(),
            provisional_replay_cache: HashMap::new(),
            next_provisional_epoch: 0,
            provisional_expiry_wake: Arc::new(Notify::new()),
            provisional_expiry_worker_started: false,
            session_generations: HashMap::new(),
        }
    }
}

pub(crate) struct OutboundSignal {
    realtime_id: String,
    peer_id: String,
    shared_session_instance_id: String,
    kind: RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
}

/// 一条已解码的入站 WebRTC 信令。v1 信封（revision 内嵌）与 v2 控制面帧
/// （revision 独立字段）在进入状态机前都归一化为该三元组。
pub(crate) struct InboundSignal {
    shared_session_instance_id: String,
    kind: RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
}

pub(crate) struct SignalOutcome {
    peer_id: String,
    shared_session_instance_id: String,
    revision: u64,
    generation: u64,
    /// `None` means that the signal only mutated the exact PeerConnection.
    /// Trickle ICE must not manufacture a lifecycle regression after an
    /// authoritative Connected event.
    state: Option<RealtimeSessionState>,
    outbound: Option<OutboundSignal>,
}

pub(crate) struct IncomingClaimResponder {
    provisional_epoch: u64,
    generation: u64,
    driver: RealtimeIoDriverHandle,
}

/// v2 控制面信令入口（§17/§22：WebRTC signaling 经 Relay Control Plane）。
/// `RealtimeSignal` 帧携带独立 `revision`，payload 是 native-owned envelope；
/// envelope 把信令绑定到跨设备共享的 session instance，而不是 process-local
/// native generation。新 Relay V2 帧携带由 Relay 写入的 authenticated source；
/// 已绑定 session 仍兼容 source 缺省的旧 Relay，未知 session 则必须有 source。
pub(crate) struct ClaimingControlSignal<'a> {
    local_device_id: &'a str,
    kind: RealtimeSignalKind,
    realtime_id: &'a str,
    authenticated_peer_id: &'a str,
    revision: u64,
    shared_session_instance_id: &'a str,
    payload: &'a [u8],
}

#[cfg(test)]
#[path = "../tests/realtime.rs"]
mod tests;
