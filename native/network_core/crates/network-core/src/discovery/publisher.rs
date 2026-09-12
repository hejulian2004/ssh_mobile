//! transport-network v2：可靠 Discovery 发布（设计 §9）。
//!
//! [`DiscoveryPublisher`] 驱动固定发布协议：
//!
//! ```text
//! trigger → DiscoveryPublish{request_id, snapshot} → RelayControlClient
//!        → server Redis CAS → DiscoveryAck{request_id, runtime_epoch, revision}
//!        → 匹配 ACK → mark_published()
//!        → 失败/超时/ACK 不匹配 → bounded retry
//!        → 超过上限 → mark_degraded()（控制连接不需要断开）
//! ```
//!
//! 退避调度为 500ms / 1s / 2s / 4s / 4s，最多 [`super::DISCOVERY_PUBLISH_MAX_ATTEMPTS`]
//! 次尝试。request_id 逐次分配；ACK 关联：
//!
//! - [`RelayControlClient`] 内部按 wire request_id 逐请求关联（`pending` oneshot 表，
//!   无 v1 全局 Notify）。
//! - 忠实 sink（测试 mock）把发布者分配的 request_id 原样带回 ACK，发布者做
//!   request_id 级校验；`RelayControlClient` 自行分配 wire request_id，因此只做
//!   runtime_epoch + revision 语义校验（[`DiscoveryControlPlane::echoes_request_id`]）。

use std::future::Future;
use std::pin::Pin;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};
use std::time::Duration;

use network_relay::v2::{
    ConnectivityAnswer, ConnectivityAttemptStart, DiscoveryAck, DiscoverySnapshot,
    RelayReserveResponse, ResolvePeerResponse, RuntimeEpoch,
};
use network_relay::{RelayControlClient, RelayError};

use crate::runtime::RuntimeState;
use crate::task_supervisor::TaskId;

use super::local_discovery::LocalDiscoveryManager;
use super::{
    DISCOVERY_PUBLISH_MAX_ATTEMPTS, DISCOVERY_PUBLISH_RETRY_BACKOFF_MS, DISCOVERY_PUBLISH_TIMEOUT,
};

/// v2 控制面发布/解析端口（§31 `RelayControlClient` 的抽象）。
///
/// 用 boxed future 保持 object-safe，`RelayControlClient` 与测试 mock 都能实现。
#[allow(clippy::type_complexity)]
pub(crate) trait DiscoveryControlPlane: Send + Sync {
    /// 发布一次 DiscoverySnapshot，等待关联 ACK。
    fn publish_discovery(
        &self,
        request_id: u64,
        snapshot: DiscoverySnapshot,
    ) -> Pin<Box<dyn Future<Output = Result<DiscoveryAck, RelayError>> + Send + '_>>;

    /// 解析对端 Discovery（§10 4-state）。
    #[allow(dead_code)] // forward path：Step 6 由 DiscoveryResolver 使用
    fn resolve_peer(
        &self,
        target_device_id: &str,
    ) -> Pin<Box<dyn Future<Output = Result<ResolvePeerResponse, RelayError>> + Send + '_>>;

    /// 控制面 socket 是否仍可发送新帧。
    fn is_usable(&self) -> Pin<Box<dyn Future<Output = bool> + Send + '_>>;

    /// The last validated Relay `Ready.presence_ttl_s`. A control-plane
    /// implementation without a Ready frame returns `None`, so candidate
    /// caches use their safe 60-second fallback.
    fn ready_presence_ttl(&self) -> Option<Duration> {
        None
    }

