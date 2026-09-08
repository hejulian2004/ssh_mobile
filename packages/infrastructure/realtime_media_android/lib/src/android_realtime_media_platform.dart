import 'package:realtime_media/realtime_media.dart';

/// Android owner for MediaProjection, hardware codecs, and SurfaceTexture.
///
/// The interface intentionally contains no frame or native-pointer method.
/// Implementations return only bounded metadata, lifecycle results, opaque
/// surface IDs, and low-frequency statistics.
abstract interface class AndroidRealtimeMediaPlatform {
  Future<void> requestProjection();

  Future<List<ScreenCaptureSource>> listCaptureSources();

  Future<void> startCapture({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
    RealtimeMediaNativeOwnerToken? ownerToken,
  });

  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  });

  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  });

  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  });

  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  });

  /// Requests a keyframe through the generation-bound native owner.
  Future<void> requestKeyframe({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  });

  /// Resets the native decoder and discards stale receive-side state.
  Future<void> resetDecoder({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  });
}
