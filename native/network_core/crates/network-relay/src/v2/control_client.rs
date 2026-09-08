//! Relay v2 控制面客户端（`/v2/control`）。
//!
//! 只发送控制消息，绝不携带 file chunk / delivery payload。应答关联完全基于
//! 逐请求 `request_id` 与逐 attempt `attempt_id`：
//!
//! - `pending: HashMap<request_id, oneshot::Sender<ControlEvent>>` —— 同步
//!   请求/应答（HeartbeatAck、DiscoveryAck、ResolvePeerResponse、
//!   RelayReserveResponse）。
//! - `attempts: HashMap<attempt_id, AttemptTracker>` —— 异步 attempt 关联
//!   （ConnectivityOffer→ConnectivityAnswer），tracker 持有该 attempt 的
//!   应答 oneshot 与创建时间。
//!
//! 不存在 v1 的全局 `Notify`；所有应答归属都由消息自身的 id 判定。

use ed25519_dalek::SigningKey;
use futures_util::{SinkExt, StreamExt};
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot, Mutex, RwLock};
use tokio::task::JoinHandle;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::info;
use url::Url;

use super::proto::*;
use super::shared::{
    authenticated_ws_request, map_connect_error, normalize_relay_url, unix_timestamp_ms, RelayError,
};

/// v2 控制面 WebSocket 路径。
pub(crate) const RELAY_V2_CONTROL_PATH: &str = "/v2/control";

const CONTROL_QUEUE_CAPACITY: usize = 8;
const EVENT_QUEUE_CAPACITY: usize = 32;
const SOCKET_OPERATION_TIMEOUT: Duration = Duration::from_secs(12);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(8);
const CONNECTIVITY_ATTEMPT_TIMEOUT: Duration = Duration::from_secs(12);

/// 异步控制面事件：presence hints、incoming reservation、被转发的信令等。
///
/// 同步请求/应答（resolve、discovery ack、reservation、heartbeat ack）通过
/// `pending`/`attempts` oneshot 直接投递给等待方；只有无等待方的帧才落到该流。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ControlEvent {
    HeartbeatAck(HeartbeatAck),
    DiscoveryAck(DiscoveryAck),
    ResolvePeerResponse(ResolvePeerResponse),
    /// 对端发起的连接 attempt（应答方视角）。
    ConnectivityOffer(ConnectivityOffer),
    ConnectivityAnswer(ConnectivityAnswer),
    PresenceHintSnapshot(PresenceHintSnapshot),
    PeerAvailableHint(PeerAvailableHint),
    PeerUnavailableHint(PeerUnavailableHint),
    RelayReserveResponse(RelayReserveResponse),
    IncomingRelayReservation(IncomingRelayReservation),
    RealtimeSignal(RealtimeSignal),
    ProtocolError(ProtocolError),
    Disconnected {
        reason: String,
    },
}

type AttemptStore = Arc<StdMutex<HashMap<String, AttemptTracker>>>;

/// 一个进行中的异步 connectivity attempt。
struct AttemptTracker {
    created_at: Instant,
    token: Arc<()>,
    response_tx: oneshot::Sender<ControlEvent>,
}

#[derive(Clone)]
struct AttemptOwner {
    attempts: AttemptStore,
    attempt_id: String,
    token: Arc<()>,
}

impl AttemptOwner {
    fn remove_if_owner(&self) {
        let mut attempts = self
            .attempts
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if attempts
            .get(&self.attempt_id)
            .is_some_and(|tracker| Arc::ptr_eq(&tracker.token, &self.token))
        {
            attempts.remove(&self.attempt_id);
        }
    }
}

/// Owns one tracker registration. The store is intentionally synchronous and
/// only held for short map operations, so Drop can cancel an unpolled or
/// dropped answer future without trying to await a Tokio lock.
struct AttemptLease {
    owner: AttemptOwner,
}

impl AttemptLease {
    fn new(attempts: AttemptStore, attempt_id: String) -> Self {
        Self {
            owner: AttemptOwner {
                attempts,
                attempt_id,
                token: Arc::new(()),
            },
        }
    }

    fn owner(&self) -> AttemptOwner {
        self.owner.clone()
    }

    fn token(&self) -> Arc<()> {
        Arc::clone(&self.owner.token)
    }
}

impl Drop for AttemptLease {
    fn drop(&mut self) {
        self.owner.remove_if_owner();
    }
}

/// Internal Rust adapter result of one authoritative Resolve →
/// ConnectivityOffer transaction. This type is consumed by `network-core`; it
/// is not part of the Dart/FFI SDK surface.
///
/// A READY response has its Offer enqueued before the response is returned;
/// non-READY responses are returned without an Offer so the caller can retain
/// the authoritative status. The coordination gate is released as soon as
/// the Resolve/Offer step finishes; [`Self::wait_for_answer`] therefore never
/// holds the gate across the answer/direct-probe window.
pub struct ConnectivityAttemptStart {
    /// The authoritative Resolve response for this transaction.
    pub resolved: ResolvePeerResponse,
    answer: Pin<Box<dyn Future<Output = Result<ConnectivityAnswer, RelayError>> + Send>>,
    /// Kept outside the answer future so dropping an unpolled start also
    /// releases its tracker registration.
    attempt_lease: Option<AttemptLease>,
}

struct ConnectivityAnswerWaiter {
    response_rx: oneshot::Receiver<ControlEvent>,
    owner: AttemptOwner,
}

impl ConnectivityAttemptStart {
    /// Construct a transaction result for control-plane implementations and
    /// test doubles that provide their own answer future.
    pub fn new<F>(resolved: ResolvePeerResponse, answer: F) -> Self
    where
        F: Future<Output = Result<ConnectivityAnswer, RelayError>> + Send + 'static,
    {
        Self {
            resolved,
            answer: Box::pin(answer),
            attempt_lease: None,
        }
    }

