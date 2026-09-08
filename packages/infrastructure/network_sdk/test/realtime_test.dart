import 'dart:async';

import 'package:test/test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  test('session exposes lifecycle and native-owned media state only', () async {
    final backend = _FakeRealtimeBackend();
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: '00112233445566778899aabbccddeeff',
      peerId: 'peer-a',
    );
    addTearDown(() async {
      await client.dispose();
    });

    expect(session.state, RealtimeSessionState.idle);
    expect(session.audioState, RealtimeAudioState.unavailable);
    expect(await session.start(), isA<SdkSuccess<void>>());
    expect(session.state, RealtimeSessionState.starting);
    expect(backend.startCalls, 1);

    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeSessionState.negotiating,
      ),
    );
    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeSessionState.connected,
      ),
    );
    backend.emit(
      const RealtimeAudioStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeAudioState.active,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.state, RealtimeSessionState.connected);
    expect(session.audioState, RealtimeAudioState.active);

    expect(await session.stop(), isA<SdkSuccess<void>>());
    expect(session.state, RealtimeSessionState.connected);
    expect(backend.stopCalls, 1);

    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeSessionState.stopped,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(session.state, RealtimeSessionState.stopped);
  });

  test(
    'client disposal stops an active native session before closing the backend',
    () async {
      final backend = _FakeRealtimeBackend();
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );

      await session.start();
      await client.dispose();

      expect(session.state, RealtimeSessionState.stopped);
      expect(backend.stopCalls, 1);
    },
  );

  test(
    'session rejects duplicate IDs and calls after client disposal',
    () async {
      final client = RealtimeClientImpl(backend: _FakeRealtimeBackend());
      client.createSession(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );

      expect(
        () => client.createSession(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-b',
        ),
        throwsStateError,
      );
      expect(
        () => client.createSession(realtimeId: 'not-an-id', peerId: 'peer-a'),
        throwsArgumentError,
      );

      await client.dispose();
      expect(
        () => client.createSession(
          realtimeId: 'ffeeddccbbaa99887766554433221100',
          peerId: 'peer-a',
        ),
        throwsA(isA<SdkClientDisposedException>()),
      );
    },
  );

  test('session applies a snapshot and records its revision', () async {
    final backend = _FakeRealtimeBackend();
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: '00112233445566778899aabbccddeeff',
      peerId: 'peer-a',
    );
    addTearDown(() => client.dispose());

    backend.emit(
      const RealtimeSnapshotBackendEvent(
        RealtimeSnapshot(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.connected,
          revision: 7,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.state, RealtimeSessionState.connected);
    expect(session.revision, 7);
  });

  test(
    'client dispatches snapshot and revision to the matching session',
    () async {
      final backend = _FakeRealtimeBackend();
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );
      addTearDown(() => client.dispose());

      backend.emit(
        const RealtimeSnapshotBackendEvent(
          RealtimeSnapshot(
            realtimeId: '00112233445566778899aabbccddeeff',
            peerId: 'peer-a',
            state: RealtimeSessionState.connected,
            revision: 5,
          ),
        ),
      );
      backend.emit(
        const RealtimeSessionStateChangedEvent(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.connected,
          revision: 6,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(session.state, RealtimeSessionState.connected);
      expect(session.revision, 6);
    },
  );

  test('client ignores snapshots for a different session peer', () async {
    final backend = _FakeRealtimeBackend();
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: '00112233445566778899aabbccddeeff',
      peerId: 'peer-a',
    );
    addTearDown(() => client.dispose());

    backend.emit(
      const RealtimeSnapshotBackendEvent(
        RealtimeSnapshot(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'other-peer',
          state: RealtimeSessionState.connected,
          revision: 9,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.state, RealtimeSessionState.idle);
    expect(session.revision, 0);
  });

  test(
    'stale revisioned state event is ignored and keeps the newer state',
    () async {
      final backend = _FakeRealtimeBackend();
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );
      addTearDown(() => client.dispose());

      backend.emit(
        const RealtimeSessionStateChangedEvent(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.connected,
          revision: 10,
        ),
      );
      backend.emit(
        const RealtimeSessionStateChangedEvent(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.negotiating,
          revision: 9,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(session.state, RealtimeSessionState.connected);
      expect(session.revision, 10);
    },
  );

  test(
    'stale revisioned failure snapshot does not override a connected session',
    () async {
      final backend = _FakeRealtimeBackend();
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );
      addTearDown(() => client.dispose());

      backend.emit(
        const RealtimeSessionStateChangedEvent(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.connected,
          revision: 10,
        ),
      );
      backend.emit(
        const RealtimeSnapshotBackendEvent(
          RealtimeSnapshot(
            realtimeId: '00112233445566778899aabbccddeeff',
            peerId: 'peer-a',
            state: RealtimeSessionState.failed,
            revision: 9,
            error: NetworkError(
              code: NetworkErrorCode.relayError,
              message: 'stale failure',
            ),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(session.state, RealtimeSessionState.connected);
      expect(session.revision, 10);
    },
  );

  test('equal revision is applied idempotently without advancing', () async {
    final backend = _FakeRealtimeBackend();
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: '00112233445566778899aabbccddeeff',
      peerId: 'peer-a',
    );
    addTearDown(() => client.dispose());

    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeSessionState.connected,
        revision: 10,
      ),
    );
    backend.emit(
      const RealtimeSnapshotBackendEvent(
        RealtimeSnapshot(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.connected,
          revision: 10,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.state, RealtimeSessionState.connected);
    expect(session.revision, 10);
  });

  test('newer revision applies and advances', () async {
    final backend = _FakeRealtimeBackend();
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: '00112233445566778899aabbccddeeff',
      peerId: 'peer-a',
    );
    addTearDown(() => client.dispose());

    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeSessionState.connected,
        revision: 10,
      ),
    );
    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeSessionState.restarting,
        revision: 11,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.state, RealtimeSessionState.restarting);
    expect(session.revision, 11);
  });

  test('stale revisioned state after stopped is ignored', () async {
    final backend = _FakeRealtimeBackend();
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: '00112233445566778899aabbccddeeff',
      peerId: 'peer-a',
    );
    addTearDown(() => client.dispose());

    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeSessionState.stopped,
        revision: 12,
      ),
    );
    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeSessionState.connected,
        revision: 11,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.state, RealtimeSessionState.stopped);
    expect(session.revision, 12);
  });

  test(
    'legacy zero-revision event applies without advancing revision',
    () async {
      final backend = _FakeRealtimeBackend();
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );
      addTearDown(() => client.dispose());

      backend.emit(
        const RealtimeSessionStateChangedEvent(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.connected,
          revision: 10,
        ),
      );
      // A legacy/unspecified event (revision omitted -> 0) still applies its
      // state but must never advance the recorded revision.
      backend.emit(
        const RealtimeSessionStateChangedEvent(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.negotiating,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(session.state, RealtimeSessionState.negotiating);
      expect(session.revision, 10);
    },
  );

  test(
    'facade realtime session routes state through the SDK coordinator',
    () async {
      final backend = _FakeRealtimeBackend();
      final client = RealtimeClientImpl(backend: backend);
      final facade = NetworkFacadeImpl(
        sessions: _StubSessionClient(),
        realtime: client,
      );
      final session = facade.createRealtimeSession(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );
      addTearDown(() async {
        await client.dispose();
        await facade.dispose();
      });

      expect(session.state, RealtimeSessionState.idle);
      expect(await session.start(), isA<SdkSuccess<void>>());
      expect(backend.startCalls, 1);

      backend.emit(
        const RealtimeSessionStateChangedEvent(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.connected,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(session.state, RealtimeSessionState.connected);
    },
  );

  test(
    'session exposes native generation without using signaling revision',
    () async {
      final backend = _FakeRealtimeBackend();
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );
      addTearDown(client.dispose);

      await session.start();
      backend.emit(
        const RealtimeSessionStateChangedEvent(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.connected,
          revision: 99,
          generation: 7,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(session.revision, 99);
      expect(session.generation, 7);
      expect(
        session.mediaToken,
        const RealtimeSessionToken(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          generation: 7,
        ),
      );
    },
  );

  test(
    'consent events are generation-bound and stale values are dropped',
    () async {
      final backend = _FakeRealtimeBackend();
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );
      addTearDown(client.dispose);
      await session.start();
      backend.emit(
        const RealtimeSessionStateChangedEvent(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.connected,
          generation: 7,
        ),
      );
      final received = <RealtimeConsent>[];
      final subscription = session.consentEvents.listen(received.add);
      addTearDown(subscription.cancel);
      final issued = DateTime.utc(2026, 1, 1, 12);
      final valid = RealtimeConsent(
        operationId: 'operation-a',
        realtimeId: '00112233445566778899aabbccddeeff',
        generation: 7,
        issuedAt: issued,
        expiresAt: issued.add(const Duration(minutes: 1)),
        decision: RealtimeConsentDecision.request,
        senderPeerId: 'peer-a',
        actionRevision: 1,
      );
      backend.emit(RealtimeConsentBackendEvent(valid));
      backend.emit(
        RealtimeConsentBackendEvent(
          RealtimeConsent(
            operationId: 'operation-b',
            realtimeId: valid.realtimeId,
            generation: 8,
            issuedAt: issued,
            expiresAt: issued.add(const Duration(minutes: 1)),
            decision: RealtimeConsentDecision.request,
            senderPeerId: 'peer-a',
            actionRevision: 1,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, [valid]);
    },
  );
}

/// Facade 测试使用的空 SessionClient 替身；Facade 仅把 Realtime 委托给注入的
/// RealtimeClient，因此 SessionClient 不需要实现具体网络调用。
final class _StubSessionClient implements SessionClient {
  @override
  Stream<SdkEvent> get events => const Stream<SdkEvent>.empty();

  @override
  Future<SdkResult<void>> start(SdkRuntimeConfig config) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> stop() async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> upsertPeer(SdkPeerConfig peer) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> removePeer(String peerId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> connect(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> disconnect(String peerId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> configureRelay(SdkRelayConfig config) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> disconnectRelay() async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<SdkTransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  }) => throw UnimplementedError('not used in this test');

  @override
  Future<SdkResult<void>> cancel(String transferId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> respondToIncoming({
    required String transferId,
    required bool accept,
  }) async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<SdkRouteSnapshot>> state(String peerId) async => SdkSuccess(
    SdkRouteSnapshot(peerId: peerId, routeType: NetworkRouteType.unspecified),
  );

  @override
  Future<void> dispose() async {}
}

final class _FakeRealtimeBackend implements RealtimeSessionBackend {
  final StreamController<RealtimeBackendEvent> _events =
      StreamController<RealtimeBackendEvent>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Stream<RealtimeBackendEvent> get events => _events.stream;

  @override
  Future<SdkResult<void>> start({
    required String realtimeId,
    required String peerId,
  }) async {
    startCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> stop({required String realtimeId}) async {
    stopCalls++;
    return const SdkSuccess<void>(null);
  }

  void emit(RealtimeBackendEvent event) => _events.add(event);

  @override
  Future<void> dispose() => _events.close();
}
