import 'package:realtime_media/realtime_media.dart';
import 'package:test/test.dart';

import 'package:realtime_media_windows/src/windows_realtime_media_backend.dart';
import 'package:realtime_media_windows/src/windows_realtime_media_platform.dart';

void main() {
  late RecordingEndpointBackend endpointBackend;
  late RecordingWindowsPlatform platform;
  late WindowsRealtimeMediaBackend backend;

  final identity = RealtimeMediaEndpointIdentity(
    realtimeId: 'realtime-1',
    peerId: 'peer-a',
    generation: 7,
    direction: RealtimeMediaDirection.send,
  );

  setUp(() {
    endpointBackend = RecordingEndpointBackend();
    platform = RecordingWindowsPlatform();
    backend = WindowsRealtimeMediaBackend(
      endpointBackend: endpointBackend,
      platform: platform,
    );
  });

  test('keeps platform cleanup before native endpoint release', () async {
    final endpoint = await backend.start(identity);
    final source = ScreenCaptureSource(
      id: ScreenCaptureSourceId('monitor:1'),
      kind: ScreenCaptureSourceKind.display,
    );

    await backend.attachCaptureSource(
      endpointId: endpoint,
      identity: identity,
      source: source,
    );
    final surface = await backend.attachRemoteVideoSurface(
      endpointId: endpoint,
      identity: identity,
    );
    await backend.detach(endpointId: endpoint, identity: identity);
    await backend.release(endpointId: endpoint, identity: identity);

    expect(surface.identity.matches(identity), isTrue);
    expect(platform.operations, <String>[
      'capture:1:monitor:1',
      'surface:1',
      'detach:1',
      'release:1',
    ]);
    expect(endpointBackend.operations, <String>[
      'start:realtime-1:7:send',
      'detach:1',
      'release:1',
    ]);
  });

  test(
    'preserves typed platform failures without changing endpoint ownership',
    () async {
      platform.failure = const RealtimeMediaException(
        RealtimeMediaErrorCode.encoderUnavailable,
        'hardware encoder unavailable',
      );
      final endpoint = await backend.start(identity);

      await expectLater(
        backend.attachCaptureSource(
          endpointId: endpoint,
          identity: identity,
          source: ScreenCaptureSource(
            id: ScreenCaptureSourceId('window:1'),
            kind: ScreenCaptureSourceKind.window,
          ),
        ),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.encoderUnavailable,
          ),
        ),
      );
      expect(endpointBackend.operations, <String>['start:realtime-1:7:send']);
      expect(platform.operations, <String>['capture:1:window:1']);
    },
  );

  test('statistics remain low-frequency and payload-free', () async {
    platform.stats = const RealtimeMediaStats(
      width: 1920,
      height: 1080,
      framesCaptured: 4,
      framesSent: 3,
      framesDropped: 1,
      framesDecoded: 0,
      framesRendered: 0,
    );
    final endpoint = await backend.start(identity);

    final stats = await backend.readStats(
      endpointId: endpoint,
      identity: identity,
    );

    expect(stats.width, 1920);
    expect(stats.framesDropped, 1);
    expect(platform.operations, <String>['stats:1']);
  });
}

final class RecordingEndpointBackend implements RealtimeMediaBackend {
  final List<String> operations = <String>[];

  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity identity,
  ) async {
    operations.add(
      'start:${identity.realtimeId}:${identity.generation}:${identity.direction.name}',
    );
    return RealtimeMediaEndpointId('1');
  }

  @override
  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  }) async {}

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => throw UnimplementedError();

  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('detach:${endpointId.value}');
  }

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('release:${endpointId.value}');
  }

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => throw UnimplementedError();
}

final class RecordingWindowsPlatform implements WindowsRealtimeMediaPlatform {
  final List<String> operations = <String>[];
  RealtimeMediaException? failure;
  RealtimeMediaStats stats = const RealtimeMediaStats();

  @override
  Future<List<ScreenCaptureSource>> listCaptureSources() async => const [];

  @override
  Future<void> startCapture({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  }) async {
    operations.add('capture:${endpointId.value}:${source.id.value}');
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('surface:${endpointId.value}');
    return RemoteVideoSurface(
      id: RemoteVideoSurfaceId('texture-${endpointId.value}'),
      endpointId: endpointId,
      identity: identity,
    );
  }

  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('detach:${endpointId.value}');
  }

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('release:${endpointId.value}');
  }

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('stats:${endpointId.value}');
    return stats;
  }
}