    /// Wait for and validate the asynchronous answer associated with this
    /// attempt.  Dropping the returned future does not hold any control-plane
    /// lock; timeout/error paths remove the attempt tracker.
    pub async fn wait_for_answer(self) -> Result<ConnectivityAnswer, RelayError> {
        let Self {
            answer,
            attempt_lease,
            ..
        } = self;
        let result = answer.await;
        drop(attempt_lease);
        result
    }
}

impl ConnectivityAnswerWaiter {
    async fn wait(self) -> Result<ConnectivityAnswer, RelayError> {
        let ConnectivityAnswerWaiter { response_rx, owner } = self;
        let result = match tokio::time::timeout(CONNECTIVITY_ATTEMPT_TIMEOUT, response_rx).await {
            Ok(Ok(ControlEvent::ConnectivityAnswer(answer))) if answer.accepted => {
                match answer.responder_runtime_epoch.as_ref() {
                    None => Err(RelayError::Protocol(
                        "accepted connectivity answer is missing responder runtime_epoch".into(),
                    )),
                    Some(epoch) => match validate_discovery_tuple(
                        epoch,
                        answer.responder_revision,
                        answer.responder_snapshot.as_ref(),
                        "responder",
                    ) {
                        Ok(()) => Ok(answer),
                        Err(error) => Err(error),
                    },
                }
            }
            Ok(Ok(ControlEvent::ConnectivityAnswer(answer))) => Ok(answer),
            Ok(Ok(ControlEvent::ProtocolError(error))) => {
                Err(RelayError::Protocol(error.to_string()))
            }
            Ok(Ok(ControlEvent::Disconnected { .. })) => Err(RelayError::NotConnected),
            Ok(Ok(_)) => Err(RelayError::Protocol(
                "unexpected response to connectivity attempt".into(),
            )),
            Ok(Err(_)) => Err(RelayError::NotConnected),
            Err(_) => Err(RelayError::Timeout("connectivity attempt timed out".into())),
        };
        owner.remove_if_owner();
        result
    }
}

/// 控制面应答归属判定。
enum RouteAction {
    RequestId(u64),
    AttemptId(String),
    Event,
}

/// 连接 `/v2/control` 的长期控制面客户端。
///
/// 拥有自己的 WebSocket 与 outbound 队列；与 [`super::RelayDataClient`] 物理隔离。
pub struct RelayControlClient {
    relay_url: Url,
    device_id: String,
    credential: String,
    signing_key: SigningKey,
    outbound: Option<mpsc::Sender<Message>>,
    inbound: Option<mpsc::Receiver<ControlEvent>>,
    inbound_tx: mpsc::Sender<ControlEvent>,
    /// 逐 `request_id` 的同步请求/应答关联表。
    pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>>,
    /// 逐 `attempt_id` 的异步 attempt 关联表。 The synchronous lock is
    /// intentional: every critical section only removes/inserts map entries
    /// and never crosses an await, which lets an attempt lease clean up from
    /// Drop safely.
    attempts: AttemptStore,
    /// Narrow gate for the frozen Resolve -> ConnectivityOffer transaction.
    coordination_gate: Arc<Mutex<()>>,
    next_request_id: Arc<AtomicU64>,
    writer_task: Option<JoinHandle<()>>,
    reader_task: Option<JoinHandle<()>>,
    is_connected: Arc<RwLock<bool>>,
    disconnect_notified: Arc<AtomicBool>,
    intentional_disconnect: Arc<AtomicBool>,
    heartbeat_interval: Duration,
    /// Server-confirmed Ready.presence_ttl_s for remote candidate freshness.
    /// It remains absent until a Ready frame has been validated.
    ready_presence_ttl: Option<Duration>,
}

impl Drop for RelayControlClient {
    /// 中止尚未结束的读写 worker，避免运行时销毁后继续占用 socket。
    fn drop(&mut self) {
        if let Some(task) = self.writer_task.take() {
            task.abort();
        }
        if let Some(task) = self.reader_task.take() {
            task.abort();
        }
    }
}

impl RelayControlClient {
    /// 创建并校验一个 Relay v2 控制面客户端。
    pub fn new(
        relay_url: String,
        device_id: String,
        credential: String,
        signing_seed: [u8; 32],
    ) -> Result<Self, RelayError> {
        if device_id.is_empty()
            || device_id.len() > MAX_DEVICE_ID_BYTES
            || credential.is_empty()
            || credential.len() > 16 * 1024
            || relay_url.len() > 2048
        {
            return Err(RelayError::InvalidConfiguration(
                "Relay URL, device ID, or credential is outside protocol bounds".into(),
            ));
        }
        let relay_url = normalize_relay_url(&relay_url, RELAY_V2_CONTROL_PATH)?;
        let (inbound_tx, inbound) = mpsc::channel(EVENT_QUEUE_CAPACITY);
        Ok(Self {
            relay_url,
            device_id,
            credential,
            signing_key: SigningKey::from_bytes(&signing_seed),
            outbound: None,
            inbound: Some(inbound),
            inbound_tx,
            pending: Arc::new(RwLock::new(HashMap::new())),
            attempts: Arc::new(StdMutex::new(HashMap::new())),
            coordination_gate: Arc::new(Mutex::new(())),
            next_request_id: Arc::new(AtomicU64::new(1)),
            writer_task: None,
            reader_task: None,
            is_connected: Arc::new(RwLock::new(false)),
            disconnect_notified: Arc::new(AtomicBool::new(false)),
            intentional_disconnect: Arc::new(AtomicBool::new(false)),
            heartbeat_interval: Duration::from_secs(u64::from(HEARTBEAT_INTERVAL_S)),
            ready_presence_ttl: None,
        })
    }

