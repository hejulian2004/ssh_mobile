part of 'native_realtime_protocol.dart';

/// Native peer lifecycle values mirrored from the frozen V2 wire.
enum NativePeerConnectionState {
  unspecified(0),
  connecting(1),
  connected(2),
  disconnected(3),
  failed(4);

  const NativePeerConnectionState(this.wireValue);

  final int wireValue;

  static NativePeerConnectionState fromWire(int value) =>
      NativePeerConnectionState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => NativePeerConnectionState.unspecified,
      );
}

/// Business lifecycle exposed by Network Protocol V2. This is intentionally
/// independent from carrier/session states.
enum NativePeerState {
  offline(0),
  connecting(1),
  online(2);

  const NativePeerState(this.wireValue);

  final int wireValue;

  static NativePeerState fromWire(int value) => NativePeerState.values
      .firstWhere((state) => state.wireValue == value, orElse: () => offline);
}

enum NativeE2eePolicy {
  required(0),
  disabled(1);

  const NativeE2eePolicy(this.wireValue);

  final int wireValue;
}

/// Native route metadata is kept as abstract enums; endpoint/socket values are
/// intentionally not part of the public typed event.
enum NativeRouteType {
  unspecified(0),
  quicDirect(1),
  relay(2),
  lan(4);

  const NativeRouteType(this.wireValue);

  final int wireValue;

  static NativeRouteType fromWire(int value) =>
      NativeRouteType.values.firstWhere(
        (route) => route.wireValue == value,
        orElse: () => NativeRouteType.unspecified,
      );
}

enum NativeRouteTopology {
  unspecified(0),
  direct(1),
  relay(2);

  const NativeRouteTopology(this.wireValue);

  final int wireValue;

  static NativeRouteTopology fromWire(int value) =>
      NativeRouteTopology.values.firstWhere(
        (topology) => topology.wireValue == value,
        orElse: () => NativeRouteTopology.unspecified,
      );
}

enum NativeRouteTransport {
  unspecified(0),
  quic(1),
  tcp(2),
  udp(3),
  webSocket(4);

  const NativeRouteTransport(this.wireValue);

  final int wireValue;

  static NativeRouteTransport fromWire(int value) =>
      NativeRouteTransport.values.firstWhere(
        (transport) => transport.wireValue == value,
        orElse: () => NativeRouteTransport.unspecified,
      );
}

/// Causal phase of one native direct/Relay route attempt.
enum NativeRouteAttemptPhase {
  unspecified(0),
  directFailed(1),
  relayFallbackStarted(2),
  relayConnected(3),
  relayFailed(4);

  const NativeRouteAttemptPhase(this.wireValue);

  final int wireValue;

  static NativeRouteAttemptPhase fromWire(int value) =>
      NativeRouteAttemptPhase.values.firstWhere(
        (phase) => phase.wireValue == value,
        orElse: () => NativeRouteAttemptPhase.unspecified,
      );
}

enum NativeRelayConnectionState {
  unspecified(0),
  connecting(1),
  connected(2),
  disconnected(3),
  failed(4);

  const NativeRelayConnectionState(this.wireValue);

  final int wireValue;

  static NativeRelayConnectionState fromWire(int value) =>
      NativeRelayConnectionState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => NativeRelayConnectionState.unspecified,
      );
}

const _maxPendingCommandResults = 64;

/// Native WebRTC Realtime session lifecycle states.
enum NativeRealtimeSessionState {
  unspecified(0),
  negotiating(1),
  connected(2),
  restarting(3),
  closed(4),
  failed(5);

  const NativeRealtimeSessionState(this.wireValue);

  /// Protobuf enumeration value used by Rust.
  final int wireValue;

  /// Converts an unknown wire value to [unspecified].
  static NativeRealtimeSessionState fromWire(int value) =>
      NativeRealtimeSessionState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => NativeRealtimeSessionState.unspecified,
      );
}

/// Native WebRTC signaling kinds.
enum NativeRealtimeSignalKind {
  unspecified(0),
  webRtcOffer(1),
  webRtcAnswer(2),
  iceCandidate(3),
  iceRestart(4),
  webRtcClose(5),
  screenShareConsent(6);

  const NativeRealtimeSignalKind(this.wireValue);

  /// Protobuf enumeration value used by Rust.
  final int wireValue;

  /// Converts an unknown wire value to [unspecified].
  static NativeRealtimeSignalKind fromWire(int value) =>
      NativeRealtimeSignalKind.values.firstWhere(
        (kind) => kind.wireValue == value,
        orElse: () => NativeRealtimeSignalKind.unspecified,
      );
}

enum NativeScreenShareConsentDecision {
  unspecified(0),
  request(1),
  accept(2),
  reject(3),
  cancel(4);

  const NativeScreenShareConsentDecision(this.wireValue);

  final int wireValue;

  static NativeScreenShareConsentDecision fromWire(int value) =>
      NativeScreenShareConsentDecision.values.firstWhere(
        (decision) => decision.wireValue == value,
        orElse: () => NativeScreenShareConsentDecision.unspecified,
      );
}

enum NativeScreenShareConsentPurpose {
  unspecified(0),
  screenShare(1);

  const NativeScreenShareConsentPurpose(this.wireValue);

  final int wireValue;

  static NativeScreenShareConsentPurpose fromWire(int value) =>
      NativeScreenShareConsentPurpose.values.firstWhere(
        (purpose) => purpose.wireValue == value,
        orElse: () => NativeScreenShareConsentPurpose.unspecified,
      );
}

enum NativeScreenShareMediaKind {
  unspecified(0),
  screenVideo(1);

  const NativeScreenShareMediaKind(this.wireValue);

  final int wireValue;

  static NativeScreenShareMediaKind fromWire(int value) =>
      NativeScreenShareMediaKind.values.firstWhere(
        (media) => media.wireValue == value,
        orElse: () => NativeScreenShareMediaKind.unspecified,
      );
}

/// Native `RetryDisposition` wire values mirrored from Rust.
enum NativeRetryDisposition {
  unspecified(0),
  noRetry(1),
  retryWithBackoff(2),
  retryAfter(3),
  refreshCredentialThenRetry(4);

  const NativeRetryDisposition(this.wireValue);

  /// Protobuf enumeration value used by Rust.
  final int wireValue;

  /// Converts an unknown wire value to [unspecified].
  static NativeRetryDisposition fromWire(int value) =>
      NativeRetryDisposition.values.firstWhere(
        (disposition) => disposition.wireValue == value,
        orElse: () => NativeRetryDisposition.unspecified,
      );
}
