import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_media_android/realtime_media_android.dart';
import 'package:realtime_media_windows/realtime_media_windows.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:feature_screen_share/feature_screen_share.dart';

import 'package:ssh_mobile/app/realtime_media_feature_adapters.dart';
import 'package:ssh_mobile/app/screen_share_route_scope.dart';
import 'package:ssh_mobile/app/screen_share_peer_arbitration.dart';
import 'package:ssh_mobile/app/screen_share_session_lease.dart';
import 'package:ssh_mobile/app/screen_share_background_host.dart';
import 'package:ssh_mobile/app/navigation/app_route_contributions.dart';

late AppScreenShareSessions _testSessions;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('ssh_mobile/window_presentation');
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
    _testSessions = AppScreenShareSessions();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (_) async => true);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, null),
    );
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
    addTearDown(_testSessions.dispose);
  });

  test('identity wait ends immediately when its caller is disposed', () async {
    session.mediaToken = null;
    final cancellation = Completer<void>();
    var completed = false;
    final waiting = waitForScreenShareSessionIdentity(
      session,
      cancelled: cancellation.future,
    ).then((_) => completed = true);
    expect(completed, isFalse);
    cancellation.complete();
    // Stream.empty's cancellation Future lives outside FakeAsync's zone.
    // Observe its actual completion, bounded below the identity timeout.
    await waiting.timeout(const Duration(seconds: 5));
    expect(completed, isTrue);
  });

  test('reports a capture worker failure after successful attachment', () {
    fakeAsync((clock) {
      final logger = _MediaHealthLogger();
      final coordinator = _coordinator(
        backend,
        capabilities,
        session,
        source: source,
        logger: logger,
      );
      final events = <ScreenShareMediaEvent>[];
      final subscription = coordinator.port.events.listen(events.add);
      unawaited(
        coordinator
            .prepare(capture: true)
            .then(
              (_) => coordinator.port.startCapture(
                operationId: 'operation-a',
                realtimeId: realtimeId,
                generation: 7,
              ),
            ),
      );
      clock.flushMicrotasks();
      expect(backend.operations, ['start:send', 'attach-capture:1']);
      backend.statsFailure = const RealtimeMediaException(
        RealtimeMediaErrorCode.frameRejected,
        'private-native-payload',
      );
      clock.elapse(const Duration(seconds: 5));
      clock.flushMicrotasks();
      expect(events, hasLength(1));
      expect(events.single.kind, ScreenShareMediaEventKind.encoderFailed);
      expect(events.single.operationId, 'operation-a');
      expect(
        logger.messages,
        contains('Screen-share media send failed: frameRejected'),
      );
      expect(logger.messages.join(), isNot(contains('private-native-payload')));
      unawaited(subscription.cancel());
      clock.flushMicrotasks();
      var disposed = false;
      unawaited(coordinator.dispose().then((_) => disposed = true));
      clock.flushMicrotasks();
      expect(disposed, isTrue);
      final reads = backend.statsReads;
      clock.elapse(const Duration(seconds: 10));
      expect(backend.statsReads, reads);
    });
  });

  test('samples receive progress only while the endpoint is owned', () {
    fakeAsync((clock) {
      final logger = _MediaHealthLogger();
      final coordinator = _coordinator(
        backend,
        capabilities,
        session,
        logger: logger,
      );
      unawaited(
        coordinator
            .prepare(capture: false)
            .then(
              (_) => coordinator.port.startViewer(
                operationId: 'operation-a',
                realtimeId: realtimeId,
                generation: 7,
              ),
            ),
      );
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 5));
      clock.flushMicrotasks();
      expect(backend.statsReads, 1);
      expect(
        logger.messages.single,
        contains('Screen-share media receive progress:'),
      );
      unawaited(
        coordinator.port.stop(
          operationId: 'operation-a',
          realtimeId: realtimeId,
          generation: 7,
        ),
      );
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 10));
      expect(backend.statsReads, 1);
      unawaited(coordinator.dispose());
      clock.flushMicrotasks();
    });
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

  test('Windows capture keeps the selected native catalog token', () async {
    final platform = _RecordingWindowsPlatform(sources: [source]);
    final windowsBackend = WindowsRealtimeMediaBackend(
      endpointBackend: _NativeOwnerBackend(),
      platform: platform,
    );
    // Native enumeration replaces all catalog tokens, even for the same display.
    capabilities.sources = [
      ScreenCaptureSource(
        id: ScreenCaptureSourceId('display:new-generation'),
        kind: ScreenCaptureSourceKind.display,
        label: 'Display 1',
      ),
    ];
    final coordinator = AppScreenShareMediaCoordinator(
      session: session,
      resources: AppRealtimeMediaResources(
        backend: windowsBackend,
        sessionFactory: AppRealtimeMediaSessionFactory(backend: windowsBackend),
      ),
      capabilities: capabilities,
      source: source,
    );
    await coordinator.prepare(capture: true);
    await coordinator.port.startCapture(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );
    expect(platform.capturedSource, same(source));
    expect(capabilities.listCalls, 0);
    await coordinator.dispose();
  });

  test('owned endpoint can stop after native token is cleared', () async {
    final coordinator = _coordinator(backend, capabilities, session);
    await coordinator.prepare(capture: false);
    await coordinator.port.startViewer(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );
    session.mediaToken = null;
    await coordinator.port.stop(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );
    expect(coordinator.remoteSurface, isNull);
    expect(
      backend.operations.where((operation) => operation == 'release:1'),
      hasLength(1),
    );
    await coordinator.dispose();
  });

  _testSharedWidgets(
    'accepted invitation fails when transport ends before media is ready',
    (tester) async {
      session.state = RealtimeSessionState.negotiating;
      await tester.pumpWidget(_routeApp(backend, session, capabilities));
      await tester.pumpAndSettle();
      session.emitConsent(_incomingConsent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept screen share'));
      await tester.pumpAndSettle();
      expect(find.text('Screen share accepted'), findsOneWidget);
      session.mediaToken = null;
      session.publishState(RealtimeSessionState.failed, generation: 7);
      await tester.pumpAndSettle();
      expect(find.text('Screen sharing failed'), findsOneWidget);
      expect(backend.operations, isEmpty);
      expect(
        session.sentConsents.last.decision,
        RealtimeConsentDecision.cancel,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  _testSharedWidgets(
    'transport loss releases active media and busy admission',
    (tester) async {
      final arbitration = AppScreenSharePeerArbitrationRegistry();
      addTearDown(arbitration.dispose);
      arbitration.acquire(
        remotePeerId: session.peerId,
        initiatorPeerId: session.peerId,
        operationId: 'operation-a',
      );
      await tester.pumpWidget(
        _routeApp(
          backend,
          session,
          capabilities,
          arguments: AppScreenShareRouteArguments(
            session: session,
            localPeerId: 'peer-local',
            arbitration: arbitration,
          ),
        ),
      );
      await tester.pumpAndSettle();
      session.emitConsent(_incomingConsent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept screen share'));
      await tester.pumpAndSettle();
      expect(arbitration.isBusy, isTrue);
      session.mediaToken = null;
      session.publishState(RealtimeSessionState.stopped, generation: 7);
      await tester.pumpAndSettle();
      expect(find.text('Screen sharing failed'), findsOneWidget);
      expect(arbitration.isBusy, isFalse);
      expect(
        backend.operations.where((operation) => operation == 'release:1'),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final disposing in [false, true]) {
    test(
      '${disposing ? 'dispose' : 'stop'} cancels native viewer readiness before waiting for attachment',
      () async {
        final gate = Completer<void>();
        backend.surfaceGate = gate;
        backend.afterRelease = () {
          if (!gate.isCompleted) {
            gate.completeError(
              const RealtimeMediaException(
                RealtimeMediaErrorCode.staleEndpoint,
                'Pending viewer cancelled.',
              ),
            );
          }
        };
        final coordinator = _coordinator(backend, capabilities, session);
        await coordinator.prepare(capture: false);
        final starting = coordinator.port.startViewer(
          operationId: 'operation-a',
          realtimeId: realtimeId,
          generation: 7,
        );
        final observed = expectLater(
          starting,
          throwsA(isA<RealtimeMediaException>()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(backend.operations, contains('attach-surface:1'));
        session.mediaToken = null;
        try {
          final stopped = disposing
              ? coordinator.dispose()
              : coordinator.port.stop(
                  operationId: 'operation-a',
                  realtimeId: realtimeId,
                  generation: 7,
                );
          await stopped.timeout(const Duration(seconds: 1));
          expect(
            backend.operations.where((operation) => operation == 'release:1'),
            hasLength(1),
          );
          expect(coordinator.remoteSurface, isNull);
        } finally {
          if (!gate.isCompleted) {
            gate.completeError(
              const RealtimeMediaException(
                RealtimeMediaErrorCode.staleEndpoint,
                'Fixture ended.',
              ),
            );
          }
          await observed;
          await coordinator.dispose();
        }
      },
    );
  }

  test(
    'foreign cancellation cannot invalidate capture still in preflight',
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
      Object? startFailure;
      final starting = coordinator.port
          .startCapture(
            operationId: 'operation-a',
            realtimeId: realtimeId,
            generation: 7,
          )
          .catchError((Object error) {
            startFailure = error;
          });
      await Future<void>.delayed(Duration.zero);
      final rejecting = expectLater(
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
      gate.complete();
      try {
        await rejecting;
        await starting;
        expect(startFailure, isNull);
        expect(backend.operations, contains('attach-capture:1'));
      } finally {
        await starting;
        await coordinator.dispose();
      }
    },
  );

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

  _testSharedWidgets(
    'reopening a hidden page borrows the same active endpoint',
    (tester) async {
      await tester.pumpWidget(_routeApp(backend, session, capabilities));
      await tester.pumpAndSettle();
      session.emitConsent(_incomingConsent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept screen share'));
      await tester.pumpAndSettle();
      final operation = _testSessions.current!;
      final surface = operation.media!.remoteSurface;
      final started = List<String>.of(backend.operations);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(_testSessions.pageVisible, isFalse);
      await tester.pumpWidget(_routeApp(backend, session, capabilities));
      await tester.pumpAndSettle();
      expect(_testSessions.current, same(operation));
      expect(operation.media!.remoteSurface, same(surface));
      expect(backend.operations, started);
      expect(find.text('Screen sharing active'), findsOneWidget);
      expect(_testSessions.pageVisible, isTrue);
    },
  );

  _testSharedWidgets('remote stop ends sharing after the page has closed', (
    tester,
  ) async {
    await tester.pumpWidget(_routeApp(backend, session, capabilities));
    await tester.pumpAndSettle();
    final request = _incomingConsent();
    session.emitConsent(request);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept screen share'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    final now = DateTime.now().toUtc();
    session.emitConsent(
      RealtimeConsent(
        operationId: request.operationId,
        realtimeId: request.realtimeId,
        sharedSessionInstanceId: request.sharedSessionInstanceId,
        issuedAt: now,
        expiresAt: now.add(const Duration(minutes: 1)),
        decision: RealtimeConsentDecision.cancel,
        senderPeerId: session.peerId,
        actionRevision: 2,
      ),
    );
    for (var turn = 0; turn < 8; turn++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(
      backend.operations.where((entry) => entry == 'release:1'),
      hasLength(1),
    );
    expect(_testSessions.isBusy, isFalse);
    expect(_testSessions.current, isNull);
  });

  _testSharedWidgets('hidden session provides open and explicit stop actions', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final resources = AppRealtimeMediaResources(
      backend: backend,
      sessionFactory: AppRealtimeMediaSessionFactory(backend: backend),
    );
    final arguments = AppScreenShareRouteArguments(
      session: session,
      localPeerId: 'peer-local',
      initialIncomingRequest: _incomingConsent(),
      acceptIncomingOnOpen: true,
    );
    _testSessions.open(arguments, resources, capabilities: capabilities);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (_, child) => AppScreenShareBackgroundHost(
          sessions: _testSessions,
          navigatorKey: navigator,
          child: child!,
        ),
        routes: {
          AppShellRouteNames.screenShare: (_) => AppScreenShareRouteScope(
            arguments: arguments,
            resources: resources,
            sessions: _testSessions,
            capabilities: capabilities,
          ),
        },
        home: const Scaffold(body: Text('Public fixture home')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Screen sharing is running'), findsOneWidget);
    final started = List<String>.of(backend.operations);
    await tester.tap(find.text('Open screen share'));
    await tester.pumpAndSettle();
    expect(find.text('Screen sharing active'), findsOneWidget);
    expect(find.text('Screen sharing is running'), findsNothing);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Screen sharing is running'), findsOneWidget);
    expect(backend.operations, started);
    await tester.tap(find.text('Stop screen share'));
    for (var turn = 0; turn < 8; turn++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pumpAndSettle();
    expect(find.text('Screen sharing is running'), findsNothing);
    expect(_testSessions.isBusy, isFalse);
    expect(session.sentConsents.last.decision, RealtimeConsentDecision.cancel);
  });

  _testSharedWidgets(
    'unconfirmed media cleanup stays busy until explicit retry',
    (tester) async {
      await tester.pumpWidget(_routeApp(backend, session, capabilities));
      await tester.pumpAndSettle();
      session.emitConsent(_incomingConsent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept screen share'));
      await tester.pumpAndSettle();
      final operation = _testSessions.current!;
      backend.releaseFailures = 100;
      final stopping = operation.stop();
      for (var turn = 0; turn < 12; turn++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      await stopping;
      expect(_testSessions.isBusy, isTrue);
      expect(operation.finished, isFalse);
      backend.releaseFailures = 0;
      final retrying = operation.stop();
      for (var turn = 0; turn < 12; turn++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      await retrying;
      expect(_testSessions.isBusy, isFalse);
      expect(operation.finished, isTrue);
    },
  );

  _testSharedWidgets('confirmed release finishes despite detach failure', (
    tester,
  ) async {
    await tester.pumpWidget(_routeApp(backend, session, capabilities));
    await tester.pumpAndSettle();
    session.emitConsent(_incomingConsent());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept screen share'));
    await tester.pumpAndSettle();
    final operation = _testSessions.current!;
    backend.detachFails = true;
    final request = _incomingConsent();
    final now = DateTime.now().toUtc();
    session.emitConsent(
      RealtimeConsent(
        operationId: request.operationId,
        realtimeId: request.realtimeId,
        sharedSessionInstanceId: request.sharedSessionInstanceId,
        issuedAt: now,
        expiresAt: now.add(const Duration(minutes: 1)),
        decision: RealtimeConsentDecision.cancel,
        senderPeerId: session.peerId,
        actionRevision: 2,
      ),
    );
    for (var turn = 0; turn < 12; turn++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(operation.finished, isTrue);
    expect(_testSessions.isBusy, isFalse);
  });

  _testSharedWidgets('encoder capability failure explains CPU mode', (
    tester,
  ) async {
    backend.captureFailure = const RealtimeMediaException(
      RealtimeMediaErrorCode.encoderUnavailable,
      'Selected encoder unavailable.',
    );
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
    final request = session.sentConsents.single;
    final now = DateTime.now().toUtc();
    session.emitConsent(
      RealtimeConsent(
        operationId: request.operationId,
        realtimeId: request.realtimeId,
        sharedSessionInstanceId: request.sharedSessionInstanceId,
        issuedAt: now,
        expiresAt: now.add(const Duration(minutes: 1)),
        decision: RealtimeConsentDecision.accept,
        senderPeerId: session.peerId,
        actionRevision: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Screen sharing failed'), findsOneWidget);
    expect(find.textContaining('encoderUnavailable'), findsOneWidget);
    expect(find.textContaining('CPU mode'), findsOneWidget);
  });

  _testSharedWidgets(
    'closing an active page leaves media and consent running',
    (tester) async {
      await tester.pumpWidget(_routeApp(backend, session, capabilities));
      await tester.pumpAndSettle();
      session.emitConsent(_incomingConsent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept screen share'));
      await tester.pumpAndSettle();
      final mediaBeforeClose = List<String>.of(backend.operations);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(
        session.sentConsents.map((event) => event.decision),
        isNot(contains(RealtimeConsentDecision.cancel)),
      );
      expect(backend.operations, mediaBeforeClose);
      expect(session.stopCalls, 0);
    },
  );

  _testSharedWidgets(
    'receive route initializes and disposes its borrowed scope',
    (tester) async {
      await tester.pumpWidget(_routeApp(backend, session, capabilities));
      await tester.pumpAndSettle();

      expect(find.text('Screen sharing'), findsOneWidget);
      expect(find.text('Screen sharing idle'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(backend.operations, isEmpty);
    },
  );

  _testSharedWidgets(
    'explicit stop awaits peer cancellation before session release',
    (tester) async {
      final client = _LeaseClient();
      await tester.pumpWidget(
        _routeApp(
          backend,
          session,
          capabilities,
          arguments: AppScreenShareRouteArguments(
            session: session,
            localPeerId: 'peer-local',
            sessionLease: AppScreenShareSessionLease(
              client: client,
              session: session,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      session.emitConsent(_incomingConsent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept screen share'));
      await tester.pumpAndSettle();
      final cancellation = Completer<void>();
      session.cancelGate = cancellation;
      final stopping = _testSessions.current!.stop();
      await tester.pump();
      expect(
        session.sentConsents.last.decision,
        RealtimeConsentDecision.cancel,
      );
      expect(session.stopCalls, 0);
      expect(client.releases, 0);
      cancellation.complete();
      for (var turn = 0; turn < 3; turn++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      await tester.pumpAndSettle();
      await stopping;
      expect(session.stopCalls, 1);
      expect(client.releases, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  _testSharedWidgets('explicit stop bounds an unresponsive peer cancellation', (
    tester,
  ) async {
    final client = _LeaseClient();
    await tester.pumpWidget(
      _routeApp(
        backend,
        session,
        capabilities,
        arguments: AppScreenShareRouteArguments(
          session: session,
          localPeerId: 'peer-local',
          sessionLease: AppScreenShareSessionLease(
            client: client,
            session: session,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    session.emitConsent(_incomingConsent());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept screen share'));
    await tester.pumpAndSettle();
    final cancellation = Completer<void>();
    session.cancelGate = cancellation;
    final stopping = _testSessions.current!.stop();
    await tester.pump(const Duration(seconds: 4));
    expect(session.stopCalls, 0);
    expect(client.releases, 0);
    await tester.pump(const Duration(seconds: 1));
    for (var turn = 0; turn < 3; turn++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pumpAndSettle();
    await stopping;
    expect(session.stopCalls, 1);
    expect(client.releases, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    cancellation.complete();
    await tester.pumpAndSettle();
    expect(session.stopCalls, 1);
    expect(client.releases, 1);
  });

  _testSharedWidgets('send route can start an outgoing consent operation', (
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

  _testSharedWidgets('route renders typed initialization failures', (
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

  _testSharedWidgets(
    'route renders a missing native token as a typed failure',
    (tester) async {
      final noTokenSession = _FakeRealtimeSession(
        realtimeId: realtimeId,
        peerId: 'peer-remote',
        generation: 7,
      )..mediaToken = null;
      addTearDown(noTokenSession.close);

      await tester.pumpWidget(_routeApp(backend, noTokenSession, capabilities));
      await tester.pumpAndSettle();
      expect(find.textContaining('backendFailure'), findsOneWidget);
    },
  );

  _testSharedWidgets(
    'route fails closed when platform ownership is unsupported',
    (tester) async {
      await tester.pumpWidget(_routeApp(backend, session, null));
      await tester.pumpAndSettle();

      expect(find.textContaining('driverUnavailable'), findsOneWidget);
    },
  );

  _testSharedWidgets(
    'incoming route exposes explicit accept and reject actions',
    (tester) async {
      await tester.pumpWidget(_routeApp(backend, session, capabilities));
      await tester.pumpAndSettle();

      session.emitConsent(_incomingConsent());
      await tester.pumpAndSettle();
      expect(find.text('Accept screen share'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);

      await tester.tap(find.text('Accept screen share'));
      await tester.pumpAndSettle();
      expect(find.text('Screen sharing active'), findsOneWidget);
      expect(
        session.sentConsents.last.decision,
        RealtimeConsentDecision.accept,
      );
      expect(backend.operations, contains('start:receive'));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(backend.operations, isNot(contains('release:1')));
    },
  );

  _testSharedWidgets(
    'received portrait video retains its native aspect ratio',
    (tester) async {
      backend.statsSnapshot = RealtimeMediaStats(width: 1080, height: 2424);
      await tester.pumpWidget(
        _routeApp(
          backend,
          session,
          capabilities,
          presenter: const _FixtureVideoPresenter(),
        ),
      );
      await tester.pumpAndSettle();
      session.emitConsent(_incomingConsent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept screen share'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      final displayed = tester.getSize(
        find.byKey(const ValueKey('fixture-video')),
      );
      expect(displayed.width / displayed.height, closeTo(1080 / 2424, 0.001));
      final mediaOperations = List<String>.of(backend.operations);
      await tester.tap(find.byTooltip('Rotate view'));
      await tester.pump();
      expect(
        tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
        2424 / 1080,
      );
      await tester.tap(find.byTooltip('Enter fullscreen'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Screen sharing active'), findsOneWidget);
      expect(backend.operations, mediaOperations);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  _testSharedWidgets(
    'busy admission prevents a second viewer before native allocation',
    (tester) async {
      final arbitration = AppScreenSharePeerArbitrationRegistry();
      addTearDown(arbitration.dispose);
      arbitration.acquire(
        remotePeerId: session.peerId,
        initiatorPeerId: session.peerId,
        operationId: 'operation-a',
      );
      arbitration.acquire(
        remotePeerId: 'occupied-peer',
        initiatorPeerId: 'peer-local',
        operationId: 'live',
      );
      arbitration.activate(
        remotePeerId: 'occupied-peer',
        initiatorPeerId: 'peer-local',
        operationId: 'live',
      );
      await tester.pumpWidget(
        _routeApp(
          backend,
          session,
          capabilities,
          arguments: AppScreenShareRouteArguments(
            session: session,
            localPeerId: 'peer-local',
            arbitration: arbitration,
          ),
        ),
      );
      await tester.pumpAndSettle();
      session.emitConsent(_incomingConsent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept screen share'));
      await tester.pumpAndSettle();
      expect(backend.operations, isEmpty);
      expect(find.text('Screen sharing failed'), findsOneWidget);
      expect(arbitration.isBusy, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  _testSharedWidgets(
    'stopping releases busy ownership while the result page remains open',
    (tester) async {
      final arbitration = AppScreenSharePeerArbitrationRegistry();
      addTearDown(arbitration.dispose);
      arbitration.acquire(
        remotePeerId: session.peerId,
        initiatorPeerId: session.peerId,
        operationId: 'operation-a',
      );
      await tester.pumpWidget(
        _routeApp(
          backend,
          session,
          capabilities,
          arguments: AppScreenShareRouteArguments(
            session: session,
            localPeerId: 'peer-local',
            arbitration: arbitration,
          ),
        ),
      );
      await tester.pumpAndSettle();
      session.emitConsent(_incomingConsent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept screen share'));
      await tester.pumpAndSettle();
      expect(arbitration.isBusy, isTrue);
      await tester.tap(find.text('Stop screen share'));
      await tester.pumpAndSettle();
      expect(find.byType(AppScreenShareRouteScope), findsOneWidget);
      expect(find.text('Screen sharing cancelled'), findsOneWidget);
      expect(arbitration.isBusy, isFalse);
      expect(
        backend.operations.where((operation) => operation == 'release:1'),
        hasLength(1),
      );
      expect(
        arbitration.acquire(
          remotePeerId: 'next-peer',
          initiatorPeerId: 'peer-local',
          operationId: 'next',
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  _testSharedWidgets(
    'initialization failure releases claimed invitation admission',
    (tester) async {
      final arbitration = AppScreenSharePeerArbitrationRegistry();
      addTearDown(arbitration.dispose);
      arbitration.acquire(
        remotePeerId: session.peerId,
        initiatorPeerId: session.peerId,
        operationId: 'operation-a',
      );
      arbitration.activate(
        remotePeerId: session.peerId,
        initiatorPeerId: session.peerId,
        operationId: 'operation-a',
      );
      session.mediaToken = null;
      await tester.pumpWidget(
        _routeApp(
          backend,
          session,
          capabilities,
          arguments: AppScreenShareRouteArguments(
            session: session,
            localPeerId: 'peer-local',
            operationId: 'operation-a',
            arbitration: arbitration,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Screen sharing unavailable'), findsOneWidget);
      expect(arbitration.isBusy, isFalse);
      expect(backend.operations, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  _testSharedWidgets(
    'CPU route freezes the choice into native receive identity',
    (tester) async {
      await tester.pumpWidget(
        _routeApp(
          backend,
          session,
          capabilities,
          arguments: AppScreenShareRouteArguments(
            session: session,
            localPeerId: 'peer-local',
            codecMode: RealtimeMediaCodecMode.cpu,
          ),
        ),
      );
      await tester.pumpAndSettle();
      session.emitConsent(_incomingConsent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept screen share'));
      await tester.pumpAndSettle();
      expect(backend.identities.single.codecMode, RealtimeMediaCodecMode.cpu);
      expect(find.text('Screen sharing active'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(backend.operations, isNot(contains('release:1')));
    },
  );

  _testSharedWidgets('incoming route can reject without creating media', (
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
  AppRemoteVideoPresenter? presenter,
}) => MaterialApp(
  home: AppScreenShareRouteScope(
    sessions: _testSessions,
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
    presenter: presenter,
  ),
);

AppScreenShareMediaCoordinator _coordinator(
  _RecordingMediaBackend backend,
  _RecordingCapabilities capabilities,
  _FakeRealtimeSession session, {
  ScreenCaptureSource? source,
  AppLogger? logger,
}) => AppScreenShareMediaCoordinator(
  session: session,
  resources: AppRealtimeMediaResources(
    backend: backend,
    sessionFactory: AppRealtimeMediaSessionFactory(backend: backend),
    logger: logger,
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

final class _NativeOwnerBackend extends _RecordingMediaBackend
    implements RealtimeMediaNativeOwnerBackend {
  @override
  Future<RealtimeMediaNativeOwnerToken> openNativeOwner({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async => RealtimeMediaNativeOwnerToken('1');
  @override
  Future<void> closeNativeOwner({
    required RealtimeMediaNativeOwnerToken token,
    required RealtimeMediaEndpointIdentity identity,
  }) async {}
}

class _RecordingMediaBackend implements RealtimeMediaBackend {
  final List<String> operations = <String>[];
  final List<RealtimeMediaEndpointIdentity> identities = [];
  int _nextEndpoint = 0;
  Completer<void>? startGate;
  Completer<void>? surfaceGate;
  void Function()? afterRelease;
  void Function()? afterAttach;
  Object? statsFailure;
  Object? captureFailure;
  int releaseFailures = 0;
  bool detachFails = false;
  int statsReads = 0;
  RealtimeMediaStats statsSnapshot = RealtimeMediaStats();

  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity identity,
  ) async {
    final gate = startGate;
    if (gate != null) await gate.future;
    final id = RealtimeMediaEndpointId('${++_nextEndpoint}');
    operations.add('start:${identity.direction.name}');
    identities.add(identity);
    return id;
  }

  @override
  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  }) async {
    operations.add('attach-capture:${endpointId.value}');
    if (captureFailure != null) throw captureFailure!;
    afterAttach?.call();
  }

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('attach-surface:${endpointId.value}');
    final pending = surfaceGate;
    if (pending != null) await pending.future;
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
    if (detachFails) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleEndpoint,
        'Native endpoint was already detached.',
      );
    }
  }

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('release:${endpointId.value}');
    if (releaseFailures > 0) {
      releaseFailures--;
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native cleanup not confirmed.',
      );
    }
    afterRelease?.call();
  }

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    statsReads++;
    final failure = statsFailure;
    if (failure != null) throw failure;
    return statsSnapshot;
  }
}

final class _MediaHealthLogger implements AppLogger {
  final messages = <String>[];
  @override
  void log(LogRecord record) => messages.add(record.message);
  @override
  AppLogger scope(String name) => this;
}

final class _FixtureVideoPresenter implements AppRemoteVideoPresenter {
  const _FixtureVideoPresenter();
  @override
  Widget build(BuildContext context, RemoteVideoSurface surface) =>
      const ColoredBox(key: ValueKey('fixture-video'), color: Colors.blue);
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
  RealtimeSnapshot? get currentSnapshot => _snapshot;
  RealtimeSnapshot? _snapshot;
  final _snapshots = StreamController<RealtimeSnapshot>.broadcast();

  @override
  Stream<RealtimeSnapshot> get snapshots => _snapshots.stream;

  final StreamController<RealtimeConsent> _consents;

  @override
  Stream<RealtimeConsent> get consentEvents => _consents.stream;

  final List<RealtimeConsent> sentConsents = <RealtimeConsent>[];
  Completer<void>? cancelGate;
  int stopCalls = 0;

  @override
  Future<SdkResult<void>> sendConsent(RealtimeConsent consent) async {
    sentConsents.add(consent);
    if (consent.decision == RealtimeConsentDecision.cancel) {
      await cancelGate?.future;
    }
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> start() async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> stop() async {
    stopCalls++;
    state = RealtimeSessionState.stopped;
    return const SdkSuccess<void>(null);
  }

  void replaceGeneration(int generation) {
    mediaToken = RealtimeSessionToken(
      realtimeId: realtimeId,
      peerId: peerId,
      generation: generation,
    );
  }

  void emitConsent(RealtimeConsent consent) => _consents.add(consent);

  void publishState(RealtimeSessionState next, {int? generation}) {
    state = next;
    final snapshot = RealtimeSnapshot(
      realtimeId: realtimeId,
      peerId: peerId,
      state: next,
      revision: ++revision,
      generation: generation ?? this.generation,
      sharedSessionInstanceId: sharedSessionInstanceId,
    );
    _snapshot = snapshot;
    _snapshots.add(snapshot);
  }

  Future<void> close() async {
    await _consents.close();
    await _snapshots.close();
  }
}

final class _LeaseClient implements RealtimeClient {
  int releases = 0;
  final released = Completer<void>();
  @override
  Future<void> releaseSession(RealtimeSession session) async {
    releases++;
    released.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected client call: ${invocation.memberName}',
  );
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
  ScreenCaptureSource? capturedSource;

  @override
  Future<List<ScreenCaptureSource>> listCaptureSources() async => sources;

  @override
  Future<void> startCapture({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {
    capturedSource = source;
  }

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

// The App owner deliberately outlives the tested widget tree. Release it
// inside WidgetTest's zone before its pending-timer invariant is checked.
void _testSharedWidgets(String description, WidgetTesterCallback body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      var closed = false;
      final closing = _testSessions.close().whenComplete(() => closed = true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      for (var turn = 0; turn < 20 && !closed; turn++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(closed, isTrue, reason: 'App-owned sharing must finish shutdown');
      await closing;
    }
  });
}