    /// 使用设备凭据和签名证明建立 `/v2/control` 连接，并等待 Ready 帧。
    pub async fn connect(&mut self) -> Result<Ready, RelayError> {
        if *self.is_connected.read().await {
            return Err(RelayError::Protocol(
                "Relay control client is already connected".into(),
            ));
        }
        if self.outbound.is_some() {
            self.disconnect().await;
        }
        self.disconnect_notified.store(false, Ordering::Release);
        self.intentional_disconnect.store(false, Ordering::Release);
        let request =
            authenticated_ws_request(&self.relay_url, &self.credential, &self.signing_key)?;
        let (socket, _) = tokio::time::timeout(SOCKET_OPERATION_TIMEOUT, connect_async(request))
            .await
            .map_err(|_| RelayError::Socket("Relay control connection timed out".into()))?
            .map_err(map_connect_error)?;
        let (mut writer, mut reader) = socket.split();
        let ready = tokio::time::timeout(Duration::from_secs(8), reader.next())
            .await
            .map_err(|_| RelayError::Authentication("Relay v2 ready frame timed out".into()))?
            .ok_or_else(|| {
                RelayError::Authentication("Relay socket closed before ready frame".into())
            })?
            .map_err(|error| RelayError::Socket(error.to_string()))?;
        let ready = validate_ready(ready, &self.device_id)?;
        self.heartbeat_interval = Duration::from_secs(u64::from(ready.heartbeat_interval_s.max(1)));
        self.ready_presence_ttl = ready_presence_ttl_from_frame(&ready);

        let (outbound, mut outbound_rx) = mpsc::channel::<Message>(CONTROL_QUEUE_CAPACITY);
        self.outbound = Some(outbound);
        *self.is_connected.write().await = true;

        let connected_for_writer = Arc::clone(&self.is_connected);
        let inbound_for_writer = self.inbound_tx.clone();
        let notified_for_writer = Arc::clone(&self.disconnect_notified);
        let intentional_for_writer = Arc::clone(&self.intentional_disconnect);
        let pending_for_writer = Arc::clone(&self.pending);
        let attempts_for_writer = Arc::clone(&self.attempts);
        let heartbeat_interval = self.heartbeat_interval;
        let next_request_id = Arc::clone(&self.next_request_id);
        self.writer_task = Some(tokio::spawn(async move {
            let mut heartbeat = tokio::time::interval(heartbeat_interval);
            heartbeat.tick().await;
            let mut reason = "Relay control writer stopped".to_string();
            loop {
                let message = tokio::select! {
                    message = outbound_rx.recv() => {
                        let Some(message) = message else {
                            reason = "Relay control outbound queue closed".to_string();
                            break;
                        };
                        message
                    }
                    _ = heartbeat.tick() => {
                        // 心跳 fire-and-forget：server 的 HeartbeatAck 会在 reader 中
                        // 发现没有等待方而被静默丢弃。
                        let request_id = next_request_id.fetch_add(1, Ordering::Relaxed);
                        let frame = RelayFrame {
                            version: RELAY_V2_VERSION,
                            kind: Some(relay_frame::Kind::Heartbeat(Heartbeat {
                                request_id,
                                sent_at_ms: unix_timestamp_ms() as i64,
                            })),
                        };
                        match encode_control_frame(&frame) {
                            Ok(encoded) => Message::Binary(encoded.into()),
                            Err(_) => continue,
                        }
                    }
                };
                let should_stop = matches!(message, Message::Close(_));
                if !matches!(
                    tokio::time::timeout(SOCKET_OPERATION_TIMEOUT, writer.send(message)).await,
                    Ok(Ok(()))
                ) {
                    reason = "Relay control writer failed".to_string();
                    break;
                }
                if should_stop {
                    break;
                }
            }
            mark_control_disconnected(
                &connected_for_writer,
                &inbound_for_writer,
                &notified_for_writer,
                &intentional_for_writer,
                &pending_for_writer,
                &attempts_for_writer,
                reason,
            )
            .await;
        }));

        let inbound_tx = self.inbound_tx.clone();
        let connected_for_reader = Arc::clone(&self.is_connected);
        let notified_for_reader = Arc::clone(&self.disconnect_notified);
        let intentional_for_reader = Arc::clone(&self.intentional_disconnect);
        let pending_for_reader = Arc::clone(&self.pending);
        let attempts_for_reader = Arc::clone(&self.attempts);
        self.reader_task = Some(tokio::spawn(async move {
            let mut reason = "Relay control reader stopped".to_string();
            while let Some(message) = reader.next().await {
                let Ok(message) = message else {
                    reason = "Relay control reader failed".to_string();
                    break;
                };
                match decode_control_event(message) {
                    Ok(Some(event)) => {
                        route_control_event(
                            event,
                            &pending_for_reader,
                            &attempts_for_reader,
                            &inbound_tx,
                        )
                        .await;
                    }
                    Ok(None) => {}
                    Err(_) => {
                        reason = "Relay control protocol stream failed".to_string();
                        break;
                    }
                }
            }
            mark_control_disconnected(
                &connected_for_reader,
                &inbound_tx,
                &notified_for_reader,
                &intentional_for_reader,
                &pending_for_reader,
                &attempts_for_reader,
                reason,
            )
            .await;
        }));
        info!("Relay v2 control client connected");
        Ok(ready)
    }

    /// 取出唯一的异步控制面事件接收器。
    pub fn take_events(&mut self) -> Result<mpsc::Receiver<ControlEvent>, RelayError> {
        self.inbound.take().ok_or_else(|| {
            RelayError::Protocol("Relay control events were already consumed".into())
        })
    }

    /// 返回 presence hint 等异步控制面事件流。
    ///
    /// 与 [`Self::take_events`] 等价，是设计 §31 中 `presenceHints` 的入口：
    /// 流上包含 PresenceHintSnapshot / PeerAvailableHint / PeerUnavailableHint、
    /// IncomingRelayReservation 以及被转发的 inbound ConnectivityOffer/Answer 与
    /// RealtimeSignal。
    pub fn presence_hints(&mut self) -> Result<mpsc::Receiver<ControlEvent>, RelayError> {
        self.take_events()
    }

    /// 返回控制面 socket 是否仍可用于新的控制帧。
    pub async fn is_usable(&self) -> bool {
        *self.is_connected.read().await
            && self
                .outbound
                .as_ref()
                .is_some_and(|sender| !sender.is_closed())
    }

