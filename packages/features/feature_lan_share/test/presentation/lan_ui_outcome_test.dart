import 'package:feature_lan_share/src/features/lan_share/viewmodels/lan_ui_outcome.dart';
import 'package:feature_lan_share/src/services/lan_share/lan_pairing_reciprocal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  test(
    'page outcome keeps retryable transfer failures without the session',
    () async {
      final outcome = await lanUiIgnored<void>(
        Future<NetworkResult<void>>.value(
          const NetworkFailure<void>(
            NetworkError(
              code: NetworkErrorCode.ioError,
              message: 'Socket write failed',
              operation: NetworkOperation.respondToIncoming,
            ),
          ),
        ),
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.failure?.kind, LanUiFailureKind.other);
      expect(outcome.failure?.retryable, isTrue);
      expect(outcome.failure?.message, 'Socket write failed');
    },
  );

  test('page outcome distinguishes storage and trust failures', () {
    final storage = lanUiFailureFrom(
      const NetworkError(
        code: NetworkErrorCode.resourceLimit,
        message: 'Insufficient storage space',
      ),
    );
    final trust = lanUiFailureFrom(
      const NetworkError(
        code: NetworkErrorCode.authenticationFailed,
        message: 'untrusted',
      ),
    );

    expect(storage.kind, LanUiFailureKind.resourceLimit);
    expect(storage.retryable, isFalse);
    expect(trust.kind, LanUiFailureKind.authenticationFailed);
    expect(trust.retryable, isFalse);
  });

  test('pairing outcome preserves the handshake progress', () async {
    final outcome = await lanUiOf<LanPairingHandshakeProgress>(
      Future<NetworkResult<LanPairingHandshakeProgress>>.value(
        const NetworkSuccess(LanPairingHandshakeProgress.paired),
      ),
    );

    expect(outcome.succeeded, isTrue);
    expect(outcome.value, LanPairingHandshakeProgress.paired);
  });
}
