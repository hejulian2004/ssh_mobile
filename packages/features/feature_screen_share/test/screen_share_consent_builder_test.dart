import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  final localNow = DateTime.utc(2026, 10, 23);
  RealtimeConsent build(RealtimeConsentDecision decision, DateTime expiry) =>
      buildScreenShareConsent(
        operationId: 'public-operation',
        realtimeId: '00112233445566778899aabbccddeeff',
        sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
        issuedAt: localNow,
        expiresAt: expiry,
        decision: decision,
        senderPeerId: 'public-peer',
        actionRevision: 1,
      );

  for (final decision in [
    RealtimeConsentDecision.accept,
    RealtimeConsentDecision.reject,
    RealtimeConsentDecision.cancel,
  ]) {
    test('${decision.name} bounds a future-skewed request deadline', () {
      final requestExpiry = localNow.add(
        RealtimeConsent.maxLifetime + const Duration(milliseconds: 250),
      );
      final response = build(decision, requestExpiry);
      expect(response.expiresAt, localNow.add(RealtimeConsent.maxLifetime));
      expect(response.expiresAt.isAfter(requestExpiry), isFalse);
      expect(response.isFresh(localNow), isTrue);
    });

    test('${decision.name} preserves the earlier request deadline', () {
      final expiry = localNow.add(const Duration(seconds: 45));
      expect(build(decision, expiry).expiresAt, expiry);
    });
  }

  test('an oversized request remains invalid', () {
    expect(
      () => build(
        RealtimeConsentDecision.request,
        localNow.add(RealtimeConsent.maxLifetime + const Duration(seconds: 1)),
      ),
      throwsArgumentError,
    );
  });

  test('an expired response remains invalid', () {
    expect(
      () => build(RealtimeConsentDecision.accept, localNow),
      throwsArgumentError,
    );
  });
}
