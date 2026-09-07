import 'realtime_media_endpoint.dart';

/// Opaque renderer-owned identity for a remote display surface.
final class RemoteVideoSurfaceId {
  RemoteVideoSurfaceId(String value) : value = _validateSurfaceId(value);

  final String value;
}

/// Observable state for an opaque native-renderer surface.
enum RemoteVideoSurfaceState { pending, ready, released, failed }

/// Renderer capability returned by a platform adapter.
///
/// It intentionally has no image-buffer, renderer-address, or texture API.
final class RemoteVideoSurface {
  RemoteVideoSurface({
    required this.id,
    required this.endpointId,
    required this.identity,
    this.state = RemoteVideoSurfaceState.ready,
  });

  final RemoteVideoSurfaceId id;
  final RealtimeMediaEndpointId endpointId;
  final RealtimeMediaEndpointIdentity identity;
  RemoteVideoSurfaceState state;

  void release() {
    state = RemoteVideoSurfaceState.released;
  }
}

String _validateSurfaceId(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw ArgumentError.value(
      value,
      'surface ID',
      'must contain 1 to 128 characters',
    );
  }
  return normalized;
}
