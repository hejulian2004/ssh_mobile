import 'package:realtime_media/realtime_media.dart';
import 'package:test/test.dart';

void main() {
  test('hardware is the default and CPU is part of the immutable binding', () {
    final hardware = RealtimeMediaEndpointIdentity(
      realtimeId: 'fixture-session',
      peerId: 'fixture-peer',
      generation: 1,
      direction: RealtimeMediaDirection.send,
    );
    final cpu = RealtimeMediaEndpointIdentity(
      realtimeId: 'fixture-session',
      peerId: 'fixture-peer',
      generation: 1,
      direction: RealtimeMediaDirection.send,
      codecMode: RealtimeMediaCodecMode.cpu,
    );
    expect(hardware.codecMode, RealtimeMediaCodecMode.hardware);
    expect(cpu.matches(hardware), isFalse);
    expect(hardware.matches(cpu), isFalse);
  });

  test(
    'CPU mode reaches the platform and cannot be swapped on a lease',
    () async {
      final backend = _Backend();
      final controller = RealtimeMediaSessionController(
        backend: backend,
        realtimeId: 'fixture-session',
        peerId: 'fixture-peer',
        generation: 1,
        codecMode: RealtimeMediaCodecMode.cpu,
      );
      final endpoint = await controller.start(RealtimeMediaDirection.receive);
      expect(backend.binding?.codecMode, RealtimeMediaCodecMode.cpu);
      final foreign = RealtimeMediaEndpoint.lease(
        id: endpoint.id,
        identity: RealtimeMediaEndpointIdentity(
          realtimeId: 'fixture-session',
          peerId: 'fixture-peer',
          generation: 1,
          direction: RealtimeMediaDirection.receive,
        ),
      );
      await expectLater(
        controller.attachRemoteVideoSurface(foreign),
        throwsA(isA<RealtimeMediaException>()),
      );
      await controller.stop();
    },
  );
}

final class _Backend implements RealtimeMediaBackend {
  RealtimeMediaEndpointIdentity? binding;
  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity identity,
  ) async {
    binding = identity;
    return RealtimeMediaEndpointId('fixture-endpoint');
  }

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async => RemoteVideoSurface(
    id: RemoteVideoSurfaceId('fixture-surface'),
    endpointId: endpointId,
    identity: identity,
  );
  @override
  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  }) async {}
  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {}
  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {}
  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async => RealtimeMediaStats();
}
