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
      'owner-open:1',
      'detach:1',
      'owner-close:1',
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
      expect(endpointBackend.operations, <String>[
        'start:realtime-1:7:send',
        'owner-open:1',
      ]);
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

  test(
    'routes keyframe and decoder recovery through the owner token',
    () async {
      final sendEndpoint = await backend.start(identity);
      await backend.requestKeyframe(
        endpointId: sendEndpoint,
        identity: identity,
      );

      final receiveIdentity = RealtimeMediaEndpointIdentity(
        realtimeId: identity.realtimeId,
        peerId: identity.peerId,
        generation: identity.generation,
        direction: RealtimeMediaDirection.receive,
      );
      final receiveEndpoint = await backend.start(receiveIdentity);
      await backend.resetDecoder(
        endpointId: receiveEndpoint,
        identity: receiveIdentity,
      );

      expect(platform.operations, <String>['keyframe:1', 'reset-decoder:2']);
    },
  );

  test(
    'enumerates bounded display and window metadata without payloads',
    () async {
      platform.sources = <ScreenCaptureSource>[
        ScreenCaptureSource(
          id: ScreenCaptureSourceId('display:1'),
          kind: ScreenCaptureSourceKind.display,
          label: 'Primary display',
          width: 1920,
          height: 1080,
        ),
        ScreenCaptureSource(
          id: ScreenCaptureSourceId('window:1'),
          kind: ScreenCaptureSourceKind.window,
          label: 'Terminal',
          width: 1280,
          height: 720,
        ),
      ];

      final sources = await backend.listCaptureSources();

      expect(sources, hasLength(2));
      expect(sources.map((source) => source.kind), <ScreenCaptureSourceKind>[
        ScreenCaptureSourceKind.display,
        ScreenCaptureSourceKind.window,
      ]);
      expect(
        sources.singleWhere((source) => source.id.value == 'display:1').width,
        1920,
      );
      expect(platform.operations, isEmpty);
    },
  );

  test('source disappearance is typed and remains releasable', () async {
    platform.failure = const RealtimeMediaException(
      RealtimeMediaErrorCode.captureSourceEnded,
      'window closed while capture was starting',
    );
    final endpoint = await backend.start(identity);

    await expectLater(
      backend.attachCaptureSource(
        endpointId: endpoint,
        identity: identity,
        source: ScreenCaptureSource(
          id: ScreenCaptureSourceId('window:closed'),
          kind: ScreenCaptureSourceKind.window,
        ),
      ),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.captureSourceEnded,
        ),
      ),
    );

    await backend.release(endpointId: endpoint, identity: identity);
    expect(endpointBackend.operations.last, 'release:1');
  });

  test('retains the owner token when endpoint release is retryable', () async {
    endpointBackend.releaseFailure = const RealtimeMediaException(
      RealtimeMediaErrorCode.driverUnavailable,
      'driver is stopping',
    );
    final endpoint = await backend.start(identity);

    await expectLater(
      backend.release(endpointId: endpoint, identity: identity),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.driverUnavailable,
        ),
      ),
    );
    endpointBackend.releaseFailure = null;
    await backend.release(endpointId: endpoint, identity: identity);

    expect(platform.operations, <String>['release:1', 'release:1']);
    expect(endpointBackend.operations, <String>[
      'start:realtime-1:7:send',
      'owner-open:1',
      'owner-close:1',
      'release:1',
      'owner-close:1',
      'release:1',
    ]);
  });

  test('fails closed when endpoint backend has no native owner port', () async {
    final backendWithoutOwner = WindowsRealtimeMediaBackend(
      endpointBackend: EndpointBackendWithoutOwner(),
      platform: platform,
    );

    await expectLater(
      backendWithoutOwner.start(identity),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.backendFailure,
        ),
      ),
    );
  });

  test(
    'rejects platform operations from another endpoint generation',
    () async {
      final endpoint = await backend.start(identity);
      final replacementIdentity = RealtimeMediaEndpointIdentity(
        realtimeId: identity.realtimeId,
        peerId: identity.peerId,
        generation: identity.generation + 1,
        direction: identity.direction,
      );

      expect(
        () => backend.readStats(
          endpointId: endpoint,
          identity: replacementIdentity,
        ),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.staleEndpoint,
          ),
        ),
      );
    },
  );
}

final class RecordingEndpointBackend
    implements RealtimeMediaBackend, RealtimeMediaNativeOwnerBackend {
  final List<String> operations = <String>[];
  RealtimeMediaException? releaseFailure;
  int _nextEndpoint = 0;

  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity identity,
  ) async {
    _nextEndpoint += 1;
    operations.add(
      'start:${identity.realtimeId}:${identity.generation}:${identity.direction.name}',
    );
    return RealtimeMediaEndpointId('$_nextEndpoint');
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
    final failure = releaseFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<RealtimeMediaNativeOwnerToken> openNativeOwner({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('owner-open:${endpointId.value}');
    return RealtimeMediaNativeOwnerToken('owner-${endpointId.value}');
  }

  @override
  Future<void> closeNativeOwner({
    required RealtimeMediaNativeOwnerToken token,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('owner-close:${token.value.split('-').last}');
  }

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => throw UnimplementedError();
}

final class EndpointBackendWithoutOwner implements RealtimeMediaBackend {
  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity identity,
  ) async => RealtimeMediaEndpointId('1');

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
  }) => throw UnimplementedError();
}

final class RecordingWindowsPlatform implements WindowsRealtimeMediaPlatform {
  final List<String> operations = <String>[];
  RealtimeMediaException? failure;
  RealtimeMediaStats stats = const RealtimeMediaStats();
  List<ScreenCaptureSource> sources = const <ScreenCaptureSource>[];

  @override
  Future<List<ScreenCaptureSource>> listCaptureSources() async => sources;

  @override
  Future<void> startCapture({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {
    operations.add('capture:${endpointId.value}:${source.id.value}');
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
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
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {
    operations.add('detach:${endpointId.value}');
  }

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {
    operations.add('release:${endpointId.value}');
  }

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {
    operations.add('stats:${endpointId.value}');
    return stats;
  }

  @override
  Future<void> requestKeyframe({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {
    operations.add('keyframe:${endpointId.value}');
  }

  @override
  Future<void> resetDecoder({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {
    operations.add('reset-decoder:${endpointId.value}');
  }
}
