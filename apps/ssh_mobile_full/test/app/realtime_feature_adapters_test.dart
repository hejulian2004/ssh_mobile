import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

import 'package:ssh_mobile/app/realtime_feature_adapters.dart';
import 'package:ssh_mobile/app/realtime_media_feature_adapters.dart';

void main() {
  const realtimeId = '00112233445566778899aabbccddeeff';

  test(
    'start queue success followed by native failure completes as failure',
    () async {
      final gateway = _FakeRealtimeGateway();
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final startFuture = session.start();
      await _pump();
      final commandId = gateway.lastStartCommandId!;
      gateway.emitCommandResult(
        commandId: commandId,
        accepted: false,
        error: const NativeNetworkError(
          code: 8,
          message: 'relay unavailable',
          operation: 'start_realtime_session',
        ),
      );

      final result = await startFuture;
      expect(result, isA<SdkFailure<void>>());
      expect(
        (result as SdkFailure<void>).error.code,
        NetworkErrorCode.relayError,
      );
      expect(session.state, RealtimeSessionState.failed);
      await client.dispose();
    },
  );

  test(
    'queue rejection returns immediately without waiting for a result',
    () async {
      final gateway = _FakeRealtimeGateway(
        startStatus: NativeOperationStatus.stopped,
      );
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final result = await session.start();

      expect(result, isA<SdkFailure<void>>());
      expect(
        (result as SdkFailure<void>).error.code,
        NetworkErrorCode.cancelled,
      );
      expect(gateway.lastStartCommandId, isNotNull);
      await client.dispose();
    },
  );

  test('native queue failure maps to an IO error', () async {
    final gateway = _FakeRealtimeGateway(
      startStatus: NativeOperationStatus.failure,
    );
    final backend = AppRealtimeSessionBackend(
      networkRuntime: _FakeNetworkRuntime(gateway),
    );
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: realtimeId,
      peerId: 'peer-a',
    );

    final result = await session.start();

    expect(result, isA<SdkFailure<void>>());
    expect((result as SdkFailure<void>).error.code, NetworkErrorCode.ioError);
    await client.dispose();
  });

  test('gateway open failure is surfaced and can be retried', () async {
    final gateway = _FakeRealtimeGateway();
    final runtime = _FakeNetworkRuntime(gateway, openError: StateError('open'));
    final backend = AppRealtimeSessionBackend(networkRuntime: runtime);

    await expectLater(
      backend.start(realtimeId: realtimeId, peerId: 'peer-a'),
      throwsA(isA<StateError>()),
    );
    await backend.dispose();
  });

  test(
    'start completion does not advance state before native state events',
    () async {
      final gateway = _FakeRealtimeGateway();
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final startFuture = session.start();
      await _pump();
      gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
      expect(await startFuture, isA<SdkSuccess<void>>());
      expect(session.state, RealtimeSessionState.starting);

      gateway.emitState(NativeRealtimeSessionState.negotiating);
      gateway.emitState(NativeRealtimeSessionState.connected);
      await _pump();
      expect(session.state, RealtimeSessionState.connected);
      await client.dispose();
    },
  );

  test('stop command completion waits for the native closed state', () async {
    final gateway = _FakeRealtimeGateway();
    final backend = AppRealtimeSessionBackend(
      networkRuntime: _FakeNetworkRuntime(gateway),
      commandResultTimeout: const Duration(seconds: 1),
    );
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: realtimeId,
      peerId: 'peer-a',
    );

    final startFuture = session.start();
    await _pump();
    gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
    await startFuture;
    gateway.emitState(NativeRealtimeSessionState.connected);
    await _pump();

    final stopFuture = session.stop();
    await _pump();
    gateway.emitCommandResult(commandId: gateway.lastStopCommandId!);
    expect(await stopFuture, isA<SdkSuccess<void>>());
    expect(session.state, RealtimeSessionState.connected);

    gateway.emitState(NativeRealtimeSessionState.closed);
    await _pump();
    expect(session.state, RealtimeSessionState.stopped);
    await client.dispose();
  });

  test(
    'missing command result times out and removes the pending command',
    () async {
      final gateway = _FakeRealtimeGateway();
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(milliseconds: 10),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final timedOut = await session.start();
      expect(timedOut, isA<SdkFailure<void>>());
      expect(
        (timedOut as SdkFailure<void>).error.code,
        NetworkErrorCode.timeout,
      );

      final secondStart = session.start();
      await _pump();
      gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
      expect(await secondStart, isA<SdkSuccess<void>>());
      await client.dispose();
    },
  );

  test('pending command capacity rejects new native work', () async {
    final gateway = _FakeRealtimeGateway();
    final backend = AppRealtimeSessionBackend(
      networkRuntime: _FakeNetworkRuntime(gateway),
      maxPendingCommands: 1,
      commandResultTimeout: const Duration(seconds: 1),
    );
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: realtimeId,
      peerId: 'peer-a',
    );

    final startFuture = session.start();
    await _pump();
    final rejectedStop = await session.stop();
    expect(rejectedStop, isA<SdkFailure<void>>());
    expect(
      (rejectedStop as SdkFailure<void>).error.code,
      NetworkErrorCode.ioError,
    );

    gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
    expect(await startFuture, isA<SdkSuccess<void>>());
    await client.dispose();
  });

  test(
    'dispose cancels pending commands and ignores late native results',
    () async {
      final gateway = _FakeRealtimeGateway();
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final startFuture = session.start();
      await _pump();
      final commandId = gateway.lastStartCommandId!;
      await client.dispose();

      final result = await startFuture;
      expect(result, isA<SdkFailure<void>>());
      expect(
        (result as SdkFailure<void>).error.code,
        NetworkErrorCode.cancelled,
      );
      expect(session.state, RealtimeSessionState.stopped);

      gateway.emitCommandResult(commandId: commandId);
      gateway.emitState(NativeRealtimeSessionState.connected);
      await _pump();
      expect(session.state, RealtimeSessionState.stopped);
    },
  );

  test('native snapshot maps to SDK snapshot with revision', () async {
    final gateway = _FakeRealtimeGateway();
    final backend = AppRealtimeSessionBackend(
      networkRuntime: _FakeNetworkRuntime(gateway),
      commandResultTimeout: const Duration(seconds: 1),
    );
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: realtimeId,
      peerId: 'peer-a',
    );

    // start() 打开 gateway 并订阅原生事件，之后快照才能被路由。
    final startFuture = session.start();
    await _pump();
    gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
    await startFuture;

    gateway.emitSnapshot(NativeRealtimeSessionState.connected, revision: 7);
    await _pump();

    expect(session.state, RealtimeSessionState.connected);
    expect(session.revision, 7);
    await client.dispose();
  });

  test('native state event carries signaling revision', () async {
    final gateway = _FakeRealtimeGateway();
    final backend = AppRealtimeSessionBackend(
      networkRuntime: _FakeNetworkRuntime(gateway),
      commandResultTimeout: const Duration(seconds: 1),
    );
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: realtimeId,
      peerId: 'peer-a',
    );

    final startFuture = session.start();
    await _pump();
    gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
    await startFuture;

    gateway.emitState(NativeRealtimeSessionState.connected, revision: 3);
    await _pump();

    expect(session.state, RealtimeSessionState.connected);
    expect(session.revision, 3);
    await client.dispose();
  });

  test('native error maps retry disposition and retry-after seconds', () async {
    final gateway = _FakeRealtimeGateway();
    final backend = AppRealtimeSessionBackend(
      networkRuntime: _FakeNetworkRuntime(gateway),
      commandResultTimeout: const Duration(seconds: 1),
    );
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: realtimeId,
      peerId: 'peer-a',
    );

    final startFuture = session.start();
    await _pump();
    gateway.emitCommandResult(
      commandId: gateway.lastStartCommandId!,
      accepted: false,
      error: const NativeNetworkError(
        code: 12,
        message: 'credential expired',
        operation: 'start_realtime_session',
        retryDisposition: NativeRetryDisposition.refreshCredentialThenRetry,
        retryAfterSeconds: 30,
      ),
    );

    final result = await startFuture;
    expect(result, isA<SdkFailure<void>>());
    final error = (result as SdkFailure<void>).error;
    expect(error.code, NetworkErrorCode.credentialExpired);
    expect(error.retryDisposition, RetryDisposition.refreshCredentialThenRetry);
    expect(error.retryAfterSeconds, 30);
    await client.dispose();
  });

  test(
    'failed state and snapshot events preserve structured native errors',
    () async {
      final gateway = _FakeRealtimeGateway();
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final startFuture = session.start();
      await _pump();
      gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
      await startFuture;
      const error = NativeNetworkError(
        code: 7,
        message: 'peer unavailable',
        operation: 'start_realtime_session',
        retryDisposition: NativeRetryDisposition.retryWithBackoff,
        retryAfterSeconds: 4,
      );

      final stateEventFuture = backend.events
          .where((event) => event is RealtimeSessionStateChangedEvent)
          .cast<RealtimeSessionStateChangedEvent>()
          .first;
      gateway.emitState(
        NativeRealtimeSessionState.failed,
        error: error,
        revision: 8,
      );
      await _pump();
      expect(session.state, RealtimeSessionState.failed);
      final stateEvent = await stateEventFuture;
      expect(stateEvent.error?.code, NetworkErrorCode.natError);
      expect(stateEvent.error?.retryAfterSeconds, 4);

      final snapshotEventFuture = backend.events
          .where((event) => event is RealtimeSnapshotBackendEvent)
          .cast<RealtimeSnapshotBackendEvent>()
          .first;
      gateway.emitSnapshot(
        NativeRealtimeSessionState.failed,
        revision: 9,
        error: error,
      );
      await _pump();
      expect(session.revision, 9);
      final snapshotEvent = await snapshotEventFuture;
      expect(snapshotEvent.snapshot.error?.message, 'peer unavailable');
      await client.dispose();
    },
  );

  test('snapshot before session exists is ignored', () async {
    final gateway = _FakeRealtimeGateway();
    final backend = AppRealtimeSessionBackend(
      networkRuntime: _FakeNetworkRuntime(gateway),
      commandResultTimeout: const Duration(seconds: 1),
    );
    final client = RealtimeClientImpl(backend: backend);
    // 快照先于 session 创建到达：SDK coordinator 忽略未知 session 事件。
    gateway.emitSnapshot(NativeRealtimeSessionState.connected, revision: 1);
    await _pump();

    final session = client.createSession(
      realtimeId: realtimeId,
      peerId: 'peer-a',
    );
    expect(session.state, RealtimeSessionState.idle);
    expect(session.revision, 0);
    await client.dispose();
  });

  test(
    'out-of-order revisioned snapshot through the adapter keeps the newer state',
    () async {
      final gateway = _FakeRealtimeGateway();
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final startFuture = session.start();
      await _pump();
      gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
      await startFuture;

      // A newer revisioned snapshot lands first, then an older revisioned
      // state event arrives late: the stale event must not roll the session
      // back to negotiating (ADR-029 reconciliation).
      gateway.emitSnapshot(NativeRealtimeSessionState.connected, revision: 6);
      await _pump();
      gateway.emitState(NativeRealtimeSessionState.negotiating, revision: 4);
      await _pump();

      expect(session.state, RealtimeSessionState.connected);
      expect(session.revision, 6);
      await client.dispose();
    },
  );

  test(
    'start-stop-start resets the revision baseline so a fresh connection applies',
    () async {
      final gateway = _FakeRealtimeGateway();
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      // First generation reaches connected at revision 2.
      final firstStart = session.start();
      await _pump();
      gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
      await firstStart;
      gateway.emitState(
        NativeRealtimeSessionState.negotiating,
        revision: 1,
        generation: 7,
      );
      gateway.emitState(
        NativeRealtimeSessionState.connected,
        revision: 2,
        generation: 7,
      );
      await _pump();
      expect(session.state, RealtimeSessionState.connected);
      expect(session.revision, 2);

      // Stop -> native closed at revision 3.
      final stopFuture = session.stop();
      await _pump();
      gateway.emitCommandResult(commandId: gateway.lastStopCommandId!);
      await stopFuture;
      gateway.emitState(
        NativeRealtimeSessionState.closed,
        revision: 3,
        generation: 7,
      );
      await _pump();
      expect(session.state, RealtimeSessionState.stopped);
      expect(session.revision, 3);

      // Fresh start() begins a new native connection generation whose
      // signaling revision restarts from a low value: the client must reset
      // its revision baseline, otherwise revisions 1/2 are mistaken for stale
      // events against the previous 3 and the session never reconnects.
      final secondStart = session.start();
      await _pump();
      gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
      await secondStart;
      gateway.emitState(
        NativeRealtimeSessionState.negotiating,
        revision: 1,
        generation: 8,
      );
      await _pump();
      expect(session.state, RealtimeSessionState.negotiating);
      expect(session.revision, 1);
      gateway.emitState(
        NativeRealtimeSessionState.connected,
        revision: 2,
        generation: 8,
      );
      await _pump();
      expect(session.state, RealtimeSessionState.connected);
      expect(session.revision, 2);
      await client.dispose();
    },
  );

  test(
    'native generation becomes the media token and rejects stale events',
    () async {
      final gateway = _FakeRealtimeGateway();
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final startFuture = session.start();
      await _pump();
      gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
      await startFuture;
      gateway.emitState(
        NativeRealtimeSessionState.connected,
        revision: 3,
        generation: 7,
      );
      await _pump();

      expect(session.generation, 7);
      expect(
        session.mediaToken,
        const RealtimeSessionToken(
          realtimeId: realtimeId,
          peerId: 'peer-a',
          generation: 7,
        ),
      );

      gateway.emitState(
        NativeRealtimeSessionState.failed,
        revision: 99,
        generation: 6,
      );
      await _pump();
      expect(session.state, RealtimeSessionState.connected);
      expect(session.generation, 7);
      await client.dispose();
    },
  );

  test('native consent adapter encodes and queues typed metadata', () async {
    final gateway = _ConsentRealtimeGateway();
    final backend = AppRealtimeSessionBackend(
      networkRuntime: _FakeNetworkRuntime(gateway),
      commandResultTimeout: const Duration(seconds: 1),
    );
    final consent = _testConsent();

    final resultFuture = backend.sendConsent(
      peerId: 'peer-a',
      consent: consent,
    );
    await _pump();

    expect(gateway.consentRealtimeId, consent.realtimeId);
    expect(gateway.consentPeerId, 'peer-a');
    expect(gateway.consentRevision, 1);
    expect(gateway.consentPayload, isNotNull);
    expect(gateway.consentPayload, isNotEmpty);

    gateway.emitCommandResult(commandId: gateway.lastConsentCommandId!);
    expect(await resultFuture, isA<SdkSuccess<void>>());
    await backend.dispose();
  });

  test('legacy gateway reports consent capability failure', () async {
    final backend = AppRealtimeSessionBackend(
      networkRuntime: _FakeNetworkRuntime(_FakeRealtimeGateway()),
    );

    final result = await backend.sendConsent(
      peerId: 'peer-a',
      consent: _testConsent(),
    );

    expect(result, isA<SdkFailure<void>>());
    expect(
      (result as SdkFailure<void>).error.code,
      NetworkErrorCode.invalidArgument,
    );
    await backend.dispose();
  });

  test('native consent signal maps to the typed SDK backend event', () async {
    final gateway = _FakeRealtimeGateway();
    final backend = AppRealtimeSessionBackend(
      networkRuntime: _FakeNetworkRuntime(gateway),
    );
    final startFuture = backend.start(realtimeId: realtimeId, peerId: 'peer-a');
    await _pump();
    gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
    await startFuture;

    final eventFuture = backend.events
        .where((event) => event is RealtimeConsentBackendEvent)
        .cast<RealtimeConsentBackendEvent>()
        .first;
    gateway.emitConsent(_nativeTestConsent());
    final event = await eventFuture;

    expect(event.consent.operationId, 'operation-a');
    expect(event.consent.generation, 7);
    expect(event.consent.decision, RealtimeConsentDecision.request);
    expect(event.consent.purpose, RealtimeConsentPurpose.screenShare);
    expect(event.consent.media, RealtimeConsentMedia.screenVideo);
    expect(event.consent.actionRevision, 1);
    await backend.dispose();
  });

  for (final status in <NativeOperationStatus>[
    NativeOperationStatus.staleGeneration,
    NativeOperationStatus.staleEndpoint,
    NativeOperationStatus.duplicateEndpoint,
    NativeOperationStatus.directionMismatch,
    NativeOperationStatus.driverUnavailable,
  ]) {
    test('native media $status fails the controller closed', () async {
      final gateway = _FakeRealtimeGateway(mediaCreateStatus: status);
      final backend = AppRealtimeMediaBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
      );
      final controller = RealtimeMediaSessionController(
        backend: backend,
        realtimeId: realtimeId,
        peerId: 'peer-a',
        generation: 7,
      );

      await expectLater(
        controller.start(RealtimeMediaDirection.send),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            isNot(RealtimeMediaErrorCode.backendFailure),
          ),
        ),
      );
      expect(controller.state, RealtimeMediaSessionState.failed);
      await controller.stop();
    });
  }

  test(
    'native release status remains typed through the media adapter',
    () async {
      final gateway = _FakeRealtimeGateway(
        mediaReleaseStatus: NativeOperationStatus.staleEndpoint,
      );
      final controller = RealtimeMediaSessionController(
        backend: AppRealtimeMediaBackend(
          networkRuntime: _FakeNetworkRuntime(gateway),
        ),
        realtimeId: realtimeId,
        peerId: 'peer-a',
        generation: 7,
      );
      final endpoint = await controller.start(RealtimeMediaDirection.send);

      await expectLater(
        controller.release(endpoint),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.staleEndpoint,
          ),
        ),
      );
      expect(endpoint.state, RealtimeMediaEndpointState.released);
      await controller.stop();
    },
  );

  test(
    'native owner bridge validates tokens and preserves identity metadata',
    () async {
      final gateway = _FakeRealtimeGateway(
        mediaOwnerOpenResult: NativeRealtimeMediaOwnerOpenResult(
          status: NativeOperationStatus.success,
          token: NativeRealtimeMediaOwnerToken(88),
        ),
      );
      final adapter = AppRealtimeMediaBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
      );
      final identity = RealtimeMediaEndpointIdentity(
        realtimeId: realtimeId,
        peerId: 'peer-a',
        generation: 7,
        direction: RealtimeMediaDirection.send,
      );
      final endpoint = await adapter.start(identity);
      final owner = await adapter.openNativeOwner(
        endpointId: endpoint,
        identity: identity,
      );

      expect(owner.value, '88');
      await adapter.closeNativeOwner(token: owner, identity: identity);
      await adapter.release(endpointId: endpoint, identity: identity);

      await expectLater(
        adapter.closeNativeOwner(
          token: RealtimeMediaNativeOwnerToken('0'),
          identity: identity,
        ),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.invalidArgument,
          ),
        ),
      );
    },
  );

  test(
    'native owner close failure remains typed through the adapter',
    () async {
      final gateway = _FakeRealtimeGateway(
        mediaOwnerOpenResult: NativeRealtimeMediaOwnerOpenResult(
          status: NativeOperationStatus.success,
          token: NativeRealtimeMediaOwnerToken(88),
        ),
        mediaOwnerCloseStatus: NativeOperationStatus.staleEndpoint,
      );
      final adapter = AppRealtimeMediaBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
      );
      final identity = RealtimeMediaEndpointIdentity(
        realtimeId: realtimeId,
        peerId: 'peer-a',
        generation: 7,
        direction: RealtimeMediaDirection.send,
      );
      final endpoint = await adapter.start(identity);
      final owner = await adapter.openNativeOwner(
        endpointId: endpoint,
        identity: identity,
      );

      await expectLater(
        adapter.closeNativeOwner(token: owner, identity: identity),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.staleEndpoint,
          ),
        ),
      );
      await adapter.release(endpointId: endpoint, identity: identity);
    },
  );

  test('unsupported Phase 2 platform operations fail closed', () async {
    final adapter = AppRealtimeMediaBackend(
      networkRuntime: _FakeNetworkRuntime(_FakeRealtimeGateway()),
    );
    final endpoint = RealtimeMediaEndpointId('77');
    final identity = RealtimeMediaEndpointIdentity(
      realtimeId: realtimeId,
      peerId: 'peer-a',
      generation: 7,
      direction: RealtimeMediaDirection.receive,
    );
    final source = ScreenCaptureSource(
      id: ScreenCaptureSourceId('display:1'),
      kind: ScreenCaptureSourceKind.display,
    );

    expect(
      () => adapter.attachCaptureSource(
        endpointId: endpoint,
        identity: identity,
        source: source,
      ),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.backendFailure,
        ),
      ),
    );
    expect(
      () => adapter.attachRemoteVideoSurface(
        endpointId: endpoint,
        identity: identity,
      ),
      throwsA(isA<RealtimeMediaException>()),
    );
    expect(
      () => adapter.readStats(endpointId: endpoint, identity: identity),
      throwsA(isA<RealtimeMediaException>()),
    );
    await expectLater(
      adapter.release(
        endpointId: RealtimeMediaEndpointId('not-a-native-id'),
        identity: identity,
      ),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.invalidArgument,
        ),
      ),
    );
  });

  for (final entry in <(NativeOperationStatus, RealtimeMediaErrorCode)>[
    (
      NativeOperationStatus.invalidArgument,
      RealtimeMediaErrorCode.invalidArgument,
    ),
    (
      NativeOperationStatus.unknownSession,
      RealtimeMediaErrorCode.unknownSession,
    ),
    (NativeOperationStatus.peerMismatch, RealtimeMediaErrorCode.peerMismatch),
    (NativeOperationStatus.frameRejected, RealtimeMediaErrorCode.frameRejected),
    (NativeOperationStatus.stopped, RealtimeMediaErrorCode.sessionReleased),
    (NativeOperationStatus.failure, RealtimeMediaErrorCode.backendFailure),
  ]) {
    test('native status ${entry.$1} remains typed', () async {
      final adapter = AppRealtimeMediaBackend(
        networkRuntime: _FakeNetworkRuntime(
          _FakeRealtimeGateway(mediaCreateStatus: entry.$1),
        ),
      );
      await expectLater(
        adapter.start(
          RealtimeMediaEndpointIdentity(
            realtimeId: realtimeId,
            peerId: 'peer-a',
            generation: 7,
            direction: RealtimeMediaDirection.send,
          ),
        ),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            entry.$2,
          ),
        ),
      );
    });
  }

  test(
    'successful native endpoint creation without an ID fails closed',
    () async {
      final adapter = AppRealtimeMediaBackend(
        networkRuntime: _FakeNetworkRuntime(
          _FakeRealtimeGateway(mediaCreateReturnsNoEndpoint: true),
        ),
      );

      await expectLater(
        adapter.start(
          RealtimeMediaEndpointIdentity(
            realtimeId: realtimeId,
            peerId: 'peer-a',
            generation: 7,
            direction: RealtimeMediaDirection.send,
          ),
        ),
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

  test(
    'generation token survives native replacement and stale start fails',
    () async {
      final gateway = _FakeRealtimeGateway();
      final sessionBackend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: sessionBackend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );
      final startFuture = session.start();
      await _pump();
      gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
      await startFuture;
      gateway.emitState(
        NativeRealtimeSessionState.connected,
        revision: 1,
        generation: 7,
      );
      await _pump();

      // Native has replaced generation 7 with generation 8 before the delayed
      // endpoint acquisition reaches the registry. The old token is immutable;
      // native compares the expected generation and returns staleGeneration.
      gateway.mediaCurrentGeneration = 8;
      final controller = AppRealtimeMediaSessionFactory(
        backend: AppRealtimeMediaBackend(
          networkRuntime: _FakeNetworkRuntime(gateway),
        ),
      ).create(session);
      await expectLater(
        controller.start(RealtimeMediaDirection.receive),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.staleGeneration,
          ),
        ),
      );
      expect(gateway.lastMediaGeneration, 7);
      expect(controller.state, RealtimeMediaSessionState.failed);
      await controller.stop();
      await client.dispose();
    },
  );

  test('AppRuntime media resources preserve the shared adapter pair', () {
    final backend = AppRealtimeMediaBackend(
      networkRuntime: _FakeNetworkRuntime(_FakeRealtimeGateway()),
    );
    final factory = AppRealtimeMediaSessionFactory(backend: backend);
    final resources = AppRealtimeMediaResources(
      backend: backend,
      sessionFactory: factory,
    );

    expect(resources.backend, same(backend));
    expect(resources.sessionFactory, same(factory));
  });
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