    /// 开启一个异步 connectivity attempt，按 `attempt_id` 关联应答（§14/§31）。
    ///
    /// 默认实现：未接线的 mock 返回 NotConnected。
    #[allow(dead_code)] // retained as an adapter for pre-transaction callers
    fn start_connectivity_attempt(
        &self,
        _attempt_id: String,
        _target_device_id: String,
        _initiator_device_id: String,
        _initiator_runtime_epoch: RuntimeEpoch,
        _initiator_revision: u32,
        _initiator_snapshot: Option<DiscoverySnapshot>,
    ) -> Pin<Box<dyn Future<Output = Result<ConnectivityAnswer, RelayError>> + Send + '_>> {
        Box::pin(async move { Err(RelayError::NotConnected) })
    }

    /// Enqueue one authoritative Resolve → ConnectivityOffer transaction and
    /// return its validated Resolve response plus an asynchronous answer
    /// waiter.  The default keeps test-only control-plane mocks disconnected;
    /// production callers can opt into the non-blocking transaction path.
    fn begin_connectivity_attempt(
        &self,
        _attempt_id: String,
        _target_device_id: String,
        _initiator_device_id: String,
        _initiator_runtime_epoch: RuntimeEpoch,
        _initiator_revision: u32,
        _initiator_snapshot: Option<DiscoverySnapshot>,
    ) -> Pin<Box<dyn Future<Output = Result<ConnectivityAttemptStart, RelayError>> + Send + '_>>
    {
        Box::pin(async move { Err(RelayError::NotConnected) })
    }

    /// 请求 Relay 分配数据面 reservation（§25/§31）。默认实现：未接线的 mock 返回
    /// NotConnected。
    fn reserve_relay(
        &self,
        _attempt_id: String,
        _target_device_id: String,
        _desired_lifetime_s: u32,
    ) -> Pin<Box<dyn Future<Output = Result<RelayReserveResponse, RelayError>> + Send + '_>> {
        Box::pin(async move { Err(RelayError::NotConnected) })
    }

    /// 发送一个受限的 WebRTC 信令帧（§17/§22：信令经 Relay Control Plane，fire-and-forget）。
    ///
    /// 默认实现：未接线的 mock 返回 NotConnected。`RelayControlClient` 把它路由到
    /// v2 控制面 `RealtimeSignal` 帧；v1 Relay 数据面路径（deprecated，Step 11 删除）
    /// 是 network-core 内部的回退，不经过本 trait。
    fn signal_webrtc(
        &self,
        _realtime_id: &str,
        _target_device_id: &str,
        _kind: network_relay::v2::RealtimeSignalKind,
        _revision: u64,
        _payload: &[u8],
    ) -> Pin<Box<dyn Future<Output = Result<(), RelayError>> + Send + '_>> {
        Box::pin(async move { Err(RelayError::NotConnected) })
    }

    /// Send a WebRTC signaling frame using its raw Relay V2 wire kind.
    ///
    /// The default keeps legacy/test control-plane implementations compatible
    /// for the frozen enum values.  Forward-compatible Network V2 values must
    /// be implemented by the concrete Relay adapter because the frozen Relay
    /// enum cannot represent them as a typed Rust variant.
    fn signal_webrtc_wire_kind(
        &self,
        realtime_id: &str,
        target_device_id: &str,
        kind: i32,
        revision: u64,
        payload: &[u8],
    ) -> Pin<Box<dyn Future<Output = Result<(), RelayError>> + Send + '_>> {
        match network_relay::v2::RealtimeSignalKind::try_from(kind) {
            Ok(kind) => self.signal_webrtc(realtime_id, target_device_id, kind, revision, payload),
            Err(_) => Box::pin(async {
                Err(RelayError::Protocol(
                    "control plane does not support this forward-compatible signal kind".into(),
                ))
            }),
        }
    }

    /// 该 sink 是否把发布者分配的 request_id 原样带回 ACK。
    ///
    /// `RelayControlClient` 内部自行分配 wire request_id（`next_request_id`），故返回
    /// `false`，发布者只做 epoch/revision 语义校验；忠实 mock 返回 `true`，从而在
    /// 单元测试里验证「错误 request_id 的 ACK 被忽略」。
    fn echoes_request_id(&self) -> bool {
        false
    }
}

