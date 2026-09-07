//! V2 网络运行时生命周期、共享状态与命令/事件通道。

use network_protocol::{NetworkCommand, NetworkEvent};
use std::sync::{
    atomic::{AtomicU16, AtomicU8, Ordering},
    Arc, Mutex,
};
use std::time::Duration;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, Mutex as AsyncMutex, Notify, RwLock};
use tracing::info;

use crate::commands::run_command_worker;
use crate::connect::{profile_capability_mask, PathHandle, PathLease, PeerId, PeerPathManager};
use crate::crypto::{CryptoContext, CryptoError, SessionCryptoManager};
use crate::crypto_handshake::SessionCryptoMaterial;
use crate::delivery::DeliveryManager;
use crate::errors::{CoreNetworkError, NetworkError};
use crate::runtime_event_lanes::BoundedEventLanes;
pub(crate) use crate::runtime_event_lanes::{EventReceiver, EventSender};
use crate::runtime_path_projections::RuntimePathProjectionStore;
use crate::session::{
    ConnectionAdmission, ConnectionAdmissionError, ConnectionAdmissionOutcome,
    ConnectionSessionStore, SessionId,
};
use crate::stream::ReliableStreamManager;
use crate::task_supervisor::RuntimeTaskSupervisor;
use network_nat::{PathManager, ResolvedCandidateCache};
use network_relay::RelayDataClient;
#[path = "runtime_lifecycle.rs"]
mod runtime_lifecycle;
use runtime_lifecycle::RuntimeLifecycleState;
use std::collections::HashMap;
use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;

pub(crate) const PEER_CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
pub(crate) const RECONNECT_INITIAL_BACKOFF: Duration = Duration::from_millis(250);
pub(crate) const RECONNECT_MAX_BACKOFF: Duration = Duration::from_secs(5);
pub(crate) const INCOMING_APPROVAL_TIMEOUT: Duration = Duration::from_secs(30);
pub(crate) const TRANSFER_COMPLETION_TIMEOUT: Duration = Duration::from_secs(15);
pub(crate) const MAX_PENDING_INCOMING_TRANSFERS: usize = 64;
pub(crate) const MAX_PENDING_RELAY_CRYPTO_HANDSHAKES: usize = 64;
pub(crate) const DELIVERY_RETRY_POLL_INTERVAL: Duration = Duration::from_millis(100);
/// Commands are control-plane input and must never grow an unbounded queue.
pub(crate) const COMMAND_MAILBOX_CAPACITY: usize = 256;

pub(crate) const RUNTIME_CREATED: u8 = 0;
pub(crate) const RUNTIME_RUNNING: u8 = 1;
pub(crate) const RUNTIME_STOPPING: u8 = 2;
pub(crate) const RUNTIME_STOPPED: u8 = 3;

/// 一次 authenticated Session admission 的不可变载体。
///
/// transport-network v2（§18）：Session 与 connection 一一对应，被替换的旧 Session
/// 会在 admission 时立即整体销毁（route 关闭 + task group 取消 + 资源 retire），
/// 因此不需要 drop 时机的延迟取消。
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ConnectionAdmissionLease {
    admission: ConnectionAdmission,
}

/// Session admission is deliberately separate from Peer lifecycle. This
/// result only tells the attempt whether it owns a fresh SessionId reservation
/// or must observe an already-reserved identity; the PeerSupervisor owns the
/// actual in-flight operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ConnectDecision {
    Started(SessionId),
    AlreadyConnected(SessionId),
    CapabilityMismatch(SessionId),
    InProgress(SessionId),
}

impl ConnectionAdmissionLease {
    pub(crate) fn new(admission: ConnectionAdmission) -> Self {
        Self { admission }
    }
}

impl std::ops::Deref for ConnectionAdmissionLease {
    type Target = ConnectionAdmission;

    fn deref(&self) -> &Self::Target {
        &self.admission
    }
}

#[derive(Clone)]
pub(crate) struct PeerConfig {
    pub(crate) endpoint: Option<SocketAddr>,
    pub(crate) identity_public_key: [u8; 32],
    pub(crate) e2e_public_key: [u8; 32],
    pub(crate) e2ee_policy: network_protocol::E2eePolicy,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PeerRouteAuthorization {
    pub(crate) direct: bool,
    pub(crate) relay: bool,
}

/// Typed bridge owned by the Runtime boundary for Relay-backed transfer work.
///
/// Transfer dispatch must not import the Relay implementation directly: the
/// Runtime exposes the narrow business capability while Relay provides the
/// concrete adapter. Borrowed path leases remain owned by the caller and are
/// kept alive by the returned transfer future.
pub(crate) trait RelayTransferPort {
    fn dispatch_relay_transfer(
        self: Arc<Self>,
        peer: PeerConfig,
        transfer: network_transfer::ResumableTransfer,
        lease: PathLease,
    ) -> Pin<Box<dyn Future<Output = ()> + Send + 'static>>;

    fn respond_to_relay_incoming<'a>(
        &'a self,
        transfer_id: &'a str,
        accepted: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), network_protocol::NetworkError>> + Send + 'a>>;

    fn cancel_relay_transfer<'a>(
        &'a self,
        transfer_id: &'a str,
    ) -> Pin<Box<dyn Future<Output = ()> + Send + 'a>>;
}

/// Typed bridge for Relay-triggered transfer recovery.
///
/// Relay only requests recovery; the Transfer domain owns the resume policy
/// and remains the sole implementation of these operations.
pub(crate) trait TransferRelayPort {
    fn resume_relay_transfers(
        self: Arc<Self>,
    ) -> Pin<Box<dyn Future<Output = ()> + Send + 'static>>;

    fn resume_transfers_for_peer(
        self: Arc<Self>,
        peer_id: String,
    ) -> Pin<Box<dyn Future<Output = ()> + Send + 'static>>;
}