RealtimeConsent _testConsent({
  RealtimeConsentDecision decision = RealtimeConsentDecision.request,
}) {
  final issued = DateTime.utc(2030, 1, 1, 12);
  return RealtimeConsent(
    operationId: 'operation-a',
    realtimeId: '00112233445566778899aabbccddeeff',
    generation: 7,
    issuedAt: issued,
    expiresAt: issued.add(const Duration(minutes: 1)),
    decision: decision,
    senderPeerId: 'peer-a',
    actionRevision: 1,
  );
}

NativeScreenShareConsent _nativeTestConsent() => NativeScreenShareConsent(
  schemaVersion: 1,
  operationId: 'operation-a',
  realtimeId: '00112233445566778899aabbccddeeff',
  generation: 7,
  issuedAtMs: DateTime.utc(2030, 1, 1, 12).millisecondsSinceEpoch,
  expiresAtMs: DateTime.utc(2030, 1, 1, 12, 1).millisecondsSinceEpoch,
  decision: NativeScreenShareConsentDecision.request,
  senderPeerId: 'peer-a',
  purpose: NativeScreenShareConsentPurpose.screenShare,
  media: NativeScreenShareMediaKind.screenVideo,
  requiresAcceptance: true,
  actionRevision: 1,
);

final class _FakeNetworkRuntime implements NetworkRuntime {
  _FakeNetworkRuntime(this.gateway, {this.openError});