impl DiscoveryControlPlane for RelayControlClient {
    fn publish_discovery(
        &self,
        _request_id: u64,
        snapshot: DiscoverySnapshot,
    ) -> Pin<Box<dyn Future<Output = Result<DiscoveryAck, RelayError>> + Send + '_>> {
        // 注意：RelayControlClient::publish_discovery 内部自行分配 wire request_id 并
        // 按 request_id 关联 ACK；传入的 request_id 只是发布者侧的尝试编号。
        Box::pin(async move { RelayControlClient::publish_discovery(self, snapshot).await })
    }

    fn resolve_peer(
        &self,
        target_device_id: &str,
    ) -> Pin<Box<dyn Future<Output = Result<ResolvePeerResponse, RelayError>> + Send + '_>> {
        // 克隆目标 ID，让返回的 future 只借用 `self`（lifetime 与 `&self` 一致），
        // 与 trait 的 elided `'_` 返回寿命匹配。
        let target_device_id = target_device_id.to_string();
        Box::pin(async move { RelayControlClient::resolve_peer(self, &target_device_id).await })
    }

    fn is_usable(&self) -> Pin<Box<dyn Future<Output = bool> + Send + '_>> {
        Box::pin(async move { RelayControlClient::is_usable(self).await })
    }

    fn ready_presence_ttl(&self) -> Option<Duration> {
        RelayControlClient::ready_presence_ttl(self)
    }

    fn start_connectivity_attempt(
        &self,
        attempt_id: String,
        target_device_id: String,
        initiator_device_id: String,
        initiator_runtime_epoch: RuntimeEpoch,
        initiator_revision: u32,
        initiator_snapshot: Option<DiscoverySnapshot>,
    ) -> Pin<Box<dyn Future<Output = Result<ConnectivityAnswer, RelayError>> + Send + '_>> {
        Box::pin(async move {
            RelayControlClient::start_connectivity_attempt(
                self,
                attempt_id,
                target_device_id,
                initiator_device_id,
                initiator_runtime_epoch,
                initiator_revision,
                initiator_snapshot,
            )
            .await
        })
    }

    fn begin_connectivity_attempt(
        &self,
        attempt_id: String,
        target_device_id: String,
        initiator_device_id: String,
        initiator_runtime_epoch: RuntimeEpoch,
        initiator_revision: u32,
        initiator_snapshot: Option<DiscoverySnapshot>,
    ) -> Pin<Box<dyn Future<Output = Result<ConnectivityAttemptStart, RelayError>> + Send + '_>>
    {
        Box::pin(async move {
            RelayControlClient::begin_connectivity_attempt(
                self,
                attempt_id,
                target_device_id,
                initiator_device_id,
                initiator_runtime_epoch,
                initiator_revision,
                initiator_snapshot,
            )
            .await
        })
    }

    fn reserve_relay(
        &self,
        attempt_id: String,
        target_device_id: String,
        desired_lifetime_s: u32,
    ) -> Pin<Box<dyn Future<Output = Result<RelayReserveResponse, RelayError>> + Send + '_>> {
        Box::pin(async move {
            RelayControlClient::reserve_relay(
                self,
                &attempt_id,
                &target_device_id,
                desired_lifetime_s,
            )
            .await
        })
    }

    fn signal_webrtc(
        &self,
        realtime_id: &str,
        target_device_id: &str,
        kind: network_relay::v2::RealtimeSignalKind,
        revision: u64,
        payload: &[u8],
    ) -> Pin<Box<dyn Future<Output = Result<(), RelayError>> + Send + '_>> {
        // 克隆输入，使返回的 future 只借用 `self`（lifetime 与 `&self` 一致）。
        let realtime_id = realtime_id.to_string();
        let target_device_id = target_device_id.to_string();
        let payload = payload.to_vec();
        Box::pin(async move {
            RelayControlClient::signal_webrtc(
                self,
                &realtime_id,
                &target_device_id,
                kind,
                revision,
                &payload,
            )
            .await
        })
    }

    fn signal_webrtc_wire_kind(
        &self,
        realtime_id: &str,
        target_device_id: &str,
        kind: i32,
        revision: u64,
        payload: &[u8],
    ) -> Pin<Box<dyn Future<Output = Result<(), RelayError>> + Send + '_>> {
        let realtime_id = realtime_id.to_string();
        let target_device_id = target_device_id.to_string();
        let payload = payload.to_vec();
        Box::pin(async move {
            RelayControlClient::signal_webrtc_wire_kind(
                self,
                &realtime_id,
                &target_device_id,
                kind,
                revision,
                &payload,
            )
            .await
        })
    }
}

/// 一次 `publish()` 的终态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PublishOutcome {
    /// 收到匹配 ACK，已进入 `Published`。
    Published,
    /// 超过有限重试上限，已进入 `Degraded`。
    Degraded,
    /// 控制面不可用，未完成发布（重连后重新触发）。
    Unavailable,
}

/// 可靠 Discovery 发布器。
#[derive(Clone)]
pub(crate) struct DiscoveryPublisher {
    sink: Arc<dyn DiscoveryControlPlane>,
    /// 发布者侧 request_id 计数器（每次发布独立）；用 Arc 使克隆共享同一序列。
    next_request_id: Arc<AtomicU64>,
    /// 退避调度；`backoff[i]` 是第 i+1 次重试前的等待。
    backoff: Vec<Duration>,
    /// 总尝试次数上限（含首次）。
    max_attempts: usize,
    /// 单次发布的应答等待上限。
    publish_timeout: Duration,
}

impl DiscoveryPublisher {
    /// 用集中常量构造发布器。
    pub(crate) fn new(sink: Arc<dyn DiscoveryControlPlane>) -> Self {
        Self {
            sink,
            next_request_id: Arc::new(AtomicU64::new(1)),
            backoff: DISCOVERY_PUBLISH_RETRY_BACKOFF_MS
                .iter()
                .map(|ms| Duration::from_millis(*ms))
                .collect(),
            max_attempts: DISCOVERY_PUBLISH_MAX_ATTEMPTS,
            publish_timeout: DISCOVERY_PUBLISH_TIMEOUT,
        }
    }

