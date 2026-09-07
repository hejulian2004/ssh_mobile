import 'dart:async';

import 'package:realtime_media/realtime_media.dart';
import 'package:test/test.dart';

void main() {
  late RecordingBackend backend;
  late RealtimeMediaSessionController controller;

  setUp(() {
    backend = RecordingBackend();
    controller = RealtimeMediaSessionController(
      backend: backend,
      realtimeId: 'realtime-1',
      peerId: 'peer-a',
      generation: 7,
    );
  });

  test('starts, attaches, detaches, and releases in order', () async {
    final endpoint = await controller.start(RealtimeMediaDirection.send);
    final source = ScreenCaptureSource(
      id: ScreenCaptureSourceId('display-1'),
      kind: ScreenCaptureSourceKind.display,
    );

    await controller.attachCaptureSource(endpoint, source);
    await controller.detach(endpoint);
    await controller.release(endpoint);

    expect(backend.operations, <String>[
      'start:realtime-1:7:send',
      'attach-source:endpoint-1:display-1',
      'detach:endpoint-1',
      'release:endpoint-1',
    ]);
    expect(endpoint.state, RealtimeMediaEndpointState.released);
    expect(controller.state, RealtimeMediaSessionState.ready);
  });

  test('typed native start failure leaves the controller failed', () async {
    backend.failStart = true;

    await expectLater(
      controller.start(RealtimeMediaDirection.send),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.backendFailure,
        ),
      ),
    );
    expect(controller.state, RealtimeMediaSessionState.failed);
  });

  test('release automatically detaches before releasing', () async {
    final endpoint = await controller.start(RealtimeMediaDirection.receive);
    await controller.attachRemoteVideoSurface(endpoint);

    await controller.release(endpoint);

    expect(backend.operations, <String>[
      'start:realtime-1:7:receive',
      'attach-surface:endpoint-1',
      'detach:endpoint-1',
      'release:endpoint-1',
    ]);
    expect(endpoint.surface!.state, RemoteVideoSurfaceState.released);
  });

  test(
    'detaching a remote surface releases it and permits a new attachment',
    () async {
      final endpoint = await controller.start(RealtimeMediaDirection.receive);
      final firstSurface = await controller.attachRemoteVideoSurface(endpoint);

      await controller.detach(endpoint);

      expect(firstSurface.state, RemoteVideoSurfaceState.released);
      expect(endpoint.surface, isNull);
      expect(endpoint.state, RealtimeMediaEndpointState.detached);
      final secondSurface = await controller.attachRemoteVideoSurface(endpoint);
      expect(secondSurface.id.value, 'surface-endpoint-1');
      expect(backend.operations, <String>[
        'start:realtime-1:7:receive',
        'attach-surface:endpoint-1',
        'detach:endpoint-1',
        'attach-surface:endpoint-1',
      ]);
    },
  );

  test(
    'mismatched remote surface is released and detached before failing closed',
    () async {
      backend.returnMismatchedSurface = true;
      final endpoint = await controller.start(RealtimeMediaDirection.receive);

      await expectLater(
        controller.attachRemoteVideoSurface(endpoint),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.backendFailure,
          ),
        ),
      );

      expect(endpoint.state, RealtimeMediaEndpointState.failed);
      expect(backend.lastSurface?.state, RemoteVideoSurfaceState.released);
      expect(backend.operations, <String>[
        'start:realtime-1:7:receive',
        'attach-surface:endpoint-1',
        'detach:endpoint-1',
      ]);
    },
  );

  test(
    'stop drains a source attachment that completes after endpoint release',
    () async {
      backend.attachGate = Completer<void>();
      backend.attachStarted = Completer<void>();
      final endpoint = await controller.start(RealtimeMediaDirection.send);
      final source = ScreenCaptureSource(
        id: ScreenCaptureSourceId('display-1'),
        kind: ScreenCaptureSourceKind.display,
      );

      final attaching = controller.attachCaptureSource(endpoint, source);
      await backend.attachStarted!.future;
      final stopping = controller.stop();
      backend.attachGate!.complete();

      await expectLater(
        attaching,
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.sessionReleased,
          ),
        ),
      );
      await stopping;

      expect(endpoint.state, RealtimeMediaEndpointState.released);
      expect(endpoint.source, isNull);
      expect(backend.operations, <String>[
        'start:realtime-1:7:send',
        'attach-source:endpoint-1:display-1',
        'release:endpoint-1',
        'detach:endpoint-1',
        'release:endpoint-1',
      ]);
    },
  );

  test('duplicate attach is rejected without a backend call', () async {
    final endpoint = await controller.start(RealtimeMediaDirection.send);
    final source = ScreenCaptureSource(
      id: ScreenCaptureSourceId('display-1'),
      kind: ScreenCaptureSourceKind.display,
    );
    await controller.attachCaptureSource(endpoint, source);

    await expectLater(
      controller.attachCaptureSource(endpoint, source),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.duplicateAttach,
        ),
      ),
    );
    expect(backend.operations, hasLength(2));
  });

  test(
    'concurrent attachment to one endpoint is rejected before a second call',
    () async {
      backend.attachGate = Completer<void>();
      backend.attachStarted = Completer<void>();
      final endpoint = await controller.start(RealtimeMediaDirection.send);
      final source = ScreenCaptureSource(
        id: ScreenCaptureSourceId('display-1'),
        kind: ScreenCaptureSourceKind.display,
      );

      final firstAttach = controller.attachCaptureSource(endpoint, source);
      await backend.attachStarted!.future;

      await expectLater(
        controller.attachCaptureSource(endpoint, source),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.duplicateAttach,
          ),
        ),
      );

      backend.attachGate!.complete();
      await firstAttach;
      expect(endpoint.state, RealtimeMediaEndpointState.attached);
      expect(backend.operations, <String>[
        'start:realtime-1:7:send',
        'attach-source:endpoint-1:display-1',
      ]);
    },
  );

  test('use after release is rejected and release is idempotent', () async {
    final endpoint = await controller.start(RealtimeMediaDirection.send);
    await controller.release(endpoint);
    await controller.release(endpoint);

    await expectLater(
      controller.detach(endpoint),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.useAfterRelease,
        ),
      ),
    );
    expect(
      backend.operations.where(
        (operation) => operation == 'release:endpoint-1',
      ),
      hasLength(1),
    );
  });

  test(
    'release before start is safe and permanently closes the controller',
    () async {
      await controller.release();
      await controller.release();

      expect(backend.operations, isEmpty);
      expect(controller.state, RealtimeMediaSessionState.released);
      await expectLater(
        controller.start(RealtimeMediaDirection.send),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.sessionReleased,
          ),
        ),
      );
    },
  );

  test('stop is idempotent and releases every active endpoint', () async {
    final endpoint = await controller.start(RealtimeMediaDirection.send);

    await controller.stop();
    await controller.stop();

    expect(endpoint.state, RealtimeMediaEndpointState.released);
    expect(controller.state, RealtimeMediaSessionState.released);
    expect(backend.operations, <String>[
      'start:realtime-1:7:send',
      'release:endpoint-1',
    ]);
  });

  test(
    'retryable endpoint release failure retains the lease for retry',
    () async {
      final endpoint = await controller.start(RealtimeMediaDirection.send);
      backend.releaseFailuresRemaining = 1;

      await expectLater(
        controller.release(endpoint),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.driverUnavailable,
          ),
        ),
      );

      expect(endpoint.state, RealtimeMediaEndpointState.failed);
      expect(controller.state, RealtimeMediaSessionState.failed);
      expect(
        backend.operations.where(
          (operation) => operation == 'release:endpoint-1',
        ),
        hasLength(1),
      );

      await controller.release(endpoint);

      expect(endpoint.state, RealtimeMediaEndpointState.released);
      expect(controller.state, RealtimeMediaSessionState.ready);
      expect(
        backend.operations.where(
          (operation) => operation == 'release:endpoint-1',
        ),
        hasLength(2),
      );
    },
  );

  test(
    'stop remains retryable while a native endpoint lease is retained',
    () async {
      final endpoint = await controller.start(RealtimeMediaDirection.send);
      backend.releaseFailuresRemaining = 1;

      await expectLater(
        controller.stop(),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.driverUnavailable,
          ),
        ),
      );

      expect(endpoint.state, RealtimeMediaEndpointState.failed);
      expect(controller.state, RealtimeMediaSessionState.failed);

      await controller.stop();

      expect(endpoint.state, RealtimeMediaEndpointState.released);
      expect(controller.state, RealtimeMediaSessionState.released);
      expect(
        backend.operations.where(
          (operation) => operation == 'release:endpoint-1',
        ),
        hasLength(2),
      );
    },
  );

  test('concurrent stops share one terminal endpoint cleanup', () async {
    final endpoint = await controller.start(RealtimeMediaDirection.send);
    backend.releaseGate = Completer<void>();
    backend.releaseStarted = Completer<void>();

    final firstStop = controller.stop();
    await backend.releaseStarted!.future;
    final secondStop = controller.stop();
    await Future<void>.delayed(Duration.zero);

    expect(
      backend.operations.where(
        (operation) => operation == 'release:endpoint-1',
      ),
      hasLength(1),
    );

    backend.releaseGate!.complete();
    await Future.wait<void>(<Future<void>>[firstStop, secondStop]);

    expect(endpoint.state, RealtimeMediaEndpointState.released);
    expect(controller.state, RealtimeMediaSessionState.released);
  });

  test('stop rejects a new start while terminal cleanup is pending', () async {
    final endpoint = await controller.start(RealtimeMediaDirection.send);
    backend.releaseGate = Completer<void>();
    backend.releaseStarted = Completer<void>();

    final stopping = controller.stop();
    await backend.releaseStarted!.future;

    await expectLater(
      controller.start(RealtimeMediaDirection.receive),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.sessionReleased,
        ),
      ),
    );

    backend.releaseGate!.complete();
    await stopping;

    expect(endpoint.state, RealtimeMediaEndpointState.released);
    expect(backend.operations, <String>[
      'start:realtime-1:7:send',
      'release:endpoint-1',
    ]);
    expect(controller.state, RealtimeMediaSessionState.released);
  });

  test(
    'stop drains a native endpoint acquired while start was pending',
    () async {
      backend.startGate = Completer<void>();
      backend.startStarted = Completer<void>();

      final starting = controller.start(RealtimeMediaDirection.send);
      await backend.startStarted!.future;
      final stopping = controller.stop();
      backend.startGate!.complete();

      await expectLater(
        starting,
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.sessionReleased,
          ),
        ),
      );
      await stopping;

      expect(backend.operations, <String>[
        'start:realtime-1:7:send',
        'release:endpoint-1',
      ]);
      expect(controller.state, RealtimeMediaSessionState.released);
    },
  );

  test(
    'dispose before start is safe and permanently closes the controller',
    () async {
      await controller.dispose();
      await controller.dispose();

      expect(backend.operations, isEmpty);
      expect(controller.state, RealtimeMediaSessionState.released);
      await expectLater(
        controller.start(RealtimeMediaDirection.receive),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.sessionReleased,
          ),
        ),
      );
    },
  );

  test('reads payload-free low-frequency endpoint statistics', () async {
    backend.stats = const RealtimeMediaStats(
      width: 1280,
      height: 720,
      framesCaptured: 10,
      framesSent: 9,
      framesDropped: 1,
    );
    final endpoint = await controller.start(RealtimeMediaDirection.send);

    final stats = await controller.stats(endpoint);

    expect(stats.width, 1280);
    expect(stats.height, 720);
    expect(stats.framesSent, 9);
    expect(backend.operations.last, 'stats:endpoint-1');
  });

  test('foreign generation endpoint is stale', () async {
    final oldEndpoint = await controller.start(RealtimeMediaDirection.send);
    final nextController = RealtimeMediaSessionController(
      backend: backend,
      realtimeId: 'realtime-1',
      peerId: 'peer-a',
      generation: 8,
    );

    await expectLater(
      nextController.detach(oldEndpoint),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.staleEndpoint,
        ),
      ),
    );
  });

  test('backend failure makes the endpoint and session failed', () async {
    backend.failAttach = true;
    final endpoint = await controller.start(RealtimeMediaDirection.send);
    final source = ScreenCaptureSource(
      id: ScreenCaptureSourceId('display-1'),
      kind: ScreenCaptureSourceKind.display,
    );

    await expectLater(
      controller.attachCaptureSource(endpoint, source),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.backendFailure,
        ),
      ),
    );
    expect(endpoint.state, RealtimeMediaEndpointState.failed);
    expect(controller.state, RealtimeMediaSessionState.failed);
    await expectLater(
      controller.attachCaptureSource(endpoint, source),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.failedState,
        ),
      ),
    );
  });

  test('typed native attach failure leaves the endpoint failed', () async {
    backend.failTypedAttach = true;
    final endpoint = await controller.start(RealtimeMediaDirection.send);
    final source = ScreenCaptureSource(
      id: ScreenCaptureSourceId('display-1'),
      kind: ScreenCaptureSourceKind.display,
    );

    await expectLater(
      controller.attachCaptureSource(endpoint, source),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.backendFailure,
        ),
      ),
    );
    expect(endpoint.state, RealtimeMediaEndpointState.failed);
    expect(controller.state, RealtimeMediaSessionState.failed);
  });

  test(
    'session release drains every endpoint after one cleanup failure',
    () async {
      backend.failDetach = true;
      final first = await controller.start(RealtimeMediaDirection.send);
      final second = await controller.start(RealtimeMediaDirection.receive);
      final source = ScreenCaptureSource(
        id: ScreenCaptureSourceId('display-1'),
        kind: ScreenCaptureSourceKind.display,
      );
      await controller.attachCaptureSource(first, source);
      await controller.attachRemoteVideoSurface(second);

      await expectLater(
        controller.release(),
        throwsA(isA<RealtimeMediaException>()),
      );

      expect(first.state, RealtimeMediaEndpointState.released);
      expect(second.state, RealtimeMediaEndpointState.released);
      expect(backend.operations, <String>[
        'start:realtime-1:7:send',
        'start:realtime-1:7:receive',
        'attach-source:endpoint-1:display-1',
        'attach-surface:endpoint-2',
        'detach:endpoint-1',
        'release:endpoint-1',
        'detach:endpoint-2',
        'release:endpoint-2',
      ]);
      expect(controller.state, RealtimeMediaSessionState.released);
    },
  );
}

