part of 'realtime.dart';

/// High-level Realtime session state exposed to Flutter features.
///
/// WebRTC negotiation is native-owned. A feature observes this state instead
/// of driving a peer connection, SDP, ICE, or a socket itself.
enum RealtimeSessionState {
  idle,
  starting,
  negotiating,
  connected,
  restarting,
  stopped,
  failed,
}

/// High-level remote audio state.
enum RealtimeAudioState { unavailable, inactive, active, muted, failed }

/// Events emitted by an App/native adapter into [RealtimeClient].
sealed class RealtimeBackendEvent {
  const RealtimeBackendEvent();
}

/// A backend state event consumed by the SDK session coordinator.
final class RealtimeSessionStateChangedEvent extends RealtimeBackendEvent {
  const RealtimeSessionStateChangedEvent({
    required this.realtimeId,
    required this.peerId,
    required this.state,
    this.error,
    this.revision = 0,
    this.generation,
  });

  final String realtimeId;
  final String peerId;
  final RealtimeSessionState state;
  final NetworkError? error;

  /// Signaling revision associated with this state; 0 when unspecified.
  final int revision;

  /// Native-authoritative media/session generation. Synthetic backends may
  /// omit it, but a production native adapter must always provide it; it must
  /// never be derived from [revision].
  final int? generation;
}

/// A complete Realtime session state snapshot published by native.
final class RealtimeSnapshot {
  const RealtimeSnapshot({
    required this.realtimeId,
    required this.peerId,
    required this.state,
    required this.revision,
    this.error,
    this.generation,
  });

  final String realtimeId;
  final String peerId;
  final RealtimeSessionState state;
  final int revision;
  final NetworkError? error;

  /// Native-authoritative media/session generation, independent of signaling
  /// revision. A production native snapshot always carries this value.
  final int? generation;
}

/// Immutable token required to bind a media endpoint to one native session.
///
/// The token is created only from a native-authoritative generation carried by
/// a state/snapshot event. Signaling revisions are intentionally absent.
final class RealtimeSessionToken {
  const RealtimeSessionToken({
    required this.realtimeId,
    required this.peerId,
    required this.generation,
  });

  final String realtimeId;
  final String peerId;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is RealtimeSessionToken &&
      other.realtimeId == realtimeId &&
      other.peerId == peerId &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(realtimeId, peerId, generation);
}

/// A backend snapshot event consumed by the SDK session coordinator.
final class RealtimeSnapshotBackendEvent extends RealtimeBackendEvent {
  const RealtimeSnapshotBackendEvent(this.snapshot);

  final RealtimeSnapshot snapshot;
}

/// A typed screen-share consent event emitted by the native control adapter.
final class RealtimeConsentBackendEvent extends RealtimeBackendEvent {
  const RealtimeConsentBackendEvent(this.consent);

  final RealtimeConsent consent;
}

/// Optional capability implemented by a native Realtime backend that can
/// transport typed screen-share consent over authenticated control signaling.
/// Keeping this separate preserves compatibility with synthetic/fake backends
/// that only exercise session lifecycle behavior.
abstract interface class RealtimeConsentBackend {
  Future<SdkResult<void>> sendConsent({
    required String peerId,
    required RealtimeConsent consent,
  });
}

/// A backend audio state event consumed by the SDK session coordinator.
final class RealtimeAudioStateChangedEvent extends RealtimeBackendEvent {
  const RealtimeAudioStateChangedEvent({
    required this.realtimeId,
    required this.peerId,
    required this.state,
  });

  final String realtimeId;
  final String peerId;
  final RealtimeAudioState state;
}

/// The native/runtime-facing backend for the high-level SDK client.
abstract interface class RealtimeSessionBackend {
  Stream<RealtimeBackendEvent> get events;

  Future<SdkResult<void>> start({
    required String realtimeId,
    required String peerId,
  });

  Future<SdkResult<void>> stop({required String realtimeId});

  /// Releases backend subscriptions without taking ownership of App Scope
  /// native resources.
  Future<void> dispose() async {}
}

/// A feature-facing Realtime session.
///
/// PeerConnection, ICE, SDP, signaling, and sockets are deliberately absent.
abstract interface class RealtimeSession {
  String get realtimeId;

  String get peerId;

  RealtimeSessionState get state;

  /// Latest signaling revision observed from state/snapshot backend events.
  int get revision;

  /// Native-authoritative generation for the current session, when the
  /// adapter has delivered its first state/snapshot event.
  int? get generation;

  /// Token used by the media adapter; null until native reports a generation.
  RealtimeSessionToken? get mediaToken;

  RealtimeAudioState get audioState;

  /// Low-frequency typed consent events for this session. The stream carries
  /// metadata only and is generation-filtered by the SDK coordinator.
  Stream<RealtimeConsent> get consentEvents;

  /// Sends a typed request/decision through the authenticated native control
  /// route. It never starts capture or touches WebRTC resources directly.
  Future<SdkResult<void>> sendConsent(RealtimeConsent consent);

  Future<SdkResult<void>> start();

  Future<SdkResult<void>> stop();
}

/// Factory and lifecycle owner for feature-facing Realtime sessions.
abstract interface class RealtimeClient {
  RealtimeSession createSession({
    required String realtimeId,
    required String peerId,
  });

  Future<void> dispose();
}