  final NetworkRealtimeGateway gateway;
  final Object? openError;

  @override
  NetworkRuntimeState get state => NetworkRuntimeState.ready;

  @override
  NetworkRuntimeDiagnostics get diagnostics => NetworkRuntimeDiagnostics(
    state: state,
    activeConnections: 0,
    nativeHandles: 1,
    readyCapabilities: const <NetworkCapability>[NetworkCapability.realtime],
  );

  @override
  Future<void> ensureCapability(NetworkCapability capability) async {}

  @override
  bool isCapabilityReady(NetworkCapability capability) => true;

  @override
  Future<NetworkCommandGateway> openCommandGateway() =>
      throw UnimplementedError();

  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() async {
    final error = openError;
    if (error != null) throw error;
    return gateway;
  }

  @override
  Future<void> dispose() async {}
}

class _FakeRealtimeGateway implements NetworkRealtimeGateway {
  _FakeRealtimeGateway({
    this.startStatus = NativeOperationStatus.success,
    this.mediaCreateStatus = NativeOperationStatus.success,
    this.mediaReleaseStatus = NativeOperationStatus.success,
    this.mediaOwnerOpenResult = const NativeRealtimeMediaOwnerOpenResult(
      status: NativeOperationStatus.driverUnavailable,
    ),
    this.mediaOwnerCloseStatus = NativeOperationStatus.success,
    this.mediaCreateReturnsNoEndpoint = false,
  });

