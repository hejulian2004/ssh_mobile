/// Lifecycle state for one logical media session.
enum RealtimeMediaSessionState {
  idle,
  starting,
  ready,
  stopping,
  failed,
  released,
}

/// Lifecycle state for a borrowed opaque endpoint lease.
enum RealtimeMediaEndpointState { ready, attached, detached, failed, released }