    /// Return the server-confirmed candidate-cache TTL from the last Ready
    /// frame. No value is exposed before a Ready handshake succeeds.
    pub fn ready_presence_ttl(&self) -> Option<Duration> {
        self.ready_presence_ttl
    }

    /// 发送一次显式 Heartbeat，并等待对应的 HeartbeatAck 回显 `request_id`。
    pub async fn heartbeat(&self) -> Result<HeartbeatAck, RelayError> {
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::Heartbeat(Heartbeat {
                request_id,
                sent_at_ms: unix_timestamp_ms() as i64,
            })),
        };
        match self.send_and_await(frame, REQUEST_TIMEOUT).await? {
            ControlEvent::HeartbeatAck(ack) => Ok(ack),
            ControlEvent::ProtocolError(error) => Err(RelayError::Protocol(error.to_string())),
            _ => Err(RelayError::Protocol(
                "unexpected response to Relay heartbeat".into(),
            )),
        }
    }

    /// 发布当前设备的 DiscoverySnapshot，等待 server 的 DiscoveryAck（CAS）。
    pub async fn publish_discovery(
        &self,
        snapshot: DiscoverySnapshot,
    ) -> Result<DiscoveryAck, RelayError> {
        validate_discovery_snapshot(&snapshot)?;
        let expected_epoch = snapshot.runtime_epoch.clone().ok_or_else(|| {
            RelayError::InvalidConfiguration("discovery snapshot must carry runtime_epoch".into())
        })?;
        let expected_revision = snapshot.revision;
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::DiscoveryPublish(DiscoveryPublish {
                request_id,
                snapshot: Some(snapshot),
            })),
        };
        match self.send_and_await(frame, REQUEST_TIMEOUT).await? {
            ControlEvent::DiscoveryAck(ack) => {
                if ack.revision != expected_revision
                    || ack.runtime_epoch.as_ref() != Some(&expected_epoch)
                {
                    return Err(RelayError::Protocol(
                        "Relay discovery ack does not match the published epoch/revision".into(),
                    ));
                }
                Ok(ack)
            }
            ControlEvent::ProtocolError(error) => Err(RelayError::Protocol(error.to_string())),
            _ => Err(RelayError::Protocol(
                "unexpected response to Relay discovery publish".into(),
            )),
        }
    }

    /// 按设备 ID 解析对端当前 Discovery（READY/OFFLINE/NOT_READY/UNKNOWN）。
    pub async fn resolve_peer(
        &self,
        target_device_id: &str,
    ) -> Result<ResolvePeerResponse, RelayError> {
        // ConnectivityOffer has no target field. Serialize every public
        // Resolve with the same narrow gate used by Resolve → Offer so a
        // status lookup cannot overwrite the server's one-shot target ticket
        // between the authoritative Resolve and its Offer.
        let _coordination_guard = self.coordination_gate.lock().await;
        self.resolve_peer_unlocked(target_device_id).await
    }

    async fn resolve_peer_unlocked(
        &self,
        target_device_id: &str,
    ) -> Result<ResolvePeerResponse, RelayError> {
        if target_device_id.is_empty() || target_device_id.len() > MAX_DEVICE_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "resolve target must contain 1-128 characters".into(),
            ));
        }
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ResolvePeerRequest(ResolvePeerRequest {
                request_id,
                target_device_id: target_device_id.to_string(),
            })),
        };
        match self.send_and_await(frame, REQUEST_TIMEOUT).await? {
            ControlEvent::ResolvePeerResponse(response) => validate_resolve_response(response),
            ControlEvent::ProtocolError(error) => Err(RelayError::Protocol(error.to_string())),
            _ => Err(RelayError::Protocol(
                "unexpected response to Relay resolve".into(),
            )),
        }
    }

    /// Enqueue one authoritative Resolve → ConnectivityOffer transaction.
    ///
    /// The returned [`ConnectivityAttemptStart`] carries the authoritative
    /// ResolvePeerResponse together with an answer waiter. READY responses
    /// enqueue the Offer before returning; non-READY responses carry no Offer
    /// and let the caller map the status without losing authority. The
    /// coordination gate covers exactly the Resolve request/response and
    /// Offer enqueue; it is released before the caller waits for an answer.
    pub async fn begin_connectivity_attempt(
        &self,
        attempt_id: String,
        target_device_id: String,
        _initiator_device_id: String,
        initiator_runtime_epoch: RuntimeEpoch,
        initiator_revision: u32,
        initiator_snapshot: Option<DiscoverySnapshot>,
    ) -> Result<ConnectivityAttemptStart, RelayError> {
        if attempt_id.is_empty() || attempt_id.len() > MAX_ATTEMPT_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "attempt_id must contain 1-128 characters".into(),
            ));
        }
        if target_device_id.is_empty() || target_device_id.len() > MAX_DEVICE_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "target device ID is outside protocol bounds".into(),
            ));
        }
        if target_device_id == self.device_id {
            return Err(RelayError::InvalidConfiguration(
                "connectivity target must differ from the authenticated device".into(),
            ));
        }
        validate_discovery_tuple(
            &initiator_runtime_epoch,
            initiator_revision,
            initiator_snapshot.as_ref(),
            "initiator",
        )?;
        // ConnectivityOffer has no target field on the frozen wire.  Keep the
        // narrow gate only across the authoritative Resolve and the Offer
        // enqueue so concurrent attempts on this shared control socket cannot
        // cross-associate their targets.  The answer/probe window is outside
        // the gate.
        let coordination_guard = self.coordination_gate.lock().await;
        if self
            .attempts
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .contains_key(&attempt_id)
        {
            return Err(RelayError::Protocol(
                "connectivity attempt_id is already in use".into(),
            ));
        }
        let resolved = self.resolve_peer_unlocked(&target_device_id).await?;
        if resolved.status != ResolveStatus::Ready as i32 {
            let status = resolved.status;
            let retry_after_ms = resolved.retry_after_ms;
            drop(coordination_guard);
            return Ok(ConnectivityAttemptStart::new(resolved, async move {
                Err(RelayError::Protocol(format!(
                    "connectivity attempt not started: resolve status={status} retry_after_ms={retry_after_ms}"
                )))
            }));
        }
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        let attempt_lease = AttemptLease::new(Arc::clone(&self.attempts), attempt_id.clone());
        {
            let mut attempts = attempt_lease
                .owner
                .attempts
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            attempts.insert(
                attempt_id.clone(),
                AttemptTracker {
                    created_at: Instant::now(),
                    token: attempt_lease.token(),
                    response_tx: tx,
                },
            );
        }
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ConnectivityOffer(ConnectivityOffer {
                request_id,
                attempt_id: attempt_id.clone(),
                // The authenticated control client is the only trusted
                // initiator identity.  The legacy parameter is retained for
                // trait/API compatibility but cannot spoof another device.
                initiator_device_id: self.device_id.clone(),
                initiator_runtime_epoch: Some(initiator_runtime_epoch),
                initiator_revision,
                initiator_snapshot,
            })),
        };
        if let Err(error) = self.send_frame(&frame).await {
            attempt_lease.owner.remove_if_owner();
            return Err(error);
        }
        drop(coordination_guard);
        let owner = attempt_lease.owner();
        Ok(ConnectivityAttemptStart {
            resolved,
            answer: Box::pin(async move {
                ConnectivityAnswerWaiter {
                    response_rx: rx,
                    owner,
                }
                .wait()
                .await
            }),
            attempt_lease: Some(attempt_lease),
        })
    }

    /// 开启一个异步 connectivity attempt，并按 `attempt_id` 关联应答。
    ///
    /// This compatibility wrapper preserves the original API: callers that do
    /// not need the authoritative Resolve response can await the answer
    /// directly.  The Resolve → Offer transaction itself is implemented by
    /// [`Self::begin_connectivity_attempt`].
    pub async fn start_connectivity_attempt(
        &self,
        attempt_id: String,
        target_device_id: String,
        initiator_device_id: String,
        initiator_runtime_epoch: RuntimeEpoch,
        initiator_revision: u32,
        initiator_snapshot: Option<DiscoverySnapshot>,
    ) -> Result<ConnectivityAnswer, RelayError> {
        self.begin_connectivity_attempt(
            attempt_id,
            target_device_id,
            initiator_device_id,
            initiator_runtime_epoch,
            initiator_revision,
            initiator_snapshot,
        )
        .await?
        .wait_for_answer()
        .await
    }

    /// 发送一个受限的 WebRTC 信令帧（fire-and-forget，不等待应答）。发送方身份
    /// 由 Relay 的认证连接上下文确定，不占用 frozen wire 字段。
    pub async fn signal_webrtc(
        &self,
        realtime_id: &str,
        target_device_id: &str,
        kind: RealtimeSignalKind,
        revision: u64,
        payload: &[u8],
    ) -> Result<(), RelayError> {
        self.signal_webrtc_wire_kind(
            realtime_id,
            target_device_id,
            kind as i32,
            revision,
            payload,
        )
        .await
    }

    /// Sends a WebRTC signaling frame using its raw Relay V2 wire kind.
    ///
    /// Relay V2's protobuf descriptor is intentionally frozen.  New
    /// Network-V2 signal kinds can therefore be forwarded as unknown numeric
    /// enum values without changing the Relay schema or its generated
    /// bindings.  Existing callers should prefer [`Self::signal_webrtc`]; this
    /// escape hatch is reserved for forward-compatible signal kinds such as
    /// screen-share consent.
    pub async fn signal_webrtc_wire_kind(
        &self,
        realtime_id: &str,
        target_device_id: &str,
        kind: i32,
        revision: u64,
        payload: &[u8],
    ) -> Result<(), RelayError> {
        if realtime_id.is_empty() || realtime_id.len() > MAX_REALTIME_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "realtime_id must contain 1-128 characters".into(),
            ));
        }
        if target_device_id.is_empty() || target_device_id.len() > MAX_DEVICE_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "WebRTC signal target must contain 1-128 characters".into(),
            ));
        }
        if payload.is_empty() || payload.len() > MAX_REALTIME_SIGNAL_PAYLOAD_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "WebRTC signal payload size is outside protocol bounds".into(),
            ));
        }
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::RealtimeSignal(RealtimeSignal {
                request_id,
                realtime_id: realtime_id.to_string(),
                target_device_id: target_device_id.to_string(),
                kind: kind as i32,
                revision,
                payload: payload.to_vec(),
            })),
        };
        self.send_frame(&frame).await
    }

    /// 请求 Relay 为一条 reservation 分配数据面端点，等待 RelayReserveResponse。
    pub async fn reserve_relay(
        &self,
        attempt_id: &str,
        target_device_id: &str,
        desired_lifetime_s: u32,
    ) -> Result<RelayReserveResponse, RelayError> {
        if attempt_id.is_empty() || attempt_id.len() > MAX_ATTEMPT_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "attempt_id must contain 1-128 characters".into(),
            ));
        }
        if target_device_id.is_empty() || target_device_id.len() > MAX_DEVICE_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "reservation target must contain 1-128 characters".into(),
            ));
        }
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::RelayReserveRequest(
                RelayReserveRequest {
                    request_id,
                    attempt_id: attempt_id.to_string(),
                    target_device_id: target_device_id.to_string(),
                    desired_lifetime_s,
                },
            )),
        };
        match self.send_and_await(frame, REQUEST_TIMEOUT).await? {
            ControlEvent::RelayReserveResponse(response) => Ok(response),
            ControlEvent::ProtocolError(error) => Err(RelayError::Protocol(error.to_string())),
            _ => Err(RelayError::Protocol(
                "unexpected response to Relay reservation".into(),
            )),
        }
    }

    /// 应答一个 inbound ConnectivityOffer（应答方视角）。
    pub async fn send_connectivity_answer(
        &self,
        offer: &ConnectivityOffer,
        accepted: bool,
        _responder_device_id: &str,
        responder_runtime_epoch: RuntimeEpoch,
        responder_revision: u32,
        responder_snapshot: Option<DiscoverySnapshot>,
    ) -> Result<(), RelayError> {
        if offer.attempt_id.is_empty() || offer.attempt_id.len() > MAX_ATTEMPT_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "connectivity offer attempt_id is outside protocol bounds".into(),
            ));
        }
        if accepted {
            validate_discovery_tuple(
                &responder_runtime_epoch,
                responder_revision,
                responder_snapshot.as_ref(),
                "responder",
            )?;
        }
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ConnectivityAnswer(ConnectivityAnswer {
                request_id,
                attempt_id: offer.attempt_id.clone(),
                accepted,
                responder_device_id: self.device_id.clone(),
                responder_runtime_epoch: Some(responder_runtime_epoch),
                responder_revision,
                responder_snapshot,
            })),
        };
        self.send_frame(&frame).await
    }

    /// 请求关闭控制面 socket 与后台读写 worker。
    pub async fn disconnect(&mut self) {
        self.intentional_disconnect.store(true, Ordering::Release);
        if let Some(outbound) = self.outbound.take() {
            let _ = outbound
                .send_timeout(Message::Close(None), SOCKET_OPERATION_TIMEOUT)
                .await;
        }
        if let Some(task) = self.writer_task.take() {
            let _ = task.await;
        }
        if let Some(task) = self.reader_task.take() {
            task.abort();
            let _ = task.await;
        }
        drain_pending(&self.pending, &self.attempts).await;
        *self.is_connected.write().await = false;
        info!("Relay v2 control client disconnected");
    }

    /// 请求共享控制面客户端主动关闭；适用于运行时保存的 Arc 引用。
    pub async fn request_disconnect(&self) {
        self.intentional_disconnect.store(true, Ordering::Release);
        if let Some(outbound) = self.outbound.as_ref() {
            let _ = outbound
                .send_timeout(Message::Close(None), SOCKET_OPERATION_TIMEOUT)
                .await;
        }
        drain_pending(&self.pending, &self.attempts).await;
        *self.is_connected.write().await = false;
    }

    /// 发送一个 v2 控制帧。
    async fn send_frame(&self, frame: &RelayFrame) -> Result<(), RelayError> {
        let encoded = encode_control_frame(frame)?;
        self.outbound()?
            .send_timeout(Message::Binary(encoded.into()), SOCKET_OPERATION_TIMEOUT)
            .await
            .map_err(|_| RelayError::NotConnected)
    }

    /// 注册 `request_id` 的 oneshot，发送请求并等待应答。
    async fn send_and_await(
        &self,
        frame: RelayFrame,
        timeout: Duration,
    ) -> Result<ControlEvent, RelayError> {
        let request_id = frame_request_id(&frame)
            .ok_or_else(|| RelayError::Protocol("v2 request frame has no request_id".into()))?;
        let (tx, rx) = oneshot::channel();
        self.pending.write().await.insert(request_id, tx);
        if let Err(error) = self.send_frame(&frame).await {
            self.pending.write().await.remove(&request_id);
            return Err(error);
        }
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(ControlEvent::Disconnected { .. })) => {
                self.pending.write().await.remove(&request_id);
                Err(RelayError::NotConnected)
            }
            Ok(Ok(event)) => {
                self.pending.write().await.remove(&request_id);
                Ok(event)
            }
            Ok(Err(_)) => {
                self.pending.write().await.remove(&request_id);
                Err(RelayError::NotConnected)
            }
            Err(_) => {
                self.pending.write().await.remove(&request_id);
                Err(RelayError::Timeout(
                    "Relay control request timed out".into(),
                ))
            }
        }
    }

    /// 返回已建立连接的出站队列。
    fn outbound(&self) -> Result<&mpsc::Sender<Message>, RelayError> {
        let outbound = self.outbound.as_ref().ok_or(RelayError::NotConnected)?;
        if outbound.is_closed() {
            return Err(RelayError::NotConnected);
        }
        Ok(outbound)
    }
}

