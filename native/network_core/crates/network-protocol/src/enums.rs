//! Stable Network Protocol V2 enum values.

use prost::Enumeration;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum NetworkErrorCode {
    Unspecified = 0,
    InvalidArgument = 1,
    AuthenticationFailed = 2,
    NoRoute = 3,
    Timeout = 4,
    PeerOffline = 5,
    QuicError = 6,
    NatError = 7,
    RelayError = 8,
    IoError = 10,
    Cancelled = 11,
    CredentialExpired = 12,
    IdentityConflict = 13,
    Configuration = 14,
    SecurityPolicyMismatch = 15,
    RelayRequiresE2ee = 16,
    PeerNotReady = 17,
    ResourceLimit = 18,
    Lifecycle = 19,
    ProtocolMismatch = 20,
    StaleOperation = 21,
    InvalidState = 22,
    PathLost = 23,
    ResumeRejected = 24,
    StreamClosed = 25,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RetryDisposition {
    Unspecified = 0,
    NoRetry = 1,
    RetryWithBackoff = 2,
    RetryAfter = 3,
    RefreshCredentialThenRetry = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum PeerConnectionState {
    Unspecified = 0,
    Connecting = 1,
    Connected = 2,
    Disconnected = 3,
    Failed = 4,
}

/// Stable, business-level peer lifecycle. Transport/session states are not
/// part of this public truth.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum PeerState {
    Offline = 0,
    Connecting = 1,
    Online = 2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum E2eePolicy {
    Required = 0,
    Disabled = 1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum CommandResultState {
    Succeeded = 0,
    Failed = 1,
    Cancelled = 2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum NetworkEventLane {
    Control = 0,
    Data = 1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RouteType {
    Unspecified = 0,
    QuicDirect = 1,
    Relay = 2,
    Lan = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RouteTopology {
    Unspecified = 0,
    Direct = 1,
    Relay = 2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RouteTransport {
    Unspecified = 0,
    Quic = 1,
    Tcp = 2,
    Udp = 3,
    WebSocket = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RouteAttemptPhase {
    Unspecified = 0,
    DirectFailed = 1,
    RelayFallbackStarted = 2,
    RelayConnected = 3,
    RelayFailed = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RealtimeSessionState {
    Unspecified = 0,
    Negotiating = 1,
    Connected = 2,
    Restarting = 3,
    Closed = 4,
    Failed = 5,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RealtimeSignalKind {
    Unspecified = 0,
    WebRtcOffer = 1,
    WebRtcAnswer = 2,
    IceCandidate = 3,
    IceRestart = 4,
    WebRtcClose = 5,
    ScreenShareConsent = 6,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum ScreenShareConsentDecision {
    Unspecified = 0,
    Request = 1,
    Accept = 2,
    Reject = 3,
    Cancel = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum ScreenShareConsentPurpose {
    Unspecified = 0,
    ScreenShare = 1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum ScreenShareMediaKind {
    Unspecified = 0,
    ScreenVideo = 1,
}

/// 应用消息进入 Delivery Manager 后采用的可靠性策略。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum DeliveryPolicyCode {
    BestEffort = 0,
    LatestState = 1,
    Acked = 2,
    AckedDeduplicated = 3,
    SessionBoundOrdered = 4,
    ResumableTransfer = 5,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RelayConnectionState {
    Unspecified = 0,
    Connecting = 1,
    Connected = 2,
    Disconnected = 3,
    Failed = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum CommunicationClass {
    Unspecified = 0,
    ReliableStream = 1,
    ReliableMessage = 2,
    BulkTransfer = 3,
    UnreliableDatagram = 4,
    RealtimeMedia = 5,
}