pub(crate) struct RuntimeState {
    /// Resources created and released by the Runtime start/stop lifecycle.
    pub(crate) lifecycle: RuntimeLifecycleState,
    pub(crate) local_path_manager: RwLock<Option<Arc<PathManager>>>,
    pub(crate) peers: RwLock<HashMap<String, PeerConfig>>,
    pub(crate) peer_route_authorizations: RwLock<HashMap<String, PeerRouteAuthorization>>,
    pub(crate) trusted_peer_keys: RwLock<HashMap<String, [u8; 32]>>,
    /// ConnectionSession storage only; logical Peer lifecycle is owned by
    /// `PeerSupervisorRegistry` and never by this connection store.
    pub(crate) connection_sessions: ConnectionSessionStore,
    /// Session-owned application crypto. Route changes do not replace this
    /// manager; explicit Session close removes the corresponding context.
    pub(crate) crypto: SessionCryptoManager,
    pub(crate) delivery: DeliveryManager,
    pub(crate) realtime: AsyncMutex<crate::realtime::RealtimeManager>,
    /// Native-only endpoint leases for encoded screen-media ingress/egress.
    /// The registry does not own a PeerConnection; it borrows the current
    /// Realtime I/O owner and rejects stale session generations.
    pub(crate) realtime_media: Mutex<crate::realtime_media::RealtimeMediaRegistry>,
    /// Runtime-owned Relay control/data/transfer state.
    pub(crate) relay: crate::relay_state::RelayDomainState,
    /// transport-network v2：本地 Discovery 生命周期 owner（§9/§29）。
    pub(crate) local_discovery: RwLock<Option<Arc<crate::discovery::LocalDiscoveryManager>>>,
    /// transport-network v2：已就绪 Session 摘要索引（§34/§29）；不拥有连接。
    pub(crate) ready_session_index: crate::connect::ready_index::ReadySessionIndex,
    /// transport-network v2：Presence → UI-only 提示缓存（§23/§29）。Presence 事件
    /// 只更新本缓存，绝不修改 ConnectivityAttempt / CandidateSet / ConnectionSession。
    pub(crate) presence_hints: crate::connect::presence::PresenceHintCache,
    /// Authoritative remote candidate cache for uncoordinated Direct Stage A.
    /// Entries are refreshed only from accepted Resolve/answer snapshots; age is
    /// checked with `Instant` inside `ResolvedCandidateCache`.
    pub(crate) remote_candidate_cache: RwLock<HashMap<String, ResolvedCandidateCache>>,
    /// V2 peer-owned lifecycle coordinator. It isolates intent generations,
    /// waiters, and bounded control mailboxes by validated PeerId.
    pub(crate) peer_supervisors: crate::connect::PeerSupervisorRegistry,
    /// Runtime owner of ready-path handles. Borrowers receive leases only.
    pub(crate) ready_paths: Arc<crate::connect::PathRegistry>,
    /// Strong peer-owned path managers. `ready_paths` is only a weak index;
    /// these managers own the corresponding PhysicalPath and its carrier.
    pub(crate) peer_path_managers: RwLock<HashMap<String, Arc<Mutex<PeerPathManager>>>>,
    /// Session-scoped lookup for non-owning path projections. The dedicated
    /// store owns replacement and stale-handle cleanup policy; peer managers
    /// remain the only carrier owners.
    path_projections: RuntimePathProjectionStore,
    /// Direct recovery policy is a scheduler gate only. It never owns a path
    /// or a session and Relay business availability is tracked independently.
    direct_recovery: Mutex<HashMap<String, crate::discovery::DirectRecoveryPolicy>>,
    /// ReliableStream byte-stream managers, keyed by peer（§17）。每个 peer 的
    /// receive buffer / QUIC send half / 网关桥都挂在这个 manager 上。
    pub(crate) reliable_streams: RwLock<HashMap<String, ReliableStreamManager>>,
    /// SSH 网关桥接的本地 sshd 端口（§21 option B）。生产默认 22；测试可覆盖指向
    /// 本地 echo server。
    pub(crate) stream_gateway_port: Arc<AtomicU16>,
    /// Runtime-owned Transfer domain state.
    pub(crate) transfer: crate::transfer::TransferDomainState,
    pub(crate) event_tx: EventSender,
    pub(crate) task_supervisor: Arc<RuntimeTaskSupervisor>,
}

impl RuntimeState {
    /// 创建由一个已启动 worker 拥有的空运行时状态。
    pub(crate) fn new<S: Into<EventSender>>(event_tx: S, bound_port: Arc<AtomicU16>) -> Self {
        let task_supervisor = RuntimeTaskSupervisor::new();
        Self {
            lifecycle: RuntimeLifecycleState::new(bound_port),
            local_path_manager: RwLock::new(None),
            peers: RwLock::new(HashMap::new()),
            peer_route_authorizations: RwLock::new(HashMap::new()),
            trusted_peer_keys: RwLock::new(HashMap::new()),
            connection_sessions: ConnectionSessionStore::new(),
            crypto: SessionCryptoManager::new(),
            delivery: DeliveryManager::new(),
            realtime: AsyncMutex::new(crate::realtime::RealtimeManager::default()),
            realtime_media: Mutex::new(crate::realtime_media::RealtimeMediaRegistry::new()),
            relay: crate::relay_state::RelayDomainState::new(),
            local_discovery: RwLock::new(None),
            ready_session_index: crate::connect::ready_index::ReadySessionIndex::new(),
            presence_hints: crate::connect::presence::PresenceHintCache::new(),
            remote_candidate_cache: RwLock::new(HashMap::new()),
            peer_supervisors: crate::connect::PeerSupervisorRegistry::with_task_supervisor(
                Arc::clone(&task_supervisor),
            ),
            ready_paths: Arc::new(crate::connect::PathRegistry::new()),
            peer_path_managers: RwLock::new(HashMap::new()),
            path_projections: RuntimePathProjectionStore::new(),
            direct_recovery: Mutex::new(HashMap::new()),
            reliable_streams: RwLock::new(HashMap::new()),
            stream_gateway_port: Arc::new(AtomicU16::new(crate::stream::STREAM_LOCAL_SSH_PORT)),
            transfer: crate::transfer::TransferDomainState::new(),
            event_tx: event_tx.into(),
            task_supervisor,
        }
    }

    async fn retire_session_resources(&self, peer_id: &str, session_id: SessionId) {
        let session_key = session_id.wire_key();
        // Retire aliases before awaiting the old task group.
        // A receiver task may be inside a bounded I/O wait; the replacement
        // Session must become cryptographically isolated without waiting for
        // that transport task to finish unwinding.
        self.crypto.remove_session(peer_id, &session_key);
        // transport-network v2：Session 替换/关闭时同步注销连接登记（§34）。
        self.ready_session_index
            .unregister_if_session(peer_id, session_id);
        // §17/§21：ConnectionSession 销毁时关闭该 peer 的所有 ReliableStream，
        // 并向应用发布 SshStreamClosed（SSH 不做透明恢复，客户端自行重连）。
        if let Some(manager) = self.reliable_streams.read().await.get(peer_id).cloned() {
            let local_opener_device_id = self
                .lifecycle
                .identity
                .read()
                .await
                .as_ref()
                .map(|identity| identity.device_id.clone())
                .unwrap_or_default();
            manager.close_all(peer_id, &local_opener_device_id).await;
        }
        // §19/§20 业务状态（pending / dedup / ordered）不属于 Session：transport
        // 丢失或 Session 被替换时**不得**清理 Delivery 的接收端去重/有序状态，
        // 否则新连接无法按 MessageId 去重、无法在有序通道上从断点继续。显式
        // Disconnect 才清理（见 peer::disconnect_peer）。
    }

    pub(crate) async fn cancel_session_tasks(&self, peer_id: &str, session_id: SessionId) {
        let session_key = session_id.wire_key();
        self.retire_session_resources(peer_id, session_id).await;
        // §19：ConnectionSession 销毁（transport 丢失 / 显式断开 / 被新连接替换）
        // 时把该 Peer 的非终态 TransferOperation 置为 Paused。业务状态保留在
        // TransferManager，等待下一次连接上的 ResumeTransfer(transfer_id) 恢复。
        self.transfer.manager.pause_peer_transfers(peer_id).await;
        // §22：RealtimeSession 绑定在 ConnectionSession 上，transport 丢失即随
        // ConnectionSession 销毁（发出 Closed、销毁 PeerConnection）；不做透明恢复。
        crate::realtime::close_realtime_sessions_for_session(self, peer_id, session_id).await;
        self.task_supervisor.cancel_session(&session_key).await;
    }
    pub(crate) async fn begin_connect(
        &self,
        peer_id: &str,
        required_capabilities: u8,
    ) -> ConnectDecision {
        // SessionStore only reserves a fresh identity. It deliberately does
        // not know whether a peer is Connecting or Online; that decision is
        // owned by PeerSupervisor. The existing binding is sufficient for
        // this attempt-local stale guard.
        if let Some(session_id) = self.connection_sessions.current_session_id(peer_id).await {
            if self
                .connection_sessions
                .current_remote_session_binding(peer_id)
                .await
                .is_some()
            {
                if self
                    .path_supports_capability(peer_id, required_capabilities)
                    .await
                {
                    ConnectDecision::AlreadyConnected(session_id)
                } else {
                    ConnectDecision::CapabilityMismatch(session_id)
                }
            } else {
                ConnectDecision::InProgress(session_id)
            }
        } else {
            let session_id = SessionId::new();
            match self
                .connection_sessions
                .register_pending_session(peer_id, session_id)
                .await
            {
                Ok(()) => ConnectDecision::Started(session_id),
                Err(_) => ConnectDecision::InProgress(
                    self.connection_sessions
                        .current_session_id(peer_id)
                        .await
                        .unwrap_or(session_id),
                ),
            }
        }
    }

