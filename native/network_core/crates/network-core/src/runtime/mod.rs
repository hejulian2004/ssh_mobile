//! V2 网络运行时生命周期、共享状态与命令/事件通道。

use std::collections::HashMap;
use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{
    atomic::{AtomicU16, AtomicU8},
    Arc, Mutex,
};
use std::time::Duration;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, Mutex as AsyncMutex, Notify, RwLock};

use network_nat::{PathManager, ResolvedCandidateCache};
use network_protocol::NetworkCommand;

use crate::connect::{PathLease, PeerPathManager};
use crate::crypto::SessionCryptoManager;
use crate::delivery::DeliveryManager;
use crate::runtime_path_projections::RuntimePathProjectionStore;
use crate::session::{ConnectionAdmission, ConnectionSessionStore, SessionId};
use crate::stream::ReliableStreamManager;
use crate::task_supervisor::RuntimeTaskSupervisor;

pub(crate) use crate::runtime_event_lanes::{EventReceiver, EventSender};

#[cfg(test)]
use crate::errors::{CoreNetworkError, NetworkError};
#[cfg(test)]
use network_protocol::NetworkEvent;
#[cfg(test)]
use network_relay::RelayDataClient;

mod admission;
mod facade;
mod lifecycle;
mod path_acquire;
mod path_close;
mod path_publish;

use lifecycle::RuntimeLifecycleState;

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
    /// Wakes connect and admission loops when a path or session claim changes.
    path_changed: Notify,
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

#[cfg(test)]
#[path = "../tests/runtime.rs"]
mod tests;
