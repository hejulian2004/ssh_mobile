import 'dart:typed_data';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'worker-generated TLS material is shared, durable and identity-bound',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final trust = LanPeerTrustStore();
      final service = LanSecurityService(
        peerTrustStore: trust,
        appOwnedX25519PrivateSeed: Uint8List(32),
      );
      try {
        final first = service.getOrCreateSecurityContext('synthetic-local');
        final second = service.getOrCreateSecurityContext('synthetic-local');
        await expectLater(
          service.getOrCreateSecurityContext('other-local'),
          throwsStateError,
        );
        expect(await second, same(await first));
        expect(
          await service.getOrCreateSecurityContext('synthetic-local'),
          same(await first),
        );
        final fingerprint = await service.getLocalCertificateFingerprint(
          'synthetic-local',
        );
        expect(fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
        final restored = LanSecurityService(
          peerTrustStore: trust,
          appOwnedX25519PrivateSeed: Uint8List(32),
        );
        expect(
          await restored.getLocalCertificateFingerprint('synthetic-local'),
          fingerprint,
        );
        await expectLater(
          service.getOrCreateSecurityContext('other-local'),
          throwsStateError,
        );
      } finally {
        await trust.dispose();
      }
    },
  );
}
