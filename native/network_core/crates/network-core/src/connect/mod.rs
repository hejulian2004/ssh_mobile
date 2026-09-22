//! transport-network v2：连接编排（设计 §11/§34/§37/§40）。
//!
//! 本模块是连接的唯一入口，实现固定状态机：
//!
//! ```text
//! IDLE → RESOLVING → RESOLVED → COORDINATING → DIRECT_CONNECTING
//!   ├──────────────────────────────→ CONNECTED_DIRECT
//!   ↓
//! DIRECT_FAILED → RELAY_RESERVING → RELAY_CONNECTING → CONNECTED_RELAY
//! ```
//!
//! 不存在 `RECONNECTING` / `DIRECT_UPGRADING` / `PATH_REPAIRING` 长期状态（§11）。
//!
//! - [`connectivity_attempt::ConnectivityAttemptCoordinator`]：唯一建连入口（§11/§37）。
//! - [`ready_index::ReadySessionIndex`]：仅保存 Resolve epoch/capability/session
//!   摘要；它不拥有 Connection，也不是真实 connectivity truth。
//! - [`presence::PresenceHintCache`]：UI-only 的 Presence 提示缓存（§23），绝不影响
//!   ConnectivityAttempt / CandidateSet / ConnectionSession。
//!
//! Relay 控制面（resolve / publish / signaling / reserve）经
//! [`crate::discovery::DiscoveryControlPlane`]（`RelayControlClient` v2 protobuf wire）
//! 路由；Relay 数据面使用 `RelayDataClient` reservation 模型，PairReady 由
//! RelayData 生命周期控制，PathHandshakeV2 元数据与 admission 则折叠在既有
//! Noise 握手内完成。

pub(crate) mod connectivity_attempt;
#[allow(dead_code)]
pub(crate) mod path;
#[allow(dead_code)]
pub(crate) mod peer_supervisor;
pub(crate) mod presence;
pub(crate) mod ready_index;

pub(crate) use connectivity_attempt::ConnectivityAttemptCoordinator;
#[allow(unused_imports)]
pub(crate) use path::{
    callback_path_carrier, ActiveRoute, DirectProbe, GenericRouteScope, PathHandle, PathKind,
    PathLease, PathProjection, PathRegistry, PathSelection, PeerPathManager, StreamCarrier,
};
#[allow(unused_imports)]
pub(crate) use peer_supervisor::{
    IntentGeneration, PeerConnectIntent, PeerId, PeerIntent, PeerState, PeerSupervisor,
    PeerSupervisorRegistry,
};

// ---------------------------------------------------------------------------
// 集中常量（设计 §39：TTL / timeout / connect window 必须集中定义，禁止散落 magic number）
// ---------------------------------------------------------------------------

use network_protocol::CommunicationClass;
use std::time::Duration;

/// Whole connect operation budget. Every child stage must be bounded by this
/// deadline; a sequence of individually bounded stages must not extend the
/// public operation indefinitely.
pub(crate) const OVERALL_CONNECT_BUDGET: Duration = Duration::from_secs(20);

/// Direct First 固定直连窗口（§15：`Direct connect window = 4s`）。
pub(crate) const DIRECT_CONNECT_WINDOW: Duration = Duration::from_secs(4);

/// Stage A uses only configured/fresh cached direct candidates.
pub(crate) const STAGE_A_CONNECT_BUDGET: Duration = DIRECT_CONNECT_WINDOW;

/// Resolve（服务器权威解析）的应答等待上限（§10/§33 ResolveTimeout）。
#[allow(dead_code)] // retained by the legacy resolver unit-test seam
pub(crate) const RESOLVE_TIMEOUT: Duration = Duration::from_secs(3);

/// A NOT_READY peer gets one bounded retry wait before returning PeerNotReady.
pub(crate) const NOT_READY_WAIT: Duration = Duration::from_secs(2);