/// 校验 Relay v2 Ready 帧的设备绑定、协议版本和有效租约参数。
fn validate_ready(message: Message, expected_device_id: &str) -> Result<Ready, RelayError> {
    let Message::Binary(frame) = message else {
        return Err(RelayError::Authentication(
            "Relay v2 ready frame must be a binary protobuf frame".into(),
        ));
    };
    let frame = decode_control_frame(&frame)?;
    let kind = frame.kind.as_ref().ok_or_else(|| {
        RelayError::Authentication("Relay v2 ready frame is missing its message".into())
    })?;
    let relay_frame::Kind::Ready(ready) = kind else {
        return Err(RelayError::Authentication(
            "Relay v2 first frame must be Ready".into(),
        ));
    };
    if frame.version != RELAY_V2_VERSION
        || ready.protocol_version != RELAY_V2_VERSION
        || ready.device_id != expected_device_id
        || ready.heartbeat_interval_s == 0
        || ready.presence_ttl_s == 0
        || ready.presence_ttl_s < ready.heartbeat_interval_s
    {
        return Err(RelayError::Authentication(
            "Relay returned an invalid v2 ready frame".into(),
        ));
    }
    Ok(ready.clone())
}

fn ready_presence_ttl_from_frame(ready: &Ready) -> Option<Duration> {
    (ready.presence_ttl_s != 0).then(|| Duration::from_secs(u64::from(ready.presence_ttl_s)))
}

