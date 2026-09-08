import 'package:realtime_media/realtime_media.dart';
import 'package:test/test.dart';

import 'package:realtime_media_android/src/android_realtime_media_backend.dart';
import 'package:realtime_media_android/src/android_realtime_media_platform.dart';

void main() {
  late RecordingEndpointBackend endpointBackend;
  late RecordingAndroidPlatform platform;
  late AndroidRealtimeMediaBackend backend;

  final sendIdentity = RealtimeMediaEndpointIdentity(
    realtimeId: 'realtime-1',
    peerId: 'peer-a',
    generation: 7,
    direction: RealtimeMediaDirection.send,
  );
  final receiveIdentity = RealtimeMediaEndpointIdentity(
    realtimeId: 'realtime-1',
    peerId: 'peer-a',
    generation: 7,
    direction: RealtimeMediaDirection.receive,
  );

  setUp(() {
    endpointBackend = RecordingEndpointBackend();
    platform = RecordingAndroidPlatform();
    backend = AndroidRealtimeMediaBackend(
      endpointBackend: endpointBackend,
      platform: platform,
    );
  });

  test(
    'keeps native owner and platform teardown before endpoint release',
    () async {
      final endpoint = await backend.start(sendIdentity);
      await backend.attachCaptureSource(
        endpointId: endpoint,
        identity: sendIdentity,
        source: ScreenCaptureSource(
          id: ScreenCaptureSourceId('display:default'),
          kind: ScreenCaptureSourceKind.display,
        ),
      );

      await backend.detach(endpointId: endpoint, identity: sendIdentity);
      await backend.release(endpointId: endpoint, identity: sendIdentity);

      expect(platform.operations, <String>[
        'projection:start:1',
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
    },
  );

  test('does not call renderer detach for a send owner', () async {
    final endpoint = await backend.start(sendIdentity);
    await backend.detach(endpointId: endpoint, identity: sendIdentity);

    expect(platform.operations, <String>['detach:1']);
    expect(platform.rendererDetachCalls, 0);
  });

  test('keeps receive owners outside projection capture ownership', () async {
    final sendEndpoint = await backend.start(sendIdentity);
    final receiveEndpoint = await backend.start(receiveIdentity);

    await backend.attachCaptureSource(
      endpointId: sendEndpoint,
      identity: sendIdentity,
      source: ScreenCaptureSource(
        id: ScreenCaptureSourceId('display:default'),
        kind: ScreenCaptureSourceKind.display,
      ),
    );
    await backend.attachRemoteVideoSurface(
      endpointId: receiveEndpoint,
      identity: receiveIdentity,
    );

    await backend.detach(
      endpointId: receiveEndpoint,
      identity: receiveIdentity,
    );
    expect(platform.operations, <String>[
      'projection:start:1',
      'surface:2',
      'detach:2',
    ]);
    expect(platform.rendererDetachCalls, 1);

    await backend.detach(endpointId: sendEndpoint, identity: sendIdentity);
    expect(platform.operations, <String>[
      'projection:start:1',
      'surface:2',
      'detach:2',
      'detach:1',
    ]);
  });

  test(
    'maps hardware and projection failures without losing endpoint ownership',
    () async {
      final endpoint = await backend.start(sendIdentity);
      platform.failure = const RealtimeMediaException(
        RealtimeMediaErrorCode.encoderUnavailable,
        'hardware MediaCodec unavailable',
      );

      await expectLater(
        backend.attachCaptureSource(
          endpointId: endpoint,
          identity: sendIdentity,
          source: ScreenCaptureSource(
            id: ScreenCaptureSourceId('display:default'),
            kind: ScreenCaptureSourceKind.display,
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

      platform.failure = const RealtimeMediaException(
        RealtimeMediaErrorCode.permissionDenied,
        'projection revoked',
      );
      await expectLater(
        platform.requestProjection(),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.permissionDenied,
          ),
        ),
      );

      platform.failure = null;
      await backend.release(endpointId: endpoint, identity: sendIdentity);
      expect(endpointBackend.operations.last, 'release:1');
    },
  );

  test('retains the owner token when endpoint release is retryable', () async {
    final endpoint = await backend.start(sendIdentity);
    endpointBackend.releaseFailure = const RealtimeMediaException(
      RealtimeMediaErrorCode.driverUnavailable,
      'driver is stopping',
    );

    await expectLater(
      backend.release(endpointId: endpoint, identity: sendIdentity),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.driverUnavailable,
        ),
      ),
    );

    endpointBackend.releaseFailure = null;
    await backend.release(endpointId: endpoint, identity: sendIdentity);
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

  test('retries platform cleanup after a transient owner failure', () async {
    final endpoint = await backend.start(sendIdentity);
    platform.releaseFailure = const RealtimeMediaException(
      RealtimeMediaErrorCode.driverUnavailable,
      'native owner is temporarily unavailable',
    );

    await expectLater(
      backend.release(endpointId: endpoint, identity: sendIdentity),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.driverUnavailable,
        ),
      ),
    );

    platform.releaseFailure = null;
    await backend.release(endpointId: endpoint, identity: sendIdentity);
    expect(platform.operations, <String>['release:1', 'release:1']);
  });

  test(
    'receive surface and stats remain opaque and generation-bound',
    () async {
      final endpoint = await backend.start(receiveIdentity);
      final surface = await backend.attachRemoteVideoSurface(
        endpointId: endpoint,
        identity: receiveIdentity,
      );
      final stats = await backend.readStats(
        endpointId: endpoint,
        identity: receiveIdentity,
      );

      expect(surface.identity.matches(receiveIdentity), isTrue);
      expect(stats.framesRendered, 3);

      final replacement = RealtimeMediaEndpointIdentity(
        realtimeId: receiveIdentity.realtimeId,
        peerId: receiveIdentity.peerId,
        generation: receiveIdentity.generation + 1,
        direction: receiveIdentity.direction,
      );
      expect(
        () => backend.readStats(endpointId: endpoint, identity: replacement),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.staleEndpoint,
          ),
        ),
      );

      await backend.release(endpointId: endpoint, identity: receiveIdentity);
      expect(platform.rendererDetachCalls, 1);
    },
  );

  test(
    'routes keyframe and decoder recovery through the owner token',
    () async {
      final sendEndpoint = await backend.start(sendIdentity);
      await backend.requestKeyframe(
        endpointId: sendEndpoint,
        identity: sendIdentity,
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
    'projection requests are delegated and repeated calls are safe',
    () async {
      await backend.requestProjection();
      await backend.requestProjection();
      expect(platform.operations, <String>['projection', 'projection']);
    },
  );

  test(
    'fails closed when endpoint backend lacks native owner capability',
    () async {
      final backendWithoutOwner = AndroidRealtimeMediaBackend(
        endpointBackend: EndpointBackendWithoutOwner(),
        platform: platform,
      );

      await expectLater(
        backendWithoutOwner.start(sendIdentity),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.backendFailure,
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
  int _nextEndpoint = 1;

  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity identity,
  ) async {
    final id = _nextEndpoint++;
    operations.add(
      'start:${identity.realtimeId}:${identity.generation}:${identity.direction.name}',
    );
    return RealtimeMediaEndpointId('$id');
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

final class RecordingAndroidPlatform implements AndroidRealtimeMediaPlatform {
  final List<String> operations = <String>[];
  RealtimeMediaException? failure;
  RealtimeMediaException? releaseFailure;
  int rendererDetachCalls = 0;

  @override
  Future<void> requestProjection() async {
    operations.add('projection');
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<List<ScreenCaptureSource>> listCaptureSources() async => const [];

  @override
  Future<void> startCapture({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {
    operations.add('projection:start:${endpointId.value}');
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
    if (identity.direction == RealtimeMediaDirection.receive) {
      rendererDetachCalls++;
    }
  }

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {
    operations.add('release:${endpointId.value}');
    if (identity.direction == RealtimeMediaDirection.receive) {
      rendererDetachCalls++;
    }
    final error = releaseFailure;
    if (error != null) throw error;
  }

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async => const RealtimeMediaStats(framesRendered: 3);

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
