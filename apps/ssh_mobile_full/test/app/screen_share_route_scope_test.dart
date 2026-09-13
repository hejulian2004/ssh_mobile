import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_media_android/realtime_media_android.dart';
import 'package:realtime_media_windows/realtime_media_windows.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:feature_screen_share/feature_screen_share.dart';

import 'package:ssh_mobile/app/realtime_media_feature_adapters.dart';
import 'package:ssh_mobile/app/screen_share_route_scope.dart';

void main() {
  const realtimeId = '00112233445566778899aabbccddeeff';
  final source = ScreenCaptureSource(
    id: ScreenCaptureSourceId('display:1'),
    kind: ScreenCaptureSourceKind.display,
    label: 'Display 1',
    width: 1920,
    height: 1080,
  );

  late _RecordingMediaBackend backend;
  late _RecordingCapabilities capabilities;
  late _FakeRealtimeSession session;

  setUp(() {
    backend = _RecordingMediaBackend();
    capabilities = _RecordingCapabilities(
      sources: <ScreenCaptureSource>[source],
    );
    session = _FakeRealtimeSession(
      realtimeId: realtimeId,
      peerId: 'peer-remote',
      generation: 7,
    );
    addTearDown(session.close);
  });

  test('prepares capture and releases the endpoint in owner order', () async {
    final coordinator = _coordinator(
      backend,
      capabilities,
      session,
      source: source,
    );

    await coordinator.prepare(capture: true);
    await coordinator.port.startCapture(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );
    await coordinator.port.stop(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );

    expect(capabilities.prepareCalls, 1);
    expect(capabilities.listCalls, 1);
    expect(backend.operations, <String>[
      'start:send',
      'attach-capture:1',
      'detach:1',
      'release:1',
    ]);
    await coordinator.dispose();
  });

  test('rejects stale generation before touching the media backend', () async {
    final coordinator = _coordinator(
      backend,
      capabilities,
      session,
      source: source,
    );
    await coordinator.prepare(capture: true);

    await expectLater(
      coordinator.port.startCapture(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 8,
      ),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.staleGeneration,
        ),
      ),
    );
    expect(backend.operations, isEmpty);
    await coordinator.dispose();
  });

  test(
    'receive attaches only an opaque surface and releases it safely',
    () async {
      final coordinator = _coordinator(backend, capabilities, session);
      await coordinator.prepare(capture: false);
      await coordinator.port.startViewer(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 7,
      );
      await coordinator.port.stop(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 7,
      );

      expect(backend.operations, <String>[
        'start:receive',
        'attach-surface:1',
        'detach:1',
        'release:1',
      ]);
      expect(capabilities.prepareCalls, 0);
      expect(capabilities.listCalls, 0);
      await coordinator.dispose();
    },
  );

  test(
    'screen-share controller does not capture before remote acceptance',
    () async {
      final coordinator = _coordinator(
        backend,
        capabilities,
        session,
        source: source,
      );
      await coordinator.prepare(capture: true);
      final consent = _FakeConsentPort();
      final controller = ScreenShareController(
        consentPort: consent,
        mediaPort: coordinator.port,
        realtimeId: realtimeId,
        sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
        generation: 7,
        localPeerId: 'peer-local',
        remotePeerId: 'peer-remote',
        now: () => DateTime.utc(2030, 1, 1, 12),
      );
      await controller.setMediaReady(true);
      await controller.startOutgoing(operationId: 'operation-a');

      expect(backend.operations, isEmpty);
      consent.emit(
        RealtimeConsent(
          operationId: 'operation-a',
          realtimeId: realtimeId,
          sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
          issuedAt: DateTime.utc(2030, 1, 1, 12),
          expiresAt: DateTime.utc(2030, 1, 1, 12, 1),
          decision: RealtimeConsentDecision.accept,
          senderPeerId: 'peer-remote',
          actionRevision: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(backend.operations, <String>['start:send', 'attach-capture:1']);
      expect(controller.state, ScreenShareOperationState.active);
      await controller.cancel();
      controller.dispose();
      await consent.close();
      await coordinator.dispose();
    },
  );

  test(
    'stale capture preflight cannot create an endpoint after stop',
    () async {
      final gate = Completer<void>();
      capabilities.prepareGate = gate;
      final coordinator = _coordinator(
        backend,
        capabilities,
        session,
        source: source,
      );
      await coordinator.prepare(capture: true);

      final start = coordinator.port.startCapture(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 7,
      );
      final startExpectation = expectLater(
        start,
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.staleEndpoint,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final stop = coordinator.port.stop(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 7,
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await stop;

      await startExpectation;
      expect(backend.operations, isEmpty);
      await coordinator.dispose();
    },
  );

  test(
    'stop invalidates a queued capture before its preparation callback runs',
    () async {
      final gate = Completer<void>();
      capabilities.prepareGate = gate;
      final coordinator = _coordinator(
        backend,
        capabilities,
        session,
        source: source,
      );
      await coordinator.prepare(capture: true);

      final first = coordinator.port.startCapture(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 7,
      );
      final firstExpectation = expectLater(
        first,
        throwsA(isA<RealtimeMediaException>()),
      );
      await Future<void>.delayed(Duration.zero);
      final queued = coordinator.port.startCapture(
        operationId: 'operation-b',
        realtimeId: realtimeId,
        generation: 7,
      );
      final queuedExpectation = expectLater(
        queued,
        throwsA(isA<RealtimeMediaException>()),
      );
      await Future<void>.delayed(Duration.zero);
      final stop = coordinator.port.stop(
        operationId: 'operation-b',
        realtimeId: realtimeId,
        generation: 7,
      );

      gate.complete();
      await stop;

      await firstExpectation;
      await queuedExpectation;
      expect(capabilities.prepareCalls, 1);
      expect(capabilities.abandonCalls, 0);
      expect(backend.operations, isEmpty);
      await coordinator.dispose();
    },
  );

  test('generation replacement during preflight fails closed', () async {
    final gate = Completer<void>();
    capabilities.prepareGate = gate;
    final coordinator = _coordinator(
      backend,
      capabilities,
      session,
      source: source,
    );
    await coordinator.prepare(capture: true);

    final start = coordinator.port.startCapture(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );
    await Future<void>.delayed(Duration.zero);
    session.replaceGeneration(8);
    gate.complete();

    await expectLater(
      start,
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.staleEndpoint,
        ),
      ),
    );
    expect(backend.operations, isEmpty);
    await coordinator.dispose();
  });

  test(
    'an invalidated preparation is not abandoned again by the coordinator',
    () async {
      final coordinator = _coordinator(
        backend,
        capabilities,
        session,
        source: source,
      );
      capabilities.preparationResult =
          AppScreenSharePreparationResult.invalidated;
      await coordinator.prepare(capture: true);

      await expectLater(
        coordinator.port.startCapture(
          operationId: 'operation-a',
          realtimeId: realtimeId,
          generation: 7,
        ),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.staleEndpoint,
          ),
        ),
      );
      expect(capabilities.abandonCalls, 0);
      await coordinator.dispose();
    },
  );

  test(
    'attach success clears preparation before a later stale check',
    () async {
      final coordinator = _coordinator(
        backend,
        capabilities,
        session,
        source: source,
      );
      backend.afterAttach = () => session.replaceGeneration(8);
      await coordinator.prepare(capture: true);

      await expectLater(
        coordinator.port.startCapture(
          operationId: 'operation-a',
          realtimeId: realtimeId,
          generation: 7,
        ),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.staleEndpoint,
          ),
        ),
      );
      expect(capabilities.abandonCalls, 0);
      expect(backend.operations, contains('release:1'));
      await coordinator.dispose();
    },
  );

  test(
    'prepare rejects missing generation and missing capture source',
    () async {
      session.mediaToken = null;
      final missingGeneration = _coordinator(backend, capabilities, session);
      await expectLater(
        missingGeneration.prepare(capture: false),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.backendFailure,
          ),
        ),
      );

      session.replaceGeneration(7);
      final missingSource = _coordinator(backend, capabilities, session);
      await expectLater(
        missingSource.prepare(capture: true),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.invalidArgument,
          ),
        ),
      );
      await missingGeneration.dispose();
      await missingSource.dispose();
    },
  );

  test('capture fails closed when the selected source disappears', () async {
    final coordinator = _coordinator(
      backend,
      capabilities,
      session,
      source: source,
    );
    await coordinator.prepare(capture: true);
    capabilities.sources = const <ScreenCaptureSource>[];

    await expectLater(
      coordinator.port.startCapture(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 7,
      ),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.driverUnavailable,
        ),
      ),
    );
    expect(backend.operations, isEmpty);
    await coordinator.dispose();
  });

  test('stop rejects a different operation identity', () async {
    final coordinator = _coordinator(
      backend,
      capabilities,
      session,
      source: source,
    );
    await coordinator.prepare(capture: true);
    await coordinator.port.startCapture(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );

    await expectLater(
      coordinator.port.stop(
        operationId: 'operation-b',
        realtimeId: realtimeId,
        generation: 7,
      ),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.staleEndpoint,
        ),
      ),
    );
    await coordinator.port.stop(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );
    await coordinator.dispose();
  });

  test(
    'late viewer start releases its endpoint after generation replacement',
    () async {
      final gate = Completer<void>();
      backend.startGate = gate;
      final coordinator = _coordinator(backend, capabilities, session);
      await coordinator.prepare(capture: false);

      final start = coordinator.port.startViewer(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 7,
      );
      await Future<void>.delayed(Duration.zero);
      session.replaceGeneration(8);
      gate.complete();

      await expectLater(
        start,
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.staleEndpoint,
          ),
        ),
      );
      expect(backend.operations, contains('release:1'));
      await coordinator.dispose();
    },
  );

  testWidgets('receive route initializes and disposes its borrowed scope', (
    tester,
  ) async {
    await tester.pumpWidget(_routeApp(backend, session, capabilities));
    await tester.pumpAndSettle();

    expect(find.text('Screen sharing'), findsOneWidget);
    expect(find.text('Screen sharing idle'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(backend.operations, isEmpty);
  });

  testWidgets('send route can start an outgoing consent operation', (
    tester,
  ) async {
    await tester.pumpWidget(
      _routeApp(
        backend,
        session,
        capabilities,
        arguments: AppScreenShareRouteArguments(
          session: session,
          localPeerId: 'peer-local',
          source: source,
          mode: AppScreenShareRouteMode.send,
          startOutgoing: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Waiting for acceptance'), findsOneWidget);
    expect(
      session.sentConsents.single.decision,
      RealtimeConsentDecision.request,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('route renders typed initialization failures', (tester) async {
    await tester.pumpWidget(
      _routeApp(
        backend,
        session,
        capabilities,
        arguments: AppScreenShareRouteArguments(
          session: session,
          localPeerId: 'peer-local',
          mode: AppScreenShareRouteMode.receive,
          startOutgoing: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Screen sharing unavailable (invalidArgument).'),
      findsOneWidget,
    );
  });

  testWidgets('route renders a missing native token as a typed failure', (
    tester,
  ) async {
    final noTokenSession = _FakeRealtimeSession(
      realtimeId: realtimeId,
      peerId: 'peer-remote',
      generation: 7,
    )..mediaToken = null;
    addTearDown(noTokenSession.close);

    await tester.pumpWidget(_routeApp(backend, noTokenSession, capabilities));
    await tester.pumpAndSettle();
    expect(find.textContaining('backendFailure'), findsOneWidget);
  });

  testWidgets('route fails closed when platform ownership is unsupported', (
    tester,
  ) async {
    await tester.pumpWidget(_routeApp(backend, session, null));
    await tester.pumpAndSettle();

    expect(find.textContaining('driverUnavailable'), findsOneWidget);
  });

  testWidgets('incoming route exposes explicit accept and reject actions', (
    tester,
  ) async {
    await tester.pumpWidget(_routeApp(backend, session, capabilities));
    await tester.pumpAndSettle();

    session.emitConsent(_incomingConsent());
    await tester.pumpAndSettle();
    expect(find.text('Accept screen share'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);

    await tester.tap(find.text('Accept screen share'));
    await tester.pumpAndSettle();
    expect(find.text('Screen sharing active'), findsOneWidget);
    expect(session.sentConsents.last.decision, RealtimeConsentDecision.accept);
    expect(backend.operations, contains('start:receive'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(backend.operations, contains('release:1'));
  });

  testWidgets('incoming route can reject without creating media', (
    tester,
  ) async {
    await tester.pumpWidget(_routeApp(backend, session, capabilities));
    await tester.pumpAndSettle();

    session.emitConsent(_incomingConsent());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();

    expect(find.text('Screen-share request rejected'), findsOneWidget);
    expect(session.sentConsents.last.decision, RealtimeConsentDecision.reject);
    expect(backend.operations, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('platform capability factory preserves platform ownership', () async {
    final windowsPlatform = _RecordingWindowsPlatform(
      sources: <ScreenCaptureSource>[source],
    );
    final windows = WindowsRealtimeMediaBackend(
      endpointBackend: backend,
      platform: windowsPlatform,
    );
    final windowsCapabilities = appScreenSharePlatformCapabilitiesFor(windows);
    expect(
      await windowsCapabilities.prepareCapture(() => true),
      AppScreenSharePreparationResult.acquired,
    );
    expect(
      await windowsCapabilities.listCaptureSources(),
      <ScreenCaptureSource>[source],
    );

    final androidPlatform = _RecordingAndroidPlatform(
      sources: <ScreenCaptureSource>[source],
    );
    final android = AndroidRealtimeMediaBackend(
      endpointBackend: backend,
      platform: androidPlatform,
    );
    final androidCapabilities = appScreenSharePlatformCapabilitiesFor(android);
    expect(
      await androidCapabilities.prepareCapture(() => true),
      AppScreenSharePreparationResult.acquired,
    );
    expect(androidPlatform.projectionCalls, 1);
    expect(
      await androidCapabilities.listCaptureSources(),
      <ScreenCaptureSource>[source],
    );
    await androidCapabilities.abandonCapturePreparation();

    expect(
      () => appScreenSharePlatformCapabilitiesFor(backend),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.driverUnavailable,
        ),
      ),
    );
  });
}

Widget _routeApp(
  _RecordingMediaBackend backend,
  _FakeRealtimeSession session,
  _RecordingCapabilities? capabilities, {
  AppScreenShareRouteArguments? arguments,
}) => MaterialApp(
  home: AppScreenShareRouteScope(
    arguments:
        arguments ??
        AppScreenShareRouteArguments(
          session: session,
          localPeerId: 'peer-local',
        ),
    resources: AppRealtimeMediaResources(
      backend: backend,
      sessionFactory: AppRealtimeMediaSessionFactory(backend: backend),
    ),
    capabilities: capabilities,
  ),
);

AppScreenShareMediaCoordinator _coordinator(
  _RecordingMediaBackend backend,
  _RecordingCapabilities capabilities,
  _FakeRealtimeSession session, {
  ScreenCaptureSource? source,
}) => AppScreenShareMediaCoordinator(
  session: session,
  resources: AppRealtimeMediaResources(
    backend: backend,
    sessionFactory: AppRealtimeMediaSessionFactory(backend: backend),
  ),
  capabilities: capabilities,
  source: source,
);

final class _FakeConsentPort implements ScreenShareConsentPort {
  final StreamController<RealtimeConsent> _events =
      StreamController<RealtimeConsent>.broadcast();
  final List<RealtimeConsent> sent = <RealtimeConsent>[];

  @override
  Stream<RealtimeConsent> get consents => _events.stream;

  @override
  Future<SdkResult<void>> sendConsent(RealtimeConsent consent) async {
    sent.add(consent);
    return const SdkSuccess<void>(null);
  }

  void emit(RealtimeConsent consent) => _events.add(consent);

  Future<void> close() => _events.close();
}

final class _RecordingCapabilities
    implements AppScreenSharePlatformCapabilities {
  _RecordingCapabilities({required this.sources});

  List<ScreenCaptureSource> sources;
  int prepareCalls = 0;
  int abandonCalls = 0;
  int listCalls = 0;
  Completer<void>? prepareGate;
  AppScreenSharePreparationResult preparationResult =
      AppScreenSharePreparationResult.acquired;

  @override
  Future<AppScreenSharePreparationResult> prepareCapture(
    AppScreenShareOperationGuard guard,
  ) async {
    prepareCalls++;
    final gate = prepareGate;
    if (gate != null) await gate.future;
    if (!guard()) return AppScreenSharePreparationResult.invalidated;
    return preparationResult;
  }

  @override
  Future<void> abandonCapturePreparation() async {
    abandonCalls++;
  }

  @override
  Future<List<ScreenCaptureSource>> listCaptureSources() async {
    listCalls++;
    return sources;
  }
}

final class _RecordingMediaBackend implements RealtimeMediaBackend {
  final List<String> operations = <String>[];
  int _nextEndpoint = 0;
  Completer<void>? startGate;
  void Function()? afterAttach;

  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity identity,
  ) async {
    final gate = startGate;
    if (gate != null) await gate.future;
    final id = RealtimeMediaEndpointId('${++_nextEndpoint}');
    operations.add('start:${identity.direction.name}');
    return id;
  }

  @override
  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  }) async {
    operations.add('attach-capture:${endpointId.value}');
    afterAttach?.call();
  }

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('attach-surface:${endpointId.value}');
    return RemoteVideoSurface(
      id: RemoteVideoSurfaceId('surface:${endpointId.value}'),
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
  }) async => RealtimeMediaStats();
}

final class _FakeRealtimeSession implements RealtimeSession {
  _FakeRealtimeSession({
    required this.realtimeId,
    required this.peerId,
    required int generation,
  }) : mediaToken = RealtimeSessionToken(
         realtimeId: realtimeId,
         peerId: peerId,
         generation: generation,
       ),
       _consents = StreamController<RealtimeConsent>.broadcast();

  @override
  final String realtimeId;

  @override
  final String peerId;

  @override
  String? get sharedSessionInstanceId => '00112233445566778899aabbccddeeff';

  @override
  RealtimeSessionToken? mediaToken;

  @override
  RealtimeSessionState state = RealtimeSessionState.connected;

  @override
  int revision = 1;

  @override
  int? get generation => mediaToken?.generation;

  @override
  RealtimeAudioState audioState = RealtimeAudioState.unavailable;

  @override
  RealtimeSnapshot? get currentSnapshot => null;

  @override
  Stream<RealtimeSnapshot> get snapshots =>
      const Stream<RealtimeSnapshot>.empty();

  final StreamController<RealtimeConsent> _consents;

  @override
  Stream<RealtimeConsent> get consentEvents => _consents.stream;

  final List<RealtimeConsent> sentConsents = <RealtimeConsent>[];

  @override
  Future<SdkResult<void>> sendConsent(RealtimeConsent consent) async {
    sentConsents.add(consent);
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> start() async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> stop() async => const SdkSuccess<void>(null);

  void replaceGeneration(int generation) {
    mediaToken = RealtimeSessionToken(
      realtimeId: realtimeId,
      peerId: peerId,
      generation: generation,
    );
  }

  void emitConsent(RealtimeConsent consent) => _consents.add(consent);

  Future<void> close() => _consents.close();
}

RealtimeConsent _incomingConsent() {
  final issued = DateTime.now().toUtc();
  return RealtimeConsent(
    operationId: 'operation-a',
    realtimeId: '00112233445566778899aabbccddeeff',
    sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
    issuedAt: issued,
    expiresAt: issued.add(const Duration(minutes: 1)),
    decision: RealtimeConsentDecision.request,
    senderPeerId: 'peer-remote',
    actionRevision: 1,
  );
}

final class _RecordingWindowsPlatform implements WindowsRealtimeMediaPlatform {
  _RecordingWindowsPlatform({required this.sources});

  final List<ScreenCaptureSource> sources;

  @override
  Future<List<ScreenCaptureSource>> listCaptureSources() async => sources;

  @override
  Future<void> startCapture({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {}

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async => RemoteVideoSurface(
    id: RemoteVideoSurfaceId('surface:${endpointId.value}'),
    endpointId: endpointId,
    identity: identity,
  );

  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {}

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {}

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async => RealtimeMediaStats();

  @override
  Future<void> requestKeyframe({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {}

  @override
  Future<void> resetDecoder({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {}

  @override
  Future<void> applyAdaptation({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required RealtimeMediaAdaptationDecision decision,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {}
}

final class _RecordingAndroidPlatform implements AndroidRealtimeMediaPlatform {
  _RecordingAndroidPlatform({required this.sources});

  final List<ScreenCaptureSource> sources;
  int projectionCalls = 0;

  @override
  Future<void> requestProjection() async => projectionCalls++;

  @override
  Future<void> abandonProjectionGrant() async {}

  @override
  Future<List<ScreenCaptureSource>> listCaptureSources() async => sources;

  @override
  Future<void> startCapture({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {}

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async => RemoteVideoSurface(
    id: RemoteVideoSurfaceId('surface:${endpointId.value}'),
    endpointId: endpointId,
    identity: identity,
  );

  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {}

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {}

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async => RealtimeMediaStats();

  @override
  Future<void> requestKeyframe({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {}

  @override
  Future<void> resetDecoder({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {}

  @override
  Future<void> applyAdaptation({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required RealtimeMediaAdaptationDecision decision,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {}
}