    /// Admit authenticated Noise material for a 1:1 ConnectionSession（§18）。
    ///
    /// 被替换的旧 Session 在这里立即整体销毁（关闭 detached route + retire 资源 +
    /// 取消其 task group）。因为 Session 与 connection 一一对应，旧 Session 属于另一条
    /// connection，取消其任务组不会中断当前新连接的握手。
    #[allow(dead_code)]
    pub(crate) async fn admit_authenticated_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        remote_session_binding: &str,
    ) -> Result<ConnectionAdmissionLease, ConnectionAdmissionError> {
        self.admit_authenticated_session_with_capability(
            peer_id,
            expected_session_id,
            remote_session_binding,
            u8::MAX,
        )
        .await
    }

    pub(crate) async fn admit_authenticated_session_with_capability(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        remote_session_binding: &str,
        candidate_capabilities: u8,
    ) -> Result<ConnectionAdmissionLease, ConnectionAdmissionError> {
        let _ = candidate_capabilities;
        let outcome: ConnectionAdmissionOutcome = self
            .connection_sessions
            .admit_authenticated_session(peer_id, expected_session_id, remote_session_binding)
            .await?;
        let admission = outcome.admission;
        if let Some(replaced_session_id) = admission.replaced_session_id {
            self.close_transport_path(peer_id).await;
            self.cancel_session_tasks(peer_id, replaced_session_id)
                .await;
        }
        Ok(ConnectionAdmissionLease::new(admission))
    }

    async fn peer_path_manager(
        &self,
        peer_id: &str,
    ) -> Result<Arc<Mutex<PeerPathManager>>, CoreNetworkError> {
        let peer = PeerId::new(peer_id)?;
        if let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() {
            return Ok(manager);
        }
        let mut managers = self.peer_path_managers.write().await;
        Ok(managers
            .entry(peer_id.to_string())
            .or_insert_with(|| {
                Arc::new(Mutex::new(PeerPathManager::new(
                    peer.clone(),
                    Arc::clone(&self.ready_paths),
                )))
            })
            .clone())
    }

    /// Return the command-registered route policy. Native-owned test seams
    /// may construct a path manager directly and therefore have no policy
    /// record; those seams retain the historical unrestricted behavior while
    /// every V2 command registration gets an explicit fail-closed policy.
    pub(crate) async fn peer_route_authorization(
        &self,
        peer_id: &str,
    ) -> Option<PeerRouteAuthorization> {
        self.peer_route_authorizations
            .read()
            .await
            .get(peer_id)
            .copied()
    }

    pub(crate) async fn route_is_authorized(
        &self,
        peer_id: &str,
        topology: crate::connection::RouteTopology,
    ) -> bool {
        self.peer_route_authorization(peer_id)
            .await
            .map(|authorization| match topology {
                crate::connection::RouteTopology::Direct => authorization.direct,
                crate::connection::RouteTopology::Relay => authorization.relay,
            })
            .unwrap_or(true)
    }

    /// Acquire one explicit business lease from the sole peer path owner.
    /// RuntimeState exposes the lookup boundary; it never stores or returns a
    /// second strong carrier owner.
    pub(crate) async fn acquire_path_lease(
        &self,
        peer_id: &str,
        required_capabilities: u8,
    ) -> Result<crate::connect::PathLease, CoreNetworkError> {
        let _peer_id = PeerId::new(peer_id)?;
        let manager = self
            .peer_path_managers
            .read()
            .await
            .get(peer_id)
            .cloned()
            .ok_or(CoreNetworkError::NoRoute)?;
        let authorization = self.peer_route_authorization(peer_id).await;
        let (allow_direct, allow_relay) = authorization
            .map(|authorization| (authorization.direct, authorization.relay))
            .unwrap_or((true, true));
        let manager = manager.lock().expect("peer path manager lock");
        let selected = manager
            .select_with_authorization(required_capabilities, allow_direct, allow_relay)
            .ok_or(CoreNetworkError::NoRoute)?;
        let (acquired, lease) =
            manager.acquire_with_authorization(required_capabilities, allow_direct, allow_relay)?;
        if acquired != selected {
            lease.release();
            return Err(CoreNetworkError::StaleAttempt);
        }
        Ok(lease)
    }

    /// Acquire the current Relay path for Relay-only business I/O. Generic
    /// path selection prefers Direct and therefore cannot preserve Relay
    /// reservation identity for these operations.
    pub(crate) async fn acquire_relay_path_lease(
        &self,
        peer_id: &str,
        required_capabilities: u8,
    ) -> Result<crate::connect::PathLease, CoreNetworkError> {
        let _peer_id = PeerId::new(peer_id)?;
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Relay)
            .await
        {
            return Err(CoreNetworkError::NoRoute);
        }
        let manager = self
            .peer_path_managers
            .read()
            .await
            .get(peer_id)
            .cloned()
            .ok_or(CoreNetworkError::NoRoute)?;
        let lease = manager
            .lock()
            .expect("peer path manager lock")
            .acquire_relay(required_capabilities)?;
        Ok(lease)
    }

    /// Acquire the lease for the exact QUIC carrier that delivered an inbound
    /// stream. Inbound work must not silently move to whichever path happens
    /// to be preferred after the frame was received.
    pub(crate) async fn acquire_path_lease_for_connection(
        &self,
        peer_id: &str,
        connection: &quinn::Connection,
        required_capabilities: u8,
    ) -> Result<crate::connect::PathLease, CoreNetworkError> {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return Err(CoreNetworkError::NoRoute);
        }
        self.acquire_matching_path_lease(peer_id, required_capabilities, |lease| {
            lease
                .connection()
                .is_some_and(|candidate| candidate.stable_id() == connection.stable_id())
        })
        .await
    }

    /// Acquire the lease for the exact generic route that delivered an
    /// inbound frame. The route id is the generic carrier identity, not a
    /// current-path selection hint.
    pub(crate) async fn acquire_path_lease_for_generic_route(
        &self,
        peer_id: &str,
        route_id: u64,
        required_capabilities: u8,
    ) -> Result<crate::connect::PathLease, CoreNetworkError> {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return Err(CoreNetworkError::NoRoute);
        }
        self.acquire_matching_path_lease(peer_id, required_capabilities, |lease| {
            match lease.stream_carrier() {
                Some(crate::connect::StreamCarrier::Generic(handle)) => handle.id() == route_id,
                #[cfg(test)]
                Some(crate::connect::StreamCarrier::GenericTest(handle)) => handle.id() == route_id,
                _ => false,
            }
        })
        .await
    }

    /// Acquire the lease for the exact Relay data client that delivered an
    /// inbound frame. Relay data clients are compared by identity because a
    /// new reservation may exist while an old one is still draining.
    pub(crate) async fn acquire_path_lease_for_relay_data(
        &self,
        peer_id: &str,
        data: &Arc<RelayDataClient>,
        required_capabilities: u8,
    ) -> Result<crate::connect::PathLease, CoreNetworkError> {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Relay)
            .await
        {
            return Err(CoreNetworkError::NoRoute);
        }
        self.acquire_matching_path_lease(peer_id, required_capabilities, |lease| {
            lease
                .relay_data()
                .is_some_and(|candidate| Arc::ptr_eq(&candidate, data))
        })
        .await
    }

    async fn acquire_matching_path_lease<F>(
        &self,
        peer_id: &str,
        required_capabilities: u8,
        matches: F,
    ) -> Result<crate::connect::PathLease, CoreNetworkError>
    where
        F: Fn(&crate::connect::PathLease) -> bool,
    {
        let _peer_id = PeerId::new(peer_id)?;
        let manager = self
            .peer_path_managers
            .read()
            .await
            .get(peer_id)
            .cloned()
            .ok_or(CoreNetworkError::NoRoute)?;
        let handles = {
            let manager = manager.lock().expect("peer path manager lock");
            let mut handles = manager.direct_ready().to_vec();
            if let Some(handle) = manager.relay_ready() {
                handles.push(handle.clone());
            }
            handles
        };
        for handle in handles {
            if handle.capability_mask() & required_capabilities != required_capabilities {
                continue;
            }
            let projection = manager
                .lock()
                .expect("peer path manager lock")
                .projection(&handle);
            let Some(projection) = projection else {
                continue;
            };
            let Ok(lease) = projection.acquire() else {
                continue;
            };
            if matches(&lease) {
                return Ok(lease);
            }
            lease.release();
        }
        Err(CoreNetworkError::NoRoute)
    }

    /// Ensure one business capability through the peer supervisor. This path
    /// starts the supervisor mailbox worker but never enables maintenance;
    /// only an explicit ConnectPeer intent may do that.
    pub(crate) async fn ensure_business_path(
        state: Arc<Self>,
        peer_id: &str,
        command_id: &str,
        class: network_protocol::CommunicationClass,
        required_capabilities: u8,
    ) -> Result<SessionId, CoreNetworkError> {
        if let Some(session_id) = state.connection_sessions.current_session_id(peer_id).await {
            if state
                .acquire_path_lease(peer_id, required_capabilities)
                .await
                .is_ok()
            {
                return Ok(session_id);
            }
        }

        let supervisor = state.peer_supervisors.get_or_create(peer_id)?;
        let intent = state.peer_supervisors.start_business(
            Arc::clone(&state),
            peer_id,
            command_id.to_string(),
            class,
        )?;
        match intent.completion().await {
            Ok(Ok(crate::connect::PeerState::Online)) => {
                let session_id = state
                    .connection_sessions
                    .current_session_id(peer_id)
                    .await
                    .ok_or(CoreNetworkError::NoRoute)?;
                if state
                    .acquire_path_lease(peer_id, required_capabilities)
                    .await
                    .is_err()
                {
                    supervisor.path_lost();
                    return Err(CoreNetworkError::NoRoute);
                }
                Ok(session_id)
            }
            Ok(Ok(_)) | Ok(Err(CoreNetworkError::NoRoute)) => Err(CoreNetworkError::NoRoute),
            Ok(Err(error)) => Err(error),
            Err(_) => Err(CoreNetworkError::Cancelled),
        }
    }

    async fn publish_transport_path(
        &self,
        peer_id: &str,
        session_id: SessionId,
        route: crate::connect::ActiveRoute,
    ) -> Result<Option<PathHandle>, CoreNetworkError> {
        let profile = route.profile();
        if !self.route_is_authorized(peer_id, profile.topology()).await {
            route.close().await;
            return Err(CoreNetworkError::NoRoute);
        }
        let manager = self.peer_path_manager(peer_id).await?;
        let (old_handle, projection) = {
            let mut manager = manager.lock().expect("peer path manager lock");
            let old_handle = match profile.topology() {
                crate::connection::RouteTopology::Direct => manager.direct_ready().first().cloned(),
                crate::connection::RouteTopology::Relay => manager.relay_ready().cloned(),
            };
            let handle = manager.publish_ready_with_route(route)?;
            let projection = manager
                .projection(&handle)
                .ok_or(CoreNetworkError::StaleAttempt)?;
            (old_handle, projection)
        };
        self.path_projections
            .replace_topology(peer_id, session_id, projection)
            .await;
        let mut recovery = self.direct_recovery.lock().expect("recovery policy lock");
        let policy = recovery.entry(peer_id.to_string()).or_default();
        match profile.topology() {
            crate::connection::RouteTopology::Direct => policy.mark_direct_ready(),
            crate::connection::RouteTopology::Relay => policy.mark_relay_ready(),
        }
        Ok(old_handle)
    }

    pub(crate) async fn has_ready_direct_path(&self, peer_id: &str) -> bool {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return false;
        }
        self.peer_path_managers
            .read()
            .await
            .get(peer_id)
            .is_some_and(|manager| {
                !manager
                    .lock()
                    .expect("peer path manager lock")
                    .direct_ready()
                    .is_empty()
            })
    }

    /// Return whether an already-ready Direct path satisfies the requested
    /// capability mask.  A ready path with a different capability is not a
    /// successful Stage A reuse candidate.
    pub(crate) async fn has_ready_direct_path_for_capability(
        &self,
        peer_id: &str,
        required_capabilities: u8,
    ) -> bool {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return false;
        }
        self.peer_path_managers
            .read()
            .await
            .get(peer_id)
            .is_some_and(|manager| {
                manager
                    .lock()
                    .expect("peer path manager lock")
                    .direct_ready()
                    .iter()
                    .any(|handle| {
                        handle.capability_mask() & required_capabilities == required_capabilities
                    })
            })
    }

    pub(crate) async fn has_ready_relay_path(&self, peer_id: &str) -> bool {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Relay)
            .await
        {
            return false;
        }
        self.peer_path_managers
            .read()
            .await
            .get(peer_id)
            .is_some_and(|manager| {
                manager
                    .lock()
                    .expect("peer path manager lock")
                    .relay_ready()
                    .is_some()
            })
    }

    pub(crate) fn reset_direct_recovery(&self, peer_id: &str) {
        let mut recovery = self.direct_recovery.lock().expect("recovery policy lock");
        recovery
            .entry(peer_id.to_string())
            .or_default()
            .reset_after_environment_change();
    }

    pub(crate) fn next_direct_recovery_delay(&self, peer_id: &str) -> Option<Duration> {
        self.direct_recovery
            .lock()
            .expect("recovery policy lock")
            .get_mut(peer_id)
            .and_then(crate::discovery::DirectRecoveryPolicy::next_delay)
    }

    pub(crate) async fn arm_direct_probe(
        &self,
        peer_id: &str,
        generation: crate::connect::IntentGeneration,
        budget: Duration,
        required_capabilities: u8,
    ) -> bool {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return false;
        }
        let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() else {
            return false;
        };
        let mut manager = manager.lock().expect("peer path manager lock");
        if manager.direct_probe().is_some() {
            return false;
        }
        manager
            .ensure_direct_probe(generation.get(), required_capabilities, budget)
            .is_ok()
    }

    pub(crate) async fn finish_direct_probe(
        &self,
        peer_id: &str,
        generation: crate::connect::IntentGeneration,
    ) {
        if let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() {
            manager
                .lock()
                .expect("peer path manager lock")
                .finish_direct_probe(generation.get());
        }
    }

    pub(crate) async fn attach_connection_for_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        connection: quinn::Connection,
        route: network_protocol::RouteType,
    ) -> Result<Option<PathHandle>, ()> {
        let topology = crate::connection::ConnectionProfile::for_route(route)
            .map(|profile| profile.topology())
            .ok_or(())?;
        if !self.route_is_authorized(peer_id, topology).await {
            connection.close(quinn::VarInt::from_u32(0), b"route unauthorized");
            return Err(());
        }
        let session_id = match self.connection_sessions.current_session_id(peer_id).await {
            Some(session_id) => {
                if expected_session_id.is_some_and(|expected| expected != session_id) {
                    connection.close(quinn::VarInt::from_u32(0), b"stale physical path");
                    return Err(());
                }
                session_id
            }
            None if expected_session_id.is_some() => {
                connection.close(quinn::VarInt::from_u32(0), b"stale physical path");
                return Err(());
            }
            None => {
                let session_id = SessionId::new();
                self.connection_sessions
                    .register_pending_session(peer_id, session_id)
                    .await
                    .map_err(|_| ())?;
                session_id
            }
        };
        self.publish_transport_path(
            peer_id,
            session_id,
            crate::connect::ActiveRoute::quic(connection, route),
        )
        .await
        .map_err(|_| ())
    }

    pub(crate) async fn attach_generic_route_for_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        scope: &mut crate::connect::GenericRouteScope,
    ) -> Result<Option<PathHandle>, ()> {
        let session_id = self
            .connection_sessions
            .current_session_id(peer_id)
            .await
            .ok_or(())?;
        if expected_session_id.is_some_and(|expected| expected != session_id) {
            return Err(());
        }
        let profile = scope.profile().ok_or(())?;
        if !self.route_is_authorized(peer_id, profile.topology()).await {
            return Err(());
        }
        if self.path_profile(peer_id).await == Some(profile) {
            return Err(());
        }
        let owner = scope.commit_and_take_owner()?;
        self.publish_transport_path(
            peer_id,
            session_id,
            crate::connect::ActiveRoute::generic(owner),
        )
        .await
        .map_err(|_| ())
    }

    pub(crate) async fn mark_relay_route_connected(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        relay: Option<Arc<RelayDataClient>>,
    ) -> bool {
        if self.connection_sessions.current_session_id(peer_id).await != Some(expected_session_id) {
            return false;
        }
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Relay)
            .await
        {
            return false;
        }
        self.publish_transport_path(
            peer_id,
            expected_session_id,
            crate::connect::ActiveRoute::relay(relay),
        )
        .await
        .is_ok()
    }

    pub(crate) async fn path_profile(
        &self,
        peer_id: &str,
    ) -> Option<crate::connection::ConnectionProfile> {
        let authorization = self.peer_route_authorization(peer_id).await;
        let (allow_direct, allow_relay) = authorization
            .map(|authorization| (authorization.direct, authorization.relay))
            .unwrap_or((true, true));
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let manager = manager.lock().expect("peer path manager lock");
        match manager.select_with_authorization(0, allow_direct, allow_relay)? {
            crate::connect::PathSelection::Direct => {
                manager.direct_ready().first().map(PathHandle::profile)
            }
            crate::connect::PathSelection::Relay => manager.relay_ready().map(PathHandle::profile),
        }
    }

    /// Check the currently ready physical paths against a business capability
    /// without allowing the ConnectionSession admission store to answer the
    /// route question.
    pub(crate) async fn path_supports_capability(
        &self,
        peer_id: &str,
        required_capabilities: u8,
    ) -> bool {
        let authorization = self.peer_route_authorization(peer_id).await;
        let (allow_direct, allow_relay) = authorization
            .map(|authorization| (authorization.direct, authorization.relay))
            .unwrap_or((true, true));
        let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() else {
            return false;
        };
        let supports = manager
            .lock()
            .expect("peer path manager lock")
            .select_with_authorization(required_capabilities, allow_direct, allow_relay)
            .is_some();
        supports
    }

    pub(crate) async fn e2ee_policy(
        &self,
        peer_id: &str,
    ) -> crate::crypto_handshake::path_handshake::E2eePolicy {
        let configured = self
            .peers
            .read()
            .await
            .get(peer_id)
            .map(|peer| peer.e2ee_policy)
            .unwrap_or(network_protocol::E2eePolicy::Required);
        crate::crypto_handshake::path_handshake::E2eePolicy::from_network_code(configured as i32)
            .unwrap_or_default()
    }

    pub(crate) async fn path_route(&self, peer_id: &str) -> Option<network_protocol::RouteType> {
        self.path_profile(peer_id)
            .await
            .and_then(|profile| profile.route().to_wire())
    }

    pub(crate) async fn path_connection_for_lease(
        &self,
        lease: &crate::connect::PathLease,
    ) -> Option<quinn::Connection> {
        if !lease.is_active() {
            return None;
        }
        lease.connection()
    }

    pub(crate) async fn path_relay_data(&self, peer_id: &str) -> Option<Arc<RelayDataClient>> {
        if !self
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Relay)
            .await
        {
            return None;
        }
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let projection = {
            let manager = manager.lock().expect("peer path manager lock");
            manager
                .relay_ready()
                .and_then(|handle| manager.projection(handle))
        }?;
        projection.acquire().ok()?.relay_data()
    }

    pub(crate) async fn path_relay_data_for_lease(
        &self,
        lease: &crate::connect::PathLease,
    ) -> Option<Arc<RelayDataClient>> {
        if !lease.is_active() {
            return None;
        }
        lease.relay_data()
    }

    pub(crate) async fn path_is_current_relay_data(
        &self,
        peer_id: &str,
        data: &Arc<RelayDataClient>,
    ) -> bool {
        self.path_relay_data(peer_id)
            .await
            .is_some_and(|current| Arc::ptr_eq(&current, data))
    }

    pub(crate) async fn path_send_channel_frame_for_lease(
        &self,
        lease: &crate::connect::PathLease,
        relay_token: &str,
        kind: crate::connection::GenericFrameKind,
        payload: &[u8],
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if !lease.is_active() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "path lease inactive",
            )
            .into());
        }
        let result = lease.send_channel_frame(relay_token, kind, payload).await;
        if result.is_ok() && !lease.is_active() {
            return Err(
                std::io::Error::new(std::io::ErrorKind::NotConnected, "path lease lost").into(),
            );
        }
        result
    }

    pub(crate) async fn path_is_connected(&self, peer_id: &str) -> bool {
        let current_session = self.connection_sessions.current_session_id(peer_id).await;
        let Some(session_id) = current_session else {
            return false;
        };
        self.path_projections.has_alive(peer_id, session_id).await
    }

    /// Validate an authenticated candidate before its peer-owned path is
    /// published. This is an admission check, not a connectivity truth read:
    /// the candidate owns no Runtime path until the caller commits it.
    pub(crate) async fn candidate_supports_required(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        profile: crate::connection::ConnectionProfile,
    ) -> bool {
        self.connection_sessions.current_session_id(peer_id).await == Some(expected_session_id)
            && profile_capability_mask(profile) != 0
    }

    /// Validate a candidate against the requested capability before path
    /// publication. The capability mask remains attempt-local and is never
    /// stored in ConnectionSessionStore.
    pub(crate) async fn candidate_supports(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        profile: crate::connection::ConnectionProfile,
        required_capabilities: u8,
    ) -> bool {
        self.connection_sessions.current_session_id(peer_id).await == Some(expected_session_id)
            && profile_capability_mask(profile) & required_capabilities == required_capabilities
    }

    pub(crate) async fn path_admission_can_retry(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
    ) -> bool {
        self.connection_sessions.current_session_id(peer_id).await == expected_session_id
            && self
                .connection_sessions
                .current_remote_session_binding(peer_id)
                .await
                .is_none()
    }

    pub(crate) async fn wait_for_path_change(&self) {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    pub(crate) async fn fail_session(&self, peer_id: &str, session_id: SessionId) {
        // A stale coordinator must only hard-close projections that still
        // belong to its exact session.  The peer may already have admitted a
        // replacement path by the time the failure is observed.
        self.close_transport_path_for_session(peer_id, session_id)
            .await;
        if self
            .connection_sessions
            .retire_session(peer_id, session_id)
            .await
        {
            self.cancel_session_tasks(peer_id, session_id).await;
        }
    }

    /// Hard-close only the physical projections owned by `session_id`.
    ///
    /// `PeerPathManager` is the carrier owner and can hold independent Direct
    /// and Relay paths.  The projection index supplies the session binding;
    /// the manager handle check prevents a stale coordinator from closing a
    /// newer path that reused the same topology slot.
    async fn close_transport_path_for_session(&self, peer_id: &str, session_id: SessionId) -> bool {
        let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() else {
            return false;
        };

        // The projection store returns a snapshot. We deliberately do not
        // hold the synchronous path-manager lock across this await; manager
        // handles are rechecked immediately before close.
        let handles = self
            .path_projections
            .handles_for_session(peer_id, session_id)
            .await;
        let direct_handle = handles.direct;
        let relay_handle = handles.relay;

        let (direct_closed, relay_closed) = {
            let mut manager = manager.lock().expect("peer path manager lock");
            let direct_closed = direct_handle.as_ref().is_some_and(|expected| {
                if manager.direct_ready().first() == Some(expected) {
                    manager.hard_close_direct();
                    true
                } else {
                    false
                }
            });
            let relay_closed = relay_handle.as_ref().is_some_and(|expected| {
                if manager.relay_ready() == Some(expected) {
                    manager.hard_close_relay();
                    true
                } else {
                    false
                }
            });
            (direct_closed, relay_closed)
        };
        if !direct_closed && !relay_closed {
            return false;
        }

        self.close_inactive_streams(peer_id).await;
        if let Ok(mut recovery) = self.direct_recovery.lock() {
            if direct_closed {
                recovery
                    .entry(peer_id.to_string())
                    .or_default()
                    .mark_direct_unavailable();
            }
            if relay_closed {
                recovery
                    .entry(peer_id.to_string())
                    .or_default()
                    .mark_relay_lost();
            }
        }

        self.path_projections
            .remove_closed_for_session(
                peer_id,
                session_id,
                direct_handle.as_ref().filter(|_| direct_closed),
                relay_handle.as_ref().filter(|_| relay_closed),
            )
            .await;
        true
    }

    /// Retire an exact stale admission without closing the peer's current
    /// physical path or invalidating its `PeerSupervisor` generation.
    ///
    /// A replacement attempt may have reserved the current Session while a
    /// Resolve response still exposes an older `ReadySessionIndex` entry. In
    /// that case the old admission is no longer the path owner, so the
    /// attempt coordinator must only retire its session-scoped resources.
    pub(crate) async fn retire_session_without_transport(
        &self,
        peer_id: &str,
        session_id: SessionId,
    ) -> bool {
        if self
            .connection_sessions
            .retire_session(peer_id, session_id)
            .await
        {
            self.cancel_session_tasks(peer_id, session_id).await;
            true
        } else {
            false
        }
    }

    pub(crate) async fn close_transport_path(&self, peer_id: &str) -> Option<PathHandle> {
        let manager = self.peer_path_managers.write().await.remove(peer_id);
        let first = self.path_projections.remove_peer(peer_id).await;
        self.direct_recovery
            .lock()
            .expect("recovery policy lock")
            .remove(peer_id);
        if let Some(manager) = manager {
            manager.lock().expect("peer path manager lock").hard_close();
        }
        first
    }

    pub(crate) async fn close_relay_path(
        &self,
        peer_id: &str,
        data: Option<&Arc<RelayDataClient>>,
    ) -> Option<PathHandle> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let relay_handle = {
            let mut manager = manager.lock().expect("peer path manager lock");
            let handle = manager.relay_ready()?.clone();
            if let Some(wanted) = data {
                let projection = manager.projection(&handle)?;
                let lease = projection.acquire().ok()?;
                let current = lease.relay_data()?;
                if !Arc::ptr_eq(&current, wanted) {
                    return None;
                }
            }
            let closed = manager.hard_close_relay_if_handle(&handle)?;
            if let Ok(mut recovery) = self.direct_recovery.lock() {
                if let Some(policy) = recovery.get_mut(peer_id) {
                    policy.mark_relay_lost();
                }
            }
            closed
        };
        self.cleanup_closed_path(peer_id, &relay_handle).await;
        Some(relay_handle)
    }

    pub(crate) async fn close_direct_path(
        &self,
        peer_id: &str,
        route_id: Option<u64>,
    ) -> Option<PathHandle> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let direct_handle = {
            let mut manager = manager.lock().expect("peer path manager lock");
            let handle = manager.direct_ready().first()?.clone();
            if route_id.is_some_and(|id| id != handle.id()) {
                return None;
            }
            let closed = manager.hard_close_direct_if_handle(&handle)?;
            if let Ok(mut recovery) = self.direct_recovery.lock() {
                if let Some(policy) = recovery.get_mut(peer_id) {
                    policy.mark_direct_unavailable();
                }
            }
            closed
        };
        self.cleanup_closed_path(peer_id, &direct_handle).await;
        Some(direct_handle)
    }

    pub(crate) async fn close_direct_path_for_connection(
        &self,
        peer_id: &str,
        connection: &quinn::Connection,
    ) -> Option<PathHandle> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let direct_handle = {
            let mut manager = manager.lock().expect("peer path manager lock");
            let handle = manager.direct_ready().first()?.clone();
            let projection = manager.projection(&handle)?;
            let lease = projection.acquire().ok()?;
            let candidate = lease.connection()?;
            if candidate.stable_id() != connection.stable_id() {
                return None;
            }
            let closed = manager.hard_close_direct_if_handle(&handle)?;
            if let Ok(mut recovery) = self.direct_recovery.lock() {
                if let Some(policy) = recovery.get_mut(peer_id) {
                    policy.mark_direct_unavailable();
                }
            }
            closed
        };
        self.cleanup_closed_path(peer_id, &direct_handle).await;
        Some(direct_handle)
    }

    pub(crate) async fn close_all_relay_paths(&self) {
        let peers = self
            .peer_path_managers
            .read()
            .await
            .iter()
            .filter(|(_, manager)| {
                manager
                    .lock()
                    .expect("peer path manager lock")
                    .relay_ready()
                    .is_some()
            })
            .map(|(peer_id, _)| peer_id.clone())
            .collect::<Vec<_>>();
        for peer_id in peers {
            let _ = self.close_relay_path(&peer_id, None).await;
        }
    }

    pub(crate) async fn close_all_transport_paths(&self) {
        let peers = self
            .peer_path_managers
            .read()
            .await
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        for peer_id in peers {
            let _ = self.close_transport_path(&peer_id).await;
        }
    }

    /// Finish asynchronous cleanup for one exact closed path.
    ///
    /// Keep an empty manager registered: a concurrent publisher may already
    /// hold a clone of that manager outside the map lock. Only explicit peer
    /// transport close and runtime shutdown remove the manager registration.
    async fn cleanup_closed_path(&self, peer_id: &str, handle: &PathHandle) {
        self.close_inactive_streams(peer_id).await;
        self.path_projections.remove_handle(peer_id, handle).await;
    }

    #[cfg(test)]
    pub(crate) async fn attach_test_generic_route(
        &self,
        peer_id: &str,
        session_id: SessionId,
        handle: crate::connection::GenericRouteHandle,
    ) -> Result<(), ()> {
        self.publish_transport_path(
            peer_id,
            session_id,
            crate::connect::ActiveRoute::generic_test(handle),
        )
        .await
        .map(|_| ())
        .map_err(|_| ())
    }

    #[cfg(test)]
    pub(crate) async fn close_path_for_test(&self, peer_id: &str) {
        let session_id = self.connection_sessions.current_session_id(peer_id).await;
        if self.close_direct_path(peer_id, None).await.is_some() {
            if let Some(session_id) = session_id {
                if self
                    .connection_sessions
                    .retire_session(peer_id, session_id)
                    .await
                {
                    self.cancel_session_tasks(peer_id, session_id).await;
                    if let Ok(supervisor) = self.peer_supervisors.get_or_create(peer_id) {
                        supervisor.path_lost();
                    }
                    crate::events::emit_peer_state(
                        &self.event_tx,
                        peer_id,
                        network_protocol::PeerConnectionState::Disconnected,
                        network_protocol::RouteType::Unspecified,
                        None,
                    );
                }
            }
        }
    }

    pub(crate) async fn crypto_context(
        &self,
        peer_id: &str,
        session_id: &str,
    ) -> Result<Arc<Mutex<CryptoContext>>, CryptoError> {
        self.crypto.get(peer_id, session_id)
    }

    pub(crate) fn install_crypto_material(
        &self,
        peer_id: &str,
        session_id: &str,
        material: &SessionCryptoMaterial,
    ) -> Result<(), CryptoError> {
        self.crypto
            .install_material_aliases(
                peer_id,
                &[session_id, material.remote_session_binding.as_str()],
                material.root_key,
                material.initiator,
            )
            .map(|_| ())
    }

    pub(crate) async fn encrypt_application_payload(
        &self,
        peer_id: &str,
        session_id: &str,
        aad: &[u8],
        plaintext: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let context = self.crypto_context(peer_id, session_id).await?;
        let result = context
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?
            .encrypt(aad, plaintext);
        result
    }

    pub(crate) async fn decrypt_application_payload(
        &self,
        peer_id: &str,
        session_id: &str,
        aad: &[u8],
        envelope: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let context = self.crypto_context(peer_id, session_id).await?;
        let result = context
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?
            .decrypt(aad, envelope);
        result
    }

    pub(crate) async fn decrypt_application_payload_for_delivery(
        &self,
        peer_id: &str,
        session_id: &str,
        aad: &[u8],
        envelope: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let context = self.crypto_context(peer_id, session_id).await?;
        let result = context
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?
            .decrypt_for_delivery(aad, envelope);
        result
    }

    /// Returns the per-peer ReliableStream manager, creating it lazily. The
    /// manager holds the receive buffers and QUIC send halves for every byte
    /// stream to `peer_id` (§17).
    pub(crate) async fn stream_manager(&self, peer_id: &str) -> ReliableStreamManager {
        let mut map = self.reliable_streams.write().await;
        map.entry(peer_id.to_string())
            .or_insert_with(|| ReliableStreamManager::new(self.event_tx.clone()))
            .clone()
    }

    /// Close streams whose long-lived path lease was revoked by a hard path
    /// close. Normal retirement leaves the lease active and therefore does not
    /// reach this boundary; the stream remains bound to its original path
    /// until the operation closes normally.
    pub(crate) async fn close_inactive_streams(&self, peer_id: &str) {
        let Some(manager) = self.reliable_streams.read().await.get(peer_id).cloned() else {
            return;
        };
        let local_opener_device_id = self
            .lifecycle
            .identity
            .read()
            .await
            .as_ref()
            .map(|identity| identity.device_id.clone())
            .unwrap_or_default();
        let _ = manager
            .close_inactive(peer_id, &local_opener_device_id)
            .await;
    }
}

