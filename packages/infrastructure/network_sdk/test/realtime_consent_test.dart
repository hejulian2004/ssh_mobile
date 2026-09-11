import 'package:test/test.dart';

import 'package:network_sdk/network_sdk.dart';

void main() {
  final issued = DateTime.utc(2026, 1, 1, 12);
  final expires = issued.add(const Duration(minutes: 1));

  RealtimeConsent consent({
    RealtimeConsentDecision decision = RealtimeConsentDecision.request,
  }) => RealtimeConsent(
    operationId: 'operation-a',
    realtimeId: '00112233445566778899aabbccddeeff',
    sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
    issuedAt: issued,
    expiresAt: expires,
    decision: decision,
    senderPeerId: 'peer-a',
    actionRevision: 1,
  );

  test('consent validates schema, identity and bounded expiry', () {
    final value = consent();
    expect(value.schemaVersion, 2);
    expect(value.issuedAtMs, issued.millisecondsSinceEpoch);
    expect(value.isExpired(issued), isFalse);
    expect(value.isExpired(expires), isTrue);
    expect(value.isFresh(issued), isTrue);
    expect(
      value.copyWith(decision: RealtimeConsentDecision.accept),
      isNot(equals(value)),
    );
  });

  test(
    'consent freshness rejects future issuance without using the constructor clock',
    () {
      final now = DateTime.utc(2026, 1, 1, 12);
      final futureIssued = now.add(const Duration(seconds: 31));
      final future = RealtimeConsent(
        operationId: 'operation-a',
        realtimeId: '00112233445566778899aabbccddeeff',
        sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
        issuedAt: futureIssued,
        expiresAt: futureIssued.add(const Duration(minutes: 1)),
        decision: RealtimeConsentDecision.request,
        senderPeerId: 'peer-a',
        actionRevision: 1,
      );

      expect(future.isFresh(now), isFalse);
      expect(
        future
            .copyWith(
              issuedAt: now.add(const Duration(seconds: 30)),
              expiresAt: now.add(const Duration(minutes: 2, seconds: 30)),
            )
            .isFresh(now),
        isTrue,
      );
      expect(consent().isFresh(now.add(const Duration(seconds: 30))), isTrue);
    },
  );

  test('consent rejects invalid identity, lifetime and action revision', () {
    expect(
      () => RealtimeConsent(
        operationId: 'x',
        realtimeId: 'not-a-realtime-id',
        sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
        issuedAt: issued,
        expiresAt: expires,
        decision: RealtimeConsentDecision.request,
        senderPeerId: 'peer-a',
        actionRevision: 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => RealtimeConsent(
        operationId: 'x',
        realtimeId: '00112233445566778899aabbccddeeff',
        sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
        issuedAt: issued,
        expiresAt: issued.add(const Duration(minutes: 3)),
        decision: RealtimeConsentDecision.request,
        senderPeerId: 'peer-a',
        actionRevision: 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => RealtimeConsent(
        operationId: 'x',
        realtimeId: '00112233445566778899aabbccddeeff',
        sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
        issuedAt: issued,
        expiresAt: expires,
        decision: RealtimeConsentDecision.request,
        senderPeerId: 'peer-a',
        actionRevision: 0,
      ),
      throwsArgumentError,
    );
  });

  test('consent bounds operation and sender identifiers by UTF-8 bytes', () {
    final valid = '界' * 42; // 126 UTF-8 bytes.
    final invalid = '界' * 43; // 129 UTF-8 bytes.
    expect(() => consent().copyWith(), returnsNormally);
    expect(
      () => RealtimeConsent(
        operationId: valid,
        realtimeId: '00112233445566778899aabbccddeeff',
        sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
        issuedAt: issued,
        expiresAt: expires,
        decision: RealtimeConsentDecision.request,
        senderPeerId: 'peer-a',
        actionRevision: 1,
      ),
      returnsNormally,
    );
    expect(
      () => RealtimeConsent(
        operationId: invalid,
        realtimeId: '00112233445566778899aabbccddeeff',
        sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
        issuedAt: issued,
        expiresAt: expires,
        decision: RealtimeConsentDecision.request,
        senderPeerId: 'peer-a',
        actionRevision: 1,
      ),
      throwsArgumentError,
    );
  });
}
