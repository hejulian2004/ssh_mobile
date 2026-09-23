use std::collections::HashMap;
use std::sync::{atomic::AtomicU16, Arc, Mutex};
use tokio::sync::{Mutex as AsyncMutex, Notify, RwLock};

use crate::connect::profile_capability_mask;
use crate::crypto::{CryptoContext, CryptoError, SessionCryptoManager};
use crate::crypto_handshake::SessionCryptoMaterial;
use crate::delivery::DeliveryManager;
use crate::runtime_path_projections::RuntimePathProjectionStore;
use crate::session::{
    ConnectionAdmissionError, ConnectionAdmissionOutcome, ConnectionSessionStore, SessionId,
};
use crate::stream::ReliableStreamManager;
use crate::task_supervisor::RuntimeTaskSupervisor;

use super::lifecycle::RuntimeLifecycleState;
use super::{
    ConnectDecision, ConnectionAdmissionLease, EventSender, PeerRouteAuthorization, RuntimeState,
};

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
            path_changed: Notify::new(),
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
    /// Capability is not an admission input. Callers must reject a carrier
    /// whose profile cannot carry the request before this claim, so a weak
    /// candidate cannot become the single winner. A replaced Session is
    /// destroyed here because it belongs to another connection.
    pub(crate) async fn admit_authenticated_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        remote_session_binding: &str,
    ) -> Result<ConnectionAdmissionLease, ConnectionAdmissionError> {
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
        self.notify_path_changed();
        Ok(ConnectionAdmissionLease::new(admission))
    }

    pub(crate) fn notify_path_changed(&self) {
        self.path_changed.notify_waiters();
    }

    #[cfg(test)]
    pub(crate) async fn allow_routes_for_test(&self, peer_id: &str) {
        self.peer_route_authorizations.write().await.insert(
            peer_id.to_string(),
            PeerRouteAuthorization {
                direct: true,
                relay: true,
            },
        );
    }

    pub(crate) fn path_change_notified(&self) -> tokio::sync::futures::Notified<'_> {
        self.path_changed.notified()
    }

    pub(crate) async fn release_claimed_session(
        &self,
        peer_id: &str,
        session_id: SessionId,
        remote_session_binding: &str,
    ) -> bool {
        let released = self
            .connection_sessions
            .release_authenticated_session(peer_id, session_id, remote_session_binding)
            .await;
        if released {
            self.notify_path_changed();
        }
        released
    }

    /// Return the command-registered route policy. A missing record is not
    /// authorization: callers must fail closed until UpsertPeerV2 writes one.
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
            .is_some_and(|authorization| match topology {
                crate::connection::RouteTopology::Direct => authorization.direct,
                crate::connection::RouteTopology::Relay => authorization.relay,
            })
    }

    pub(crate) async fn authorized_route_flags(&self, peer_id: &str) -> (bool, bool) {
        self.peer_route_authorization(peer_id)
            .await
            .map(|authorization| (authorization.direct, authorization.relay))
            .unwrap_or((false, false))
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
            self.notify_path_changed();
        }
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
            self.notify_path_changed();
            true
        } else {
            false
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
