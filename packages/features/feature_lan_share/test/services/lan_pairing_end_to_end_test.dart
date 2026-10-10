import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('two LAN services complete reciprocal PIN pairing over HTTPS', () async {
    final trustStore = LanPeerTrustStore();
    final securityA = LanSecurityService(
      appOwnedX25519PrivateSeed: Uint8List.fromList(List<int>.filled(32, 1)),
      peerTrustStore: trustStore,
    );
    final securityB = LanSecurityService(
      appOwnedX25519PrivateSeed: Uint8List.fromList(List<int>.filled(32, 2)),
      peerTrustStore: trustStore,
    );
    final nativeRegistrationStarted = Completer<void>();
    final releaseNativeRegistration = Completer<void>();
    final serviceA = LanTransferService(
      currentDeviceId: 'device-a',
      securityService: securityA,
      storageService: LanStorageService(),
      networkIdentityPublicKeyProvider: () async =>
          Uint8List.fromList(List<int>.filled(32, 3)),
      onPairingCommitted: (peer) async {
        expect(peer.deviceId, 'device-b');
        nativeRegistrationStarted.complete();
        await releaseNativeRegistration.future;
      },
    );
    final serviceB = LanTransferService(
      currentDeviceId: 'device-b',
      securityService: securityB,
      storageService: LanStorageService(),
      networkIdentityPublicKeyProvider: () async =>
          Uint8List.fromList(List<int>.filled(32, 4)),
    );
    addTearDown(() async {
      await serviceA.close();
      await serviceB.close();
      await trustStore.dispose();
    });

    expect(await serviceA.startListening(port: 0), isA<NetworkSuccess<int>>());
    expect(await serviceB.startListening(port: 0), isA<NetworkSuccess<int>>());

    final pinA = securityA.generate6DigitPin();
    final pinB = securityB.generate6DigitPin();
    final peerA = _peer('device-a', serviceA.activePort, 'Device A');
    final peerB = _peer('device-b', serviceB.activePort, 'Device B');

    final first = await _runWithRealHttpClient(
      () => serviceA.sendHandshake(peerB, pinB, 'Device A'),
    );
    if (first is NetworkFailure<LanPairingHandshakeProgress>) {
      fail(
        'first handshake failed: ${first.error.code} ${first.error.message}',
      );
    }
    expect(first, isA<NetworkSuccess<LanPairingHandshakeProgress>>());
    expect(
      (first as NetworkSuccess<LanPairingHandshakeProgress>).data,
      LanPairingHandshakeProgress.waitingForPeer,
    );
    expect(await securityA.peerTrustStore.read('device-b'), isNull);
    expect(await securityB.peerTrustStore.read('device-a'), isNull);

    final secondFuture = _runWithRealHttpClient(
      () => serviceB.sendHandshake(peerA, pinA, 'Device B', isInitiator: false),
    );
    await nativeRegistrationStarted.future.timeout(const Duration(seconds: 2));
    releaseNativeRegistration.complete();
    final second = await secondFuture;
    if (second is NetworkFailure<LanPairingHandshakeProgress>) {
      fail(
        'second handshake failed: ${second.error.code} ${second.error.message}',
      );
    }
    expect(second, isA<NetworkSuccess<LanPairingHandshakeProgress>>());
    expect(
      (second as NetworkSuccess<LanPairingHandshakeProgress>).data,
      LanPairingHandshakeProgress.paired,
    );
    expect(await securityA.peerTrustStore.read('device-b'), isNotNull);
    expect(await securityB.peerTrustStore.read('device-a'), isNotNull);
  });
}

Future<T> _runWithRealHttpClient<T>(Future<T> Function() action) {
  final realOverrides = _RealHttpOverrides();
  return HttpOverrides.runZoned(
    action,
    createHttpClient: realOverrides.createHttpClient,
  );
}

LanDiscoveredPeer _peer(String deviceId, int port, String alias) {
  return LanDiscoveredPeer(
    deviceId: deviceId,
    alias: alias,
    ip: '127.0.0.1',
    controlPort: port,
    os: 'windows',
    lastSeen: DateTime.now().toUtc(),
  );
}

final class _RealHttpOverrides extends HttpOverrides {}
