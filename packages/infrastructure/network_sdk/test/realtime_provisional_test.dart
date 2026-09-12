import 'dart:async';

import 'package:network_sdk/network_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('normalized snapshots include Negotiating state events', () async {
    final backend = _ClaimBackend();
    final client = RealtimeClientImpl(backend: backend);
    addTearDown(client.dispose);
    final session = client.createSession(
      realtimeId: _realtimeId,
      peerId: 'peer-a',
    );
    final snapshots = <RealtimeSnapshot>[];
    final subscription = session.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);

    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: _realtimeId,
        peerId: 'peer-a',
        state: RealtimeSessionState.negotiating,
        generation: 7,
        sharedSessionInstanceId: _sharedId,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.currentSnapshot?.state, RealtimeSessionState.negotiating);
    expect(session.currentSnapshot?.generation, 7);
    expect(session.currentSnapshot?.sharedSessionInstanceId, _sharedId);
    expect(snapshots, hasLength(1));
    expect(snapshots.single.state, RealtimeSessionState.negotiating);
  });

  test(
    'claim pre-registers the responder before synchronous native events',
    () async {
      final backend = _ClaimBackend(emitSynchronouslyDuringClaim: true);
      final client = RealtimeClientImpl(backend: backend);
      addTearDown(client.dispose);

      final result = await client.claimIncomingSession(_offer());
      expect(result, isA<SdkSuccess<RealtimeSession>>());
      final session = (result as SdkSuccess<RealtimeSession>).data;
      await Future<void>.delayed(Duration.zero);

      expect(backend.claimedSession, same(session));
      expect(session.state, RealtimeSessionState.negotiating);
      expect(session.generation, 11);
      expect(session.sharedSessionInstanceId, _sharedId);
      expect(session.currentSnapshot?.state, RealtimeSessionState.negotiating);
    },
  );

  test('releaseSession waits for an authoritative terminal event', () async {
    final backend = _ClaimBackend();
    final client = RealtimeClientImpl(backend: backend);
    addTearDown(client.dispose);
    final first = client.createSession(
      realtimeId: _realtimeId,
      peerId: 'peer-a',
    );
    await client.releaseSession(first);
    expect(
      () => client.createSession(realtimeId: _realtimeId, peerId: 'peer-a'),
      throwsStateError,
    );

    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: _realtimeId,
        peerId: 'peer-a',
        state: RealtimeSessionState.stopped,
        generation: 13,
        sharedSessionInstanceId: _sharedId,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final replacement = client.createSession(
      realtimeId: _realtimeId,
      peerId: 'peer-a',
    );
    expect(replacement.state, RealtimeSessionState.idle);
    await client.releaseSession(first);
    expect(replacement.state, RealtimeSessionState.idle);
  });

  test('releaseSession does not wait for a command timeout', () async {
    final backend = _ClaimBackend(blockStop: true);
    final client = RealtimeClientImpl(backend: backend);
    addTearDown(client.dispose);
    final session = client.createSession(
      realtimeId: _realtimeId,
      peerId: 'peer-a',
    );
    await session.start();

    await expectLater(client.releaseSession(session), completes);
    expect(backend.stopCalled, isTrue);
    expect(
      () => client.createSession(realtimeId: _realtimeId, peerId: 'peer-a'),
      throwsStateError,
    );
  });
}

const _realtimeId = '00112233445566778899aabbccddeeff';
const _sharedId = 'ffeeddccbbaa99887766554433221100';

RealtimeIncomingSessionOffer _offer() {
  final issuedAt = DateTime.now().toUtc();
  return RealtimeIncomingSessionOffer(
    offerId: 'offer-1',
    claimToken: 'claim-token-1',
    realtimeId: _realtimeId,
    authenticatedPeerId: 'peer-a',
    sharedSessionInstanceId: _sharedId,
    bindingExpiresAt: issuedAt.add(const Duration(minutes: 1)),
    request: RealtimeConsent(
      operationId: 'operation-1',
      realtimeId: _realtimeId,
      sharedSessionInstanceId: _sharedId,
      issuedAt: issuedAt,
      expiresAt: issuedAt.add(const Duration(minutes: 1)),
      decision: RealtimeConsentDecision.request,
      senderPeerId: 'peer-a',
      actionRevision: 1,
    ),
  );
}

final class _ClaimBackend
    implements RealtimeSessionBackend, RealtimeIncomingSessionBackend {
  _ClaimBackend({
    this.emitSynchronouslyDuringClaim = false,
    this.blockStop = false,
  });

  final bool emitSynchronouslyDuringClaim;
  final bool blockStop;
  final StreamController<RealtimeBackendEvent> _events =
      StreamController<RealtimeBackendEvent>.broadcast();
  RealtimeSession? claimedSession;
  bool stopCalled = false;
  final Completer<void> _stopRelease = Completer<void>();

  @override
  Stream<RealtimeBackendEvent> get events => _events.stream;

  @override
  Future<SdkResult<void>> start({
    required String realtimeId,
    required String peerId,
  }) async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> stop({required String realtimeId}) async {
    stopCalled = true;
    if (blockStop) await _stopRelease.future;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> claimIncomingOffer({
    required RealtimeIncomingSessionOffer offer,
    required RealtimeSession session,
  }) async {
    claimedSession = session;
    if (emitSynchronouslyDuringClaim) {
      _events.add(
        const RealtimeSessionStateChangedEvent(
          realtimeId: _realtimeId,
          peerId: 'peer-a',
          state: RealtimeSessionState.negotiating,
          generation: 11,
          sharedSessionInstanceId: _sharedId,
        ),
      );
    }
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> rejectIncomingOffer(
    RealtimeIncomingSessionOffer offer,
  ) async => const SdkSuccess<void>(null);

  @override
  Future<void> discardIncomingOffer(RealtimeIncomingSessionOffer offer) async {}

  void emit(RealtimeBackendEvent event) => _events.add(event);

  @override
  Future<void> dispose() => _events.close();
}