/// 管理 Tokio 异步运行时生命周期与命令/事件通道。
pub struct NetworkRuntime {
    pub(crate) runtime: Arc<Runtime>,
    pub(crate) command_tx: Mutex<Option<mpsc::Sender<NetworkCommand>>>,
    pub(crate) event_rx: Arc<Mutex<EventReceiver>>,
    pub(crate) event_tx: EventSender,
    pub(crate) bound_port: Arc<AtomicU16>,
    pub(crate) lifecycle: AtomicU8,
    pub(crate) state: Mutex<Option<Arc<RuntimeState>>>,
    pub(crate) stop_notify: Arc<Notify>,
}

impl NetworkRuntime {
    /// 创建运行时。调用 `start` 并提交配置命令后才开始使用网络；
    /// 生命周期转换前不会启动 worker。
    pub fn new() -> Result<Self, NetworkError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("ssh-net-worker")
            .build()
            .map_err(|error| NetworkError::RuntimeInitFailed(error.to_string()))?;
        let (event_tx, event_rx) = BoundedEventLanes::channel();
        let bound_port = Arc::new(AtomicU16::new(0));
        info!("NetworkRuntime initialized successfully");
        Ok(Self {
            runtime: Arc::new(runtime),
            command_tx: Mutex::new(None),
            event_rx: Arc::new(Mutex::new(event_rx)),
            event_tx,
            bound_port,
            lifecycle: AtomicU8::new(RUNTIME_CREATED),
            state: Mutex::new(None),
            stop_notify: Arc::new(Notify::new()),
        })
    }

    /// 将运行时从 Created 转换为 Running，并启动 worker。
    pub fn start(&self) -> Result<(), NetworkError> {
        self.lifecycle
            .compare_exchange(
                RUNTIME_CREATED,
                RUNTIME_RUNNING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| NetworkError::RuntimeNotRunning)?;
        let (command_tx, command_rx) = mpsc::channel::<NetworkCommand>(COMMAND_MAILBOX_CAPACITY);
        let state = Arc::new(RuntimeState::new(
            self.event_tx.clone(),
            Arc::clone(&self.bound_port),
        ));
        *self.state.lock().map_err(|_| {
            NetworkError::CommandQueueFailed("runtime state lock poisoned".into())
        })? = Some(Arc::clone(&state));
        let _runtime_guard = self.runtime.enter();
        if state
            .task_supervisor
            .spawn_runtime(
                "command-worker",
                run_command_worker(command_rx, Arc::clone(&state)),
            )
            .is_none()
        {
            return Err(NetworkError::RuntimeNotRunning);
        }
        *self
            .command_tx
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("command lock poisoned".into()))? =
            Some(command_tx);
        Ok(())
    }

    /// 恰好停止 worker 一次；重复调用仍然成功。
    pub fn stop(&self) -> Result<(), NetworkError> {
        let current = self.lifecycle.load(Ordering::Acquire);
        if current == RUNTIME_CREATED || current == RUNTIME_STOPPED {
            self.bound_port.store(0, Ordering::Release);
            self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
            self.stop_notify.notify_waiters();
            return Ok(());
        }
        if current == RUNTIME_STOPPING {
            loop {
                let notified = self.stop_notify.notified();
                if self.lifecycle.load(Ordering::Acquire) != RUNTIME_STOPPING {
                    break;
                }
                self.runtime.block_on(notified);
            }
            return Ok(());
        }
        self.lifecycle
            .compare_exchange(
                RUNTIME_RUNNING,
                RUNTIME_STOPPING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| NetworkError::RuntimeNotRunning)?;
        self.command_tx
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("command lock poisoned".into()))?
            .take();
        let state = self
            .state
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("runtime state lock poisoned".into()))?
            .take();
        if let Some(state) = state {
            self.shutdown_listener(state);
        }
        self.bound_port.store(0, Ordering::Release);
        self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
        self.stop_notify.notify_waiters();
        Ok(())
    }

    /// 返回 native QUIC endpoint 实际绑定的 UDP 端口。
    ///
    /// 该值只用于受控测试和诊断；调用方不会获得 socket 或 Quinn handle。
    pub fn bound_local_port(&self) -> Option<u16> {
        let port = self.bound_port.load(Ordering::Acquire);
        (port != 0).then_some(port)
    }

    /// Acquires an opaque native screen-media endpoint for a live Realtime
    /// session. The endpoint is bound to the current runtime/session generation
    /// and cannot expose the peer, socket, or media payload through this API.
    pub fn create_realtime_media_endpoint(
        &self,
        realtime_id: &str,
        peer_id: &str,
        direction: crate::realtime_media::RealtimeMediaDirection,
        expected_generation: u64,
    ) -> Result<
        crate::realtime_media::RealtimeMediaEndpointId,
        crate::realtime_media::RealtimeMediaError,
    > {
        let state = self.media_state()?;
        self.runtime
            .block_on(crate::realtime_media::create_endpoint(
                &state,
                realtime_id,
                peer_id,
                direction,
                expected_generation,
            ))
    }

    /// Test-only seam used by network-ffi to exercise the complete C ABI
    /// success path against a live native Realtime driver. It is excluded from
    /// normal builds and never exposes the driver or PeerConnection handle.
    #[cfg(feature = "ffi-test-support")]
    #[doc(hidden)]
    pub fn install_ffi_test_realtime_session(
        &self,
        realtime_id: &str,
        peer_id: &str,
    ) -> Result<u64, crate::realtime_media::RealtimeMediaError> {
        let state = self.media_state()?;
        self.runtime.block_on(async move {
            let mut driver = network_webrtc::RealtimeIoDriver::bind(
                network_webrtc::WebRtcPeer::new(network_webrtc::WebRtcConfig::default())
                    .map_err(|_| crate::realtime_media::RealtimeMediaError::DriverUnavailable)?,
                "127.0.0.1:0".parse().expect("valid loopback bind address"),
            )
            .await
            .map_err(|_| crate::realtime_media::RealtimeMediaError::DriverUnavailable)?;
            driver
                .peer_mut()
                .configure_h264_screen_video(
                    network_webrtc::MediaDirection::Sendrecv,
                    Some(0x1357_2468),
                )
                .map_err(|_| crate::realtime_media::RealtimeMediaError::DriverUnavailable)?;
            let driver = driver.into_handle();
            let mut manager = state.realtime.lock().await;
            Ok(manager.insert_ffi_test_driver_session(
                realtime_id.to_owned(),
                peer_id.to_owned(),
                driver,
            ))
        })
    }

    /// Test-only packet injection companion for
    /// [`install_ffi_test_realtime_session`]. Real callers receive RTP from
    /// the I/O driver; this only makes the pull half of the C ABI deterministic.
    #[cfg(feature = "ffi-test-support")]
    #[doc(hidden)]
    pub fn inject_ffi_test_realtime_media_frame(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
        frame: network_webrtc::EncodedVideoFrame,
    ) -> Result<(), crate::realtime_media::RealtimeMediaError> {
        let state = self.media_state()?;
        crate::realtime_media::inject_test_endpoint_frame(&state, endpoint_id, frame)
    }

    /// Releases an endpoint lease. Release remains idempotent after runtime
    /// stop because the registry has already invalidated every endpoint.
    pub fn release_realtime_media_endpoint(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
    ) -> Result<(), crate::realtime_media::RealtimeMediaError> {
        let state = self
            .state
            .lock()
            .map_err(|_| crate::realtime_media::RealtimeMediaError::Internal)?
            .clone();
        let Some(state) = state else {
            return Ok(());
        };
        crate::realtime_media::release_endpoint(&state, endpoint_id)
    }

    /// Submits a native-resident encoded H.264 access unit to a send endpoint.
    pub fn push_realtime_media_h264(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
        frame: network_webrtc::EncodedVideoFrame,
    ) -> Result<network_webrtc::VideoEnqueueResult, crate::realtime_media::RealtimeMediaError> {
        let state = self.media_state()?;
        crate::realtime_media::push_endpoint(&state, endpoint_id, frame)
    }

    /// Reads one native-resident encoded H.264 access unit from a receive
    /// endpoint. It never routes through the protobuf event queue.
    pub fn pop_realtime_media_h264(
        &self,
        endpoint_id: crate::realtime_media::RealtimeMediaEndpointId,
    ) -> Result<Option<network_webrtc::EncodedVideoFrame>, crate::realtime_media::RealtimeMediaError>
    {
        let state = self.media_state()?;
        crate::realtime_media::pop_endpoint(&state, endpoint_id)
    }

    /// 返回原生轮询边界使用的 Tokio handle。
    pub fn handle(&self) -> &tokio::runtime::Handle {
        self.runtime.handle()
    }

    /// 运行时处于 Running 时入队一个 V2 命令。
    pub fn send_command(&self, command: NetworkCommand) -> Result<(), NetworkError> {
        if self.lifecycle.load(Ordering::Acquire) != RUNTIME_RUNNING {
            return Err(NetworkError::RuntimeNotRunning);
        }
        let sender = self
            .command_tx
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("command lock poisoned".into()))?
            .as_ref()
            .ok_or(NetworkError::RuntimeNotRunning)?
            .clone();
        sender.try_send(command).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => {
                NetworkError::CommandQueueFailed("command mailbox is full".into())
            }
            mpsc::error::TrySendError::Closed(_) => {
                NetworkError::CommandQueueFailed("command mailbox is closed".into())
            }
        })
    }

    /// 轮询一个事件，但不向调用方暴露内部 receiver。
    pub fn poll_event(&self, timeout_ms: u32) -> Option<NetworkEvent> {
        let mut receiver = self.event_rx.lock().ok()?;
        if timeout_ms == 0 {
            receiver.try_recv()
        } else {
            let handle = self.runtime.handle();
            let _guard = handle.enter();
            handle
                .block_on(tokio::time::timeout(
                    Duration::from_millis(timeout_ms as u64),
                    receiver.recv(),
                ))
                .ok()?
        }
    }

    /// 为原生测试和受控集成注入一个事件。
    pub fn emit_event(&self, event: NetworkEvent) {
        let _ = self.event_tx.send(event);
    }

    fn media_state(&self) -> Result<Arc<RuntimeState>, crate::realtime_media::RealtimeMediaError> {
        if self.lifecycle.load(Ordering::Acquire) != RUNTIME_RUNNING {
            return Err(crate::realtime_media::RealtimeMediaError::RuntimeNotRunning);
        }
        self.state
            .lock()
            .map_err(|_| crate::realtime_media::RealtimeMediaError::Internal)?
            .clone()
            .ok_or(crate::realtime_media::RealtimeMediaError::RuntimeNotRunning)
    }

    /// Cancel the root, close every native I/O owner, then await every task
    /// registered in the supervisor before releasing the runtime state.
    fn shutdown_listener(&self, state: Arc<RuntimeState>) {
        self.runtime.block_on(async move {
            state.task_supervisor.cancel_root();
            crate::realtime_media::invalidate_all(&state);
            state.peer_supervisors.stop_all();
            state.close_all_transport_paths().await;
            // 控制面 Drop 会中止后台读写 worker（RelayControlClient::drop）；显式
            // take 释放共享引用即可。
            state.relay.control.write().await.take();
            state.realtime.lock().await.close_all();
            // A caller that observed `Running` immediately before `stop()`
            // moved the lifecycle to Stopping can still hold a cloned state.
            // Revoke again after the terminal peer close so that race cannot
            // publish a fresh endpoint into a stopped runtime generation.
            crate::realtime_media::invalidate_all(&state);
            if let Some(endpoint) = state.lifecycle.endpoint.write().await.take() {
                endpoint.close(quinn::VarInt::from_u32(0), b"runtime stopping");
            }
            state.task_supervisor.shutdown().await;
        });
    }

    /// 仅测试用：为当前 Peer 显式驱动一次确定性 recovery，返回其 wire key。
    ///
    /// 测试在连接保持稳定时显式重放未 ACK 消息，验证接收端按 MessageId 去重。
    /// 重放会以当前 ConnectionSession 重新编码发送（§20），不依赖生产重连路径。
    #[cfg(test)]
    pub(crate) fn recover_current_peer_for_test(&self, peer_id: &str) -> Option<String> {
        let state = self
            .state
            .lock()
            .expect("runtime state lock")
            .clone()
            .expect("runtime state");
        self.runtime.block_on(async move {
            let session_id = state
                .connection_sessions
                .current_session_id(peer_id)
                .await?;
            let wire_key = session_id.wire_key();
            crate::channel::recover_session(Arc::clone(&state), peer_id.to_string()).await;
            Some(wire_key)
        })
    }
}

/// Rust 侧最终销毁时中止仍存在的 supervised tasks。
impl Drop for NetworkRuntime {
    /// 中止在显式停止转换后仍存活的 tasks。
    fn drop(&mut self) {
        if let Ok(mut sender) = self.command_tx.lock() {
            sender.take();
        }
        if let Ok(mut state) = self.state.lock() {
            if let Some(state) = state.take() {
                if let Ok(mut endpoint) = state.lifecycle.endpoint.try_write() {
                    if let Some(endpoint) = endpoint.take() {
                        endpoint.close(quinn::VarInt::from_u32(0), b"runtime dropped");
                    }
                }
                if let Ok(mut realtime) = state.realtime.try_lock() {
                    crate::realtime_media::invalidate_all(&state);
                    realtime.close_all();
                }
                state.peer_supervisors.stop_all();
                state.task_supervisor.abort_all_now();
            }
        }
        self.bound_port.store(0, Ordering::Release);
        self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
        self.stop_notify.notify_waiters();
    }
}

#[cfg(test)]
#[path = "tests/runtime.rs"]
mod tests;