/// Validate the semantic fields that protobuf scalar defaults cannot express.
/// A zero epoch/revision is never a usable discovery publication; accepting it
/// would let an offline or not-ready peer enter the direct-connect path.
fn validate_discovery_snapshot(snapshot: &DiscoverySnapshot) -> Result<(), RelayError> {
    let epoch = snapshot.runtime_epoch.as_ref().ok_or_else(|| {
        RelayError::InvalidConfiguration("discovery snapshot must carry runtime_epoch".into())
    })?;
    if epoch.high == 0 && epoch.low == 0 {
        return Err(RelayError::InvalidConfiguration(
            "discovery snapshot runtime_epoch must be non-zero".into(),
        ));
    }
    if snapshot.revision == 0 {
        return Err(RelayError::InvalidConfiguration(
            "discovery snapshot revision must be non-zero".into(),
        ));
    }
    if snapshot.transport_capabilities.len() > MAX_DISCOVERY_CAPABILITIES {
        return Err(RelayError::InvalidConfiguration(
            "discovery snapshot has too many transport capabilities".into(),
        ));
    }
    if let Some(bundle) = snapshot.candidate_bundle.as_ref() {
        if bundle.candidates.len() > MAX_DISCOVERY_CANDIDATES {
            return Err(RelayError::InvalidConfiguration(
                "discovery snapshot has too many candidates".into(),
            ));
        }
        if bundle
            .candidates
            .iter()
            .any(|candidate| candidate.len() > MAX_DISCOVERY_CANDIDATE_BYTES)
        {
            return Err(RelayError::InvalidConfiguration(
                "discovery snapshot contains an oversized candidate".into(),
            ));
        }
    }
    Ok(())
}

