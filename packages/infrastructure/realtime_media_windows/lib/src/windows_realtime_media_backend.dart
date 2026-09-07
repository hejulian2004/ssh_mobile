import 'package:realtime_media/realtime_media.dart';

import 'windows_realtime_media_platform.dart';

/// Composes the NetworkRuntime endpoint lease with the Windows media owner.
///
/// Endpoint creation/release remains delegated to the existing native bridge.
/// Windows owns only capture, codec, decoder, surface, and texture resources;
/// therefore release first tears down the platform resource and only then
/// finalizes the endpoint lease.
final class WindowsRealtimeMediaBackend implements RealtimeMediaBackend {
  const WindowsRealtimeMediaBackend({
    required this.endpointBackend,
    required this.platform,
  });

  final RealtimeMediaBackend endpointBackend;
  final WindowsRealtimeMediaPlatform platform;

  Future<List<ScreenCaptureSource>> listCaptureSources() =>
      platform.listCaptureSources();

  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity identity,
  ) => endpointBackend.start(identity);

  @override
  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  }) => platform.startCapture(
    endpointId: endpointId,
    identity: identity,
    source: source,
  );

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => platform.attachRemoteVideoSurface(
    endpointId: endpointId,
    identity: identity,
  );

  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    await platform.detach(endpointId: endpointId, identity: identity);
    await endpointBackend.detach(endpointId: endpointId, identity: identity);
  }

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    await platform.release(endpointId: endpointId, identity: identity);
    await endpointBackend.release(endpointId: endpointId, identity: identity);
  }

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => platform.readStats(endpointId: endpointId, identity: identity);
}