  final StreamController<NativeNetworkEvent> _events =
      StreamController<NativeNetworkEvent>.broadcast();
  final NativeOperationStatus startStatus;
  final NativeOperationStatus mediaCreateStatus;
  final NativeOperationStatus mediaReleaseStatus;
  final NativeRealtimeMediaOwnerOpenResult mediaOwnerOpenResult;
  final NativeOperationStatus mediaOwnerCloseStatus;
  final bool mediaCreateReturnsNoEndpoint;
  int? mediaCurrentGeneration;
  int _sequence = 0;
  String? lastStartCommandId;
  String? lastStopCommandId;
  int? lastMediaGeneration;

  @override
  Stream<NativeNetworkEvent> get events => _events.stream;

  @override
  NativeCommandTicket start({
    required String realtimeId,
    required String peerId,
  }) {
    final commandId = 'start-${++_sequence}';
    lastStartCommandId = commandId;
    return NativeCommandTicket(commandId: commandId, queueStatus: startStatus);
  }

  @override
  NativeCommandTicket stop({required String realtimeId}) {
    final commandId = 'stop-${++_sequence}';
    lastStopCommandId = commandId;
    return NativeCommandTicket(
      commandId: commandId,
      queueStatus: NativeOperationStatus.success,
    );
  }

  @override
  NativeRealtimeMediaEndpointCreateResult createMediaEndpoint({
    required String realtimeId,
    required String peerId,
    required int generation,
    required NativeRealtimeMediaDirection direction,
  }) {
    lastMediaGeneration = generation;
    final status =
        mediaCurrentGeneration != null && generation != mediaCurrentGeneration
        ? NativeOperationStatus.staleGeneration
        : mediaCreateStatus;
    return NativeRealtimeMediaEndpointCreateResult(
      status: status,
      endpointId: status.isSuccess && !mediaCreateReturnsNoEndpoint
          ? NativeRealtimeMediaEndpointId(77)
          : null,
    );
  }