/// Validate the epoch/revision/snapshot tuple carried by an offer or answer.
fn validate_discovery_tuple(
    epoch: &RuntimeEpoch,
    revision: u32,
    snapshot: Option<&DiscoverySnapshot>,
    role: &str,
) -> Result<(), RelayError> {
    if epoch.high == 0 && epoch.low == 0 {
        return Err(RelayError::InvalidConfiguration(format!(
            "{role} runtime_epoch must be non-zero"
        )));
    }
    if revision == 0 {
        return Err(RelayError::InvalidConfiguration(format!(
            "{role} discovery revision must be non-zero"
        )));
    }
    let snapshot = snapshot.ok_or_else(|| {
        RelayError::InvalidConfiguration(format!(
            "{role} discovery snapshot is required for an accepted connectivity attempt"
        ))
    })?;
    validate_discovery_snapshot(snapshot)?;
    if snapshot.revision != revision || snapshot.runtime_epoch.as_ref() != Some(epoch) {
        return Err(RelayError::Protocol(format!(
            "{role} epoch/revision does not match its discovery snapshot"
        )));
    }
    Ok(())
}

/// Resolve is a four-state authority.  Discovery is legal only for READY, and
/// READY must carry a complete, non-zero epoch/revision snapshot.
fn validate_resolve_response(
    response: ResolvePeerResponse,
) -> Result<ResolvePeerResponse, RelayError> {
    let status = ResolveStatus::try_from(response.status)
        .map_err(|_| RelayError::Protocol("Relay returned an unknown resolve status".into()))?;
    match status {
        ResolveStatus::Ready => {
            let snapshot = response.discovery.as_ref().ok_or_else(|| {
                RelayError::Protocol("READY resolve response is missing discovery".into())
            })?;
            validate_discovery_snapshot(snapshot)
                .map_err(|error| RelayError::Protocol(error.to_string()))?;
        }
        ResolveStatus::Offline | ResolveStatus::NotReady | ResolveStatus::Unknown => {
            if response.discovery.is_some() {
                return Err(RelayError::Protocol(
                    "non-READY resolve response must not carry discovery".into(),
                ));
            }
        }
        ResolveStatus::Unspecified => {
            return Err(RelayError::Protocol(
                "Relay returned an unspecified resolve status".into(),
            ));
        }
    }
    Ok(response)
}

/// 解码一个 Relay v2 控制消息。
fn decode_control_event(message: Message) -> Result<Option<ControlEvent>, RelayError> {
    match message {
        Message::Binary(frame) => {
            let frame = decode_control_frame(&frame)?;
            control_event_from_frame(frame).map(Some)
        }
        Message::Ping(_) | Message::Pong(_) => Ok(None),
        Message::Close(_) => Err(RelayError::Socket("Relay control closed the socket".into())),
        Message::Text(_) | Message::Frame(_) => Err(RelayError::Protocol(
            "Relay v2 control frames must be binary protobuf".into(),
        )),
    }
}

/// 将 v2 控制帧转换为高层面事件，并拒绝方向非法的消息。
fn control_event_from_frame(frame: RelayFrame) -> Result<ControlEvent, RelayError> {
    if frame.version != RELAY_V2_VERSION {
        return Err(RelayError::Protocol(format!(
            "unsupported Relay v2 frame version {}",
            frame.version
        )));
    }
    let kind = frame
        .kind
        .ok_or_else(|| RelayError::Protocol("Relay v2 frame is missing its message kind".into()))?;
    Ok(match kind {
        relay_frame::Kind::Heartbeat(_) => {
            return Err(RelayError::Protocol(
                "Relay server must not send Heartbeat frames".into(),
            ))
        }
        relay_frame::Kind::HeartbeatAck(message) => ControlEvent::HeartbeatAck(message),
        relay_frame::Kind::DiscoveryPublish(_) => {
            return Err(RelayError::Protocol(
                "Relay server must not send DiscoveryPublish frames".into(),
            ))
        }
        relay_frame::Kind::DiscoveryAck(message) => ControlEvent::DiscoveryAck(message),
        relay_frame::Kind::ResolvePeerRequest(_) => {
            return Err(RelayError::Protocol(
                "Relay server must not send ResolvePeerRequest frames".into(),
            ))
        }
        relay_frame::Kind::ResolvePeerResponse(message) => {
            ControlEvent::ResolvePeerResponse(message)
        }
        relay_frame::Kind::ConnectivityOffer(message) => {
            if message.attempt_id.is_empty() {
                return Err(RelayError::Protocol(
                    "Relay connectivity offer is missing attempt_id".into(),
                ));
            }
            ControlEvent::ConnectivityOffer(message)
        }
        relay_frame::Kind::ConnectivityAnswer(message) => {
            if message.attempt_id.is_empty() {
                return Err(RelayError::Protocol(
                    "Relay connectivity answer is missing attempt_id".into(),
                ));
            }
            ControlEvent::ConnectivityAnswer(message)
        }
        relay_frame::Kind::PresenceHintSnapshot(message) => {
            ControlEvent::PresenceHintSnapshot(message)
        }
        relay_frame::Kind::PeerAvailableHint(message) => ControlEvent::PeerAvailableHint(message),
        relay_frame::Kind::PeerUnavailableHint(message) => {
            ControlEvent::PeerUnavailableHint(message)
        }
        relay_frame::Kind::RelayReserveRequest(_) => {
            return Err(RelayError::Protocol(
                "Relay server must not send RelayReserveRequest frames".into(),
            ))
        }
        relay_frame::Kind::RelayReserveResponse(message) => {
            ControlEvent::RelayReserveResponse(message)
        }
        relay_frame::Kind::IncomingRelayReservation(message) => {
            ControlEvent::IncomingRelayReservation(message)
        }
        relay_frame::Kind::RealtimeSignal(message) => ControlEvent::RealtimeSignal(message),
        relay_frame::Kind::ProtocolError(message) => ControlEvent::ProtocolError(message),
        relay_frame::Kind::Ready(_) => {
            return Err(RelayError::Protocol(
                "Relay v2 Ready is only valid on the first frame".into(),
            ))
        }
    })
}