final class RecordingBackend implements RealtimeMediaBackend {
  final List<String> operations = <String>[];
  bool failStart = false;
  bool failAttach = false;
  bool failTypedAttach = false;
  bool failDetach = false;
  int releaseFailuresRemaining = 0;
  bool returnMismatchedSurface = false;
  Completer<void>? attachGate;
  Completer<void>? attachStarted;
  Completer<void>? releaseGate;
  Completer<void>? releaseStarted;
  Completer<void>? startGate;
  Completer<void>? startStarted;
  RealtimeMediaStats stats = const RealtimeMediaStats();
  RemoteVideoSurface? lastSurface;
  int _nextEndpoint = 0;

  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity identity,
  ) async {
    _nextEndpoint += 1;
    operations.add(
      'start:${identity.realtimeId}:${identity.generation}:${identity.direction.name}',
    );
    if (startStarted != null && !startStarted!.isCompleted) {
      startStarted!.complete();
    }
    if (startGate != null) await startGate!.future;
    if (failStart) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'synthetic typed start failure',
      );
    }
    return RealtimeMediaEndpointId('endpoint-$_nextEndpoint');
  }

  @override
  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  }) async {
    operations.add('attach-source:${endpointId.value}:${source.id.value}');
    if (attachStarted != null && !attachStarted!.isCompleted) {
      attachStarted!.complete();
    }
    if (attachGate != null) await attachGate!.future;
    if (failTypedAttach) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'synthetic typed attach failure',
      );
    }
    if (failAttach) throw StateError('synthetic attach failure');
  }

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('attach-surface:${endpointId.value}');
    final surface = RemoteVideoSurface(
      id: RemoteVideoSurfaceId('surface-${endpointId.value}'),
      endpointId: returnMismatchedSurface
          ? RealtimeMediaEndpointId('foreign-endpoint')
          : endpointId,
      identity: returnMismatchedSurface
          ? RealtimeMediaEndpointIdentity(
              realtimeId: identity.realtimeId,
              peerId: identity.peerId,
              generation: identity.generation + 1,
              direction: identity.direction,
            )
          : identity,
    );
    lastSurface = surface;
    return surface;
  }

  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('detach:${endpointId.value}');
    if (failDetach) throw StateError('synthetic detach failure');
  }

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('release:${endpointId.value}');
    if (releaseStarted != null && !releaseStarted!.isCompleted) {
      releaseStarted!.complete();
    }
    if (releaseGate != null) await releaseGate!.future;
    if (releaseFailuresRemaining > 0) {
      releaseFailuresRemaining -= 1;
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.driverUnavailable,
        'synthetic driver unavailable',
      );
    }
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