  @override
  NativeOperationStatus releaseMediaEndpoint(
    NativeRealtimeMediaEndpointId endpointId,
  ) => mediaReleaseStatus;

  @override
  NativeRealtimeMediaOwnerOpenResult openMediaOwner({
    required NativeRealtimeMediaEndpointId endpointId,
    required String realtimeId,
    required String peerId,
    required int generation,
    required NativeRealtimeMediaDirection direction,
  }) => mediaOwnerOpenResult;

  @override
  NativeOperationStatus closeMediaOwner(NativeRealtimeMediaOwnerToken token) =>
      mediaOwnerCloseStatus;

  void emitCommandResult({
    required String commandId,
    bool accepted = true,
    NativeNetworkError? error,
  }) {
    _events.add(
      NativeCommandResultEvent(
        eventId: 'event-$commandId',
        timestampMs: 1,
        protocolVersion: 2,
        commandId: commandId,
        accepted: accepted,
        error: error,
      ),
    );
  }

  void emitState(
    NativeRealtimeSessionState state, {
    int? revision,
    int generation = 1,
    NativeNetworkError? error,
  }) {
    _events.add(
      NativeRealtimeStateChangedEvent(
        eventId: 'state-${++_sequence}',
        timestampMs: 1,
        protocolVersion: 2,
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: state,
        revision: revision ?? _sequence,
        generation: generation,
        error: error,
      ),
    );
  }

