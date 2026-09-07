import 'package:realtime_media/realtime_media.dart';

/// Windows owner for capture, codec, decoder, and texture resources.
///
/// Only lifecycle metadata crosses this boundary. Encoded/decoded media,
/// native pointers, and pixel buffers are deliberately absent from every
/// method signature.
abstract interface class WindowsRealtimeMediaPlatform {
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
}
