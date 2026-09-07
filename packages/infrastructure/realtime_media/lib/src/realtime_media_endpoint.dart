import 'realtime_media_state.dart';
import 'remote_video_surface.dart';
import 'screen_capture_source.dart';

/// Direction of one opaque native media endpoint.
enum RealtimeMediaDirection { send, receive }

/// Stable Dart-side value for a native endpoint lease, never a native address.
final class RealtimeMediaEndpointId {
  RealtimeMediaEndpointId(String value) : value = _validateEndpointId(value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is RealtimeMediaEndpointId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// Immutable binding that prevents a lease from crossing session generations.
final class RealtimeMediaEndpointIdentity {
  RealtimeMediaEndpointIdentity({
    required String realtimeId,
    required String peerId,
    required this.generation,
    required this.direction,
  }) : realtimeId = _validateIdentity(realtimeId, 'realtime ID'),
       peerId = _validateIdentity(peerId, 'peer ID') {
    if (generation <= 0) {
      throw ArgumentError.value(generation, 'generation', 'must be positive');
    }
  }

  final String realtimeId;
  final String peerId;
  final int generation;
  final RealtimeMediaDirection direction;

  bool matches(RealtimeMediaEndpointIdentity other) =>
      realtimeId == other.realtimeId &&
      peerId == other.peerId &&
      generation == other.generation &&
      direction == other.direction;
}

/// Borrowed endpoint lease owned by a [RealtimeMediaSessionController].
final class RealtimeMediaEndpoint {
  /// Constructs a lease record for a platform bridge. App code should acquire
  /// leases through [RealtimeMediaSessionController.start]; a foreign record is
  /// rejected by the controller's identity guard.
  RealtimeMediaEndpoint.lease({required this.id, required this.identity});

  final RealtimeMediaEndpointId id;
  final RealtimeMediaEndpointIdentity identity;
  RealtimeMediaEndpointState state = RealtimeMediaEndpointState.ready;
  ScreenCaptureSource? source;
  RemoteVideoSurface? surface;

  bool get isAttached => source != null || surface != null;
}

String _validateEndpointId(String value) =>
    _validateIdentity(value, 'endpoint ID');

String _validateIdentity(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw ArgumentError.value(value, name, 'must contain 1 to 128 characters');
  }
  return normalized;
}