  void emitSnapshot(
    NativeRealtimeSessionState state, {
    required int revision,
    int generation = 1,
    NativeNetworkError? error,
  }) {
    _events.add(
      NativeRealtimeSnapshotEvent(
        eventId: 'snapshot-${++_sequence}',
        timestampMs: 1,
        protocolVersion: 2,
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: state,
        revision: revision,
        generation: generation,
        error: error,
      ),
    );
  }

  void emitConsent(NativeScreenShareConsent consent) {
    _events.add(
      NativeRealtimeSignalEvent(
        eventId: 'consent-${++_sequence}',
        timestampMs: 1,
        protocolVersion: 2,
        realtimeId: consent.realtimeId,
        peerId: consent.senderPeerId,
        kind: NativeRealtimeSignalKind.screenShareConsent,
        revision: 1,
        payload: Uint8List(0),
        consent: consent,
      ),
    );
  }
}

final class _ConsentRealtimeGateway extends _FakeRealtimeGateway
    implements NetworkRealtimeConsentGateway {
  int _consentSequence = 0;
  String? lastConsentCommandId;
  String? consentRealtimeId;
  String? consentPeerId;
  int? consentRevision;
  Uint8List? consentPayload;

  @override
  NativeCommandTicket sendScreenShareConsent({
    required String realtimeId,
    required String peerId,
    required int revision,
    required Uint8List payload,
  }) {
    consentRealtimeId = realtimeId;
    consentPeerId = peerId;
    consentRevision = revision;
    consentPayload = Uint8List.fromList(payload);
    final commandId = 'consent-${++_consentSequence}';
    lastConsentCommandId = commandId;
    return NativeCommandTicket(
      commandId: commandId,
      queueStatus: NativeOperationStatus.success,
    );
  }
}