/// ReserveRelay 的应答等待上限（§25/§33 RelayReservationFailed）。
pub(crate) const RELAY_RESERVE_TIMEOUT: Duration = Duration::from_secs(3);

/// Idle retirement for a non-maintained path with no borrower or business work.
pub(crate) const EPHEMERAL_PATH_IDLE_TIMEOUT: Duration = Duration::from_secs(60);

/// Frozen peer admission limits. The runtime ResourceLimiter remains the
/// cross-domain enforcement point; these values are the connectivity policy
/// used by peer-owned admission/eviction tests.
#[allow(dead_code)]
pub(crate) const MAX_ACTIVE_PEERS: usize = 64;
pub(crate) const MAX_CONFIGURED_PEERS: usize = 256;

/// RelayReserveRequest 期望的数据面 reservation 生命周期（§25）。
pub(crate) const RELAY_RESERVATION_LIFETIME_S: u32 = 60;

/// 连接能力位（§17/§34 capability）。注册表按位覆盖判定：registered 覆盖 requested
/// 当且仅当 `(registered & requested) == requested`。
pub(crate) const CAPABILITY_RELIABLE_MESSAGE: u8 = 1;
pub(crate) const CAPABILITY_RELIABLE_STREAM: u8 = 2;
pub(crate) const CAPABILITY_UNRELIABLE_DATAGRAM: u8 = 4;

/// 默认连接能力（§17）：QUIC 基线同时携带 ReliableMessage 与 ReliableStream。
pub(crate) const DEFAULT_CONNECTION_CAPABILITY: u8 =
    CAPABILITY_RELIABLE_MESSAGE | CAPABILITY_RELIABLE_STREAM;

/// 把 CommunicationClass 映射为注册表能力位（§17 映射表）。
/// RealtimeMedia 不经过普通 ConnectionSession 建连（走 WebRTC 信令），这里映射到
/// 默认连接能力作为安全基线。
pub(crate) fn communication_class_capability(class: CommunicationClass) -> u8 {
    match class {
        CommunicationClass::ReliableStream | CommunicationClass::BulkTransfer => {
            CAPABILITY_RELIABLE_STREAM
        }
        CommunicationClass::ReliableMessage => CAPABILITY_RELIABLE_MESSAGE,
        CommunicationClass::UnreliableDatagram => CAPABILITY_UNRELIABLE_DATAGRAM,
        CommunicationClass::RealtimeMedia => DEFAULT_CONNECTION_CAPABILITY,
        CommunicationClass::Unspecified => DEFAULT_CONNECTION_CAPABILITY,
    }
}

/// 默认 CommunicationClass：Unspecified / 旧调用方按 ReliableMessage（§17）。
pub(crate) fn default_communication_class(class: CommunicationClass) -> CommunicationClass {
    match class {
        CommunicationClass::Unspecified => CommunicationClass::ReliableMessage,
        other => other,
    }
}

/// 从已建立的 route profile 推导注册表能力位（§34）：注册表记录连接**实际**能
/// 承载什么，因此 QUIC/TCP 基线连接可被后续 ReliableStream 请求复用。
pub(crate) fn profile_satisfies(
    profile: crate::connection::ConnectionProfile,
    required_capabilities: u8,
) -> bool {
    profile_capability_mask(profile) & required_capabilities == required_capabilities
}

pub(crate) fn profile_capability_mask(profile: crate::connection::ConnectionProfile) -> u8 {
    use crate::connection::ConnectionCapability as Cap;
    let mut mask = 0;
    if profile.supports(Cap::ReliableMessage) {
        mask |= CAPABILITY_RELIABLE_MESSAGE;
    }
    if profile.supports(Cap::ReliableStream) {
        mask |= CAPABILITY_RELIABLE_STREAM;
    }
    if profile.supports(Cap::UnreliableDatagram) {
        mask |= CAPABILITY_UNRELIABLE_DATAGRAM;
    }
    mask
}

#[cfg(test)]
#[path = "../tests/connect/mod.rs"]
mod tests;