/// 判定一个控制事件应投递给哪个关联表。
fn route_action(event: &ControlEvent) -> RouteAction {
    match event {
        ControlEvent::HeartbeatAck(message) => RouteAction::RequestId(message.request_id),
        ControlEvent::DiscoveryAck(message) => RouteAction::RequestId(message.request_id),
        ControlEvent::ResolvePeerResponse(message) => RouteAction::RequestId(message.request_id),
        ControlEvent::RelayReserveResponse(message) => RouteAction::RequestId(message.request_id),
        ControlEvent::ConnectivityAnswer(message) => {
            RouteAction::AttemptId(message.attempt_id.clone())
        }
        ControlEvent::ProtocolError(message) => {
            if !message.attempt_id.is_empty() {
                RouteAction::AttemptId(message.attempt_id.clone())
            } else if message.request_id != 0 {
                RouteAction::RequestId(message.request_id)
            } else {
                RouteAction::Event
            }
        }
        _ => RouteAction::Event,
    }
}

/// 将解码后的控制事件按 `request_id`/`attempt_id` 投递，替代 v1 的全局 Notify。
async fn route_control_event(
    event: ControlEvent,
    pending: &RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>,
    attempts: &AttemptStore,
    events: &mpsc::Sender<ControlEvent>,
) {
    // An async error may carry both the responder's request_id and the
    // initiator's attempt_id.  Attempt ownership wins when a tracker exists;
    // a reservation error with no attempt tracker can still fall back to its
    // request waiter.  Unknown/late attempt errors are dropped rather than
    // leaking into the generic event stream.
    if let ControlEvent::ProtocolError(error) = &event {
        if !error.attempt_id.is_empty() {
            let tracker = remove_attempt(attempts, &error.attempt_id);
            if let Some(tracker) = tracker {
                if tracker.created_at.elapsed() <= CONNECTIVITY_ATTEMPT_TIMEOUT {
                    let _ = tracker.response_tx.send(event);
                }
                return;
            }
        }
        if error.request_id != 0 {
            if let Some(sender) = pending.write().await.remove(&error.request_id) {
                let _ = sender.send(event);
            }
        }
        return;
    }
    match route_action(&event) {
        RouteAction::RequestId(request_id) => {
            let sender = pending.write().await.remove(&request_id);
            match sender {
                Some(sender) => {
                    let _ = sender.send(event);
                }
                None => {
                    // 例行的 heartbeat ack 无人等待时静默丢弃，避免污染事件流。
                    if !matches!(event, ControlEvent::HeartbeatAck(_)) {
                        let _ = events.send(event).await;
                    }
                }
            }
        }
        RouteAction::AttemptId(attempt_id) => {
            let tracker = remove_attempt(attempts, &attempt_id);
            if let Some(tracker) = tracker {
                // 过期 attempt 的迟到应答直接丢弃，避免串到同 id 的新 attempt。
                if tracker.created_at.elapsed() <= CONNECTIVITY_ATTEMPT_TIMEOUT {
                    let _ = tracker.response_tx.send(event);
                }
            }
        }
        RouteAction::Event => {
            let _ = events.send(event).await;
        }
    }
}

/// 将 worker 终止转换为一次性的 Relay v2 断开事件，并失败所有等待方。
async fn mark_control_disconnected(
    connected: &Arc<RwLock<bool>>,
    inbound: &mpsc::Sender<ControlEvent>,
    notified: &Arc<AtomicBool>,
    intentional: &Arc<AtomicBool>,
    pending: &RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>,
    attempts: &AttemptStore,
    reason: String,
) {
    *connected.write().await = false;
    let first_disconnect = !notified.swap(true, Ordering::AcqRel);
    // Drain regardless of whether shutdown was intentional. The explicit
    // disconnect methods also drain, but the worker must remain the fallback
    // when their futures are cancelled after setting the intentional flag.
    drain_pending(pending, attempts).await;
    if !intentional.load(Ordering::Acquire) && first_disconnect {
        let _ = inbound.send(ControlEvent::Disconnected { reason }).await;
    }
}

/// 失败并清空所有待处理请求/attempt，让等待方快速返回 NotConnected。
async fn drain_pending(
    pending: &RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>,
    attempts: &AttemptStore,
) {
    let mut pending = pending.write().await;
    for (_, sender) in pending.drain() {
        let _ = sender.send(ControlEvent::Disconnected {
            reason: "Relay control socket disconnected".into(),
        });
    }
    drop(pending);
    let trackers = {
        let mut attempts = attempts
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        attempts
            .drain()
            .map(|(_, tracker)| tracker)
            .collect::<Vec<_>>()
    };
    for tracker in trackers {
        let _ = tracker.response_tx.send(ControlEvent::Disconnected {
            reason: "Relay control socket disconnected".into(),
        });
    }
}

fn remove_attempt(attempts: &AttemptStore, attempt_id: &str) -> Option<AttemptTracker> {
    attempts
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(attempt_id)
}

#[cfg(test)]
#[path = "../tests/control_client.rs"]
mod tests;