    /// 注入式构造（测试用：小退避 / 大尝试数以加速或验证完整调度）。
    #[cfg(test)]
    pub(crate) fn with_config(
        sink: Arc<dyn DiscoveryControlPlane>,
        backoff: Vec<Duration>,
        max_attempts: usize,
        publish_timeout: Duration,
    ) -> Self {
        Self {
            sink,
            next_request_id: Arc::new(AtomicU64::new(1)),
            backoff,
            max_attempts,
            publish_timeout,
        }
    }

    /// 触发一次可靠发布：发送 → 等 ACK → 成功 `Published`；失败按 bounded backoff
    /// 重试，超过上限 `Degraded`；控制面不可用 `Unavailable`（重连后重新触发）。
    pub(crate) async fn publish(
        &self,
        manager: &LocalDiscoveryManager,
        reason: &str,
    ) -> PublishOutcome {
        manager.mark_publishing();
        let snapshot = manager.snapshot();
        let mut attempt: usize = 0;
        loop {
            // §9：连接断开时不白等有限重试；由 on_control_connected 在重连后重发。
            if !self.sink.is_usable().await {
                tracing::debug!(reason, "discovery publish aborted: control plane unusable");
                manager.mark_degraded();
                return PublishOutcome::Unavailable;
            }
            let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
            let attempt_result = tokio::time::timeout(
                self.publish_timeout,
                self.sink.publish_discovery(request_id, snapshot.clone()),
            )
            .await;
            let published = match attempt_result {
                Ok(Ok(ack)) if self.ack_is_valid(request_id, &snapshot, &ack) => {
                    tracing::debug!(
                        reason,
                        request_id,
                        revision = snapshot.revision,
                        "discovery published"
                    );
                    true
                }
                Ok(Ok(_)) => {
                    // 匹配的 request_id 但 epoch/revision 不匹配（旧/串线 ACK）视为失败。
                    tracing::warn!(
                        reason,
                        request_id,
                        "discovery ACK did not match published snapshot"
                    );
                    false
                }
                Ok(Err(error)) => {
                    tracing::debug!(reason, %error, "discovery publish attempt failed");
                    false
                }
                Err(_) => {
                    tracing::debug!(reason, "discovery publish attempt timed out (ack lost)");
                    false
                }
            };
            if published {
                manager.mark_published();
                return PublishOutcome::Published;
            }
            attempt += 1;
            if attempt >= self.max_attempts {
                tracing::warn!(
                    reason,
                    attempts = attempt,
                    "discovery publish exceeded max attempts; DEGRADED"
                );
                manager.mark_degraded();
                return PublishOutcome::Degraded;
            }
            let backoff = self.backoff_for(attempt);
            tracing::debug!(
                reason,
                attempt,
                ?backoff,
                "discovery publish retry scheduled"
            );
            tokio::time::sleep(backoff).await;
        }
    }

    /// 在受监督的后台任务里启动发布重试循环；控制面断开时
    /// [`Self::publish`] 内部会以 `Unavailable` 退出（cancel on disconnect）。
    #[allow(dead_code)] // forward path：Step 6 触发网络变化/手动重发时使用
    pub(crate) fn start_retry_loop(
        &self,
        state: &Arc<RuntimeState>,
        manager: Arc<LocalDiscoveryManager>,
        reason: &'static str,
    ) -> Option<TaskId> {
        let publisher = Arc::new(self.clone());
        state
            .task_supervisor
            .spawn_runtime("discovery-publish", async move {
                let outcome = publisher.publish(&manager, reason).await;
                tracing::debug!(?outcome, reason, "discovery publish retry loop exited");
            })
    }

    /// ACK 是否与本次发布匹配：epoch/revision 必须一致；忠实 sink 还要求 request_id 一致。
    fn ack_is_valid(
        &self,
        request_id: u64,
        snapshot: &DiscoverySnapshot,
        ack: &DiscoveryAck,
    ) -> bool {
        if snapshot.runtime_epoch.as_ref() != ack.runtime_epoch.as_ref()
            || snapshot.revision != ack.revision
        {
            return false;
        }
        if self.sink.echoes_request_id() && ack.request_id != request_id {
            return false;
        }
        true
    }

    /// 第 `retry_index`（1-based）次重试前的等待；超过调度长度时取最后一个（有界上限）。
    fn backoff_for(&self, retry_index: usize) -> Duration {
        self.backoff
            .get(retry_index.saturating_sub(1))
            .copied()
            .unwrap_or_else(|| self.backoff.last().copied().unwrap_or(Duration::ZERO))
    }
}

#[cfg(test)]
#[path = "../tests/discovery/publisher.rs"]
mod tests;
