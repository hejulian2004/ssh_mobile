import 'dart:async';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const current = LanShareLocalIpv4Candidate(
    address: '192.168.1.20',
    interfaceName: 'Wi-Fi',
    interfaceIndex: 5,
  );
  const next = LanShareLocalIpv4Candidate(
    address: '10.2.0.9',
    interfaceName: 'Ethernet',
    interfaceIndex: 3,
  );

  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test(
    'valid address update preserves QR contract; stale update stops only web',
    () async {
      final candidates = _FakeCandidateSource([current, next]);
      final selector = _CountingSelector();
      final discovery = LanDiscoveryService(
        currentDeviceId: 'local-device',
        currentDeviceAlias: 'Local Device',
        localAddressSelectionPort: selector,
        localAddressCandidateSource: candidates,
      );
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
      );
      final storage = LanStorageService();
      final transfer = LanTransferService(
        currentDeviceId: 'local-device',
        securityService: security,
        storageService: storage,
        nativeTransferPortProvider: () => 62000,
      );
      addTearDown(() async {
        await discovery.close();
        await transfer.close();
        await security.peerTrustStore.dispose();
      });

      expect(
        await transfer.startListening(port: 0),
        isA<NetworkSuccess<int>>(),
      );
      expect(
        await discovery.updateWebShareAddressOverride(current.address),
        isA<NetworkSuccess<void>>(),
      );
      final start = await discovery.startWebShareServer(
        securityService: security,
        storageService: storage,
        transferService: transfer,
      );
      expect(start, isA<NetworkSuccess<String>>());

      final initialUri = Uri.parse(discovery.webShareUrl!);
      expect(initialUri.host, current.address);
      expect(initialUri.host, isNot('127.0.0.1'));
      expect(initialUri.queryParameters['deviceId'], 'local-device');
      expect(
        initialUri.queryParameters['lanPort'],
        transfer.activePort.toString(),
      );
      expect(initialUri.queryParameters['nativePort'], '62000');
      expect(initialUri.queryParameters['access'], isNotEmpty);
      expect(initialUri.queryParameters['certFingerprint'], hasLength(64));

      expect(
        await discovery.updateWebShareAddressOverride(next.address),
        isA<NetworkSuccess<void>>(),
      );
      final updatedUri = Uri.parse(discovery.webShareUrl!);
      expect(updatedUri.host, next.address);
      expect(updatedUri.queryParameters, initialUri.queryParameters);

      final ambiguous = await discovery.updateWebShareAddressOverride(null);
      expect(ambiguous, isA<NetworkFailure<void>>());
      expect(
        discovery.webShareAddressSelectionResult,
        isA<LanShareLocalAddressAmbiguous>(),
      );
      expect(discovery.isWebShareActive, isFalse);
      expect(discovery.webShareUrl, isNull);
      expect(transfer.isListening, isTrue);

      expect(
        await discovery.updateWebShareAddressOverride(current.address),
        isA<NetworkSuccess<void>>(),
      );
      expect(
        await discovery.startWebShareServer(
          securityService: security,
          storageService: storage,
          transferService: transfer,
        ),
        isA<NetworkSuccess<String>>(),
      );

      final stale = await discovery.updateWebShareAddressOverride('192.0.2.44');
      expect(stale, isA<NetworkFailure<void>>());
      expect(
        discovery.webShareAddressSelectionResult,
        isA<LanShareLocalAddressStaleOverride>(),
      );
      expect(discovery.isWebShareActive, isFalse);
      expect(discovery.webShareUrl, isNull);
      expect(transfer.isListening, isTrue);
      expect(selector.calls, 1);
    },
  );

  test(
    'address changes are serialized with start and stop operations',
    () async {
      final candidateSource = _BlockingCandidateSource([current]);
      final selector = _AlwaysUnavailableSelector();
      final discovery = LanDiscoveryService(
        currentDeviceId: 'local-device',
        currentDeviceAlias: 'Local Device',
        localAddressSelectionPort: selector,
        localAddressCandidateSource: candidateSource,
      );
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
      );
      final storage = LanStorageService();
      final transfer = LanTransferService(
        currentDeviceId: 'local-device',
        securityService: security,
        storageService: storage,
      );
      addTearDown(() async {
        await discovery.close();
        await transfer.close();
        await security.peerTrustStore.dispose();
      });

      final start = discovery.startWebShareServer(
        securityService: security,
        storageService: storage,
        transferService: transfer,
      );
      await candidateSource.firstLoadStarted.future;
      final update = discovery.updateWebShareAddressOverride(current.address);
      final stop = discovery.stopWebShareServer();
      expect(candidateSource.loadCalls, 1);

      candidateSource.releaseFirstLoad();
      expect(await start, isA<NetworkFailure<String>>());
      expect(await update, isA<NetworkSuccess<void>>());
      expect(await stop, isA<NetworkSuccess<void>>());
      expect(candidateSource.loadCalls, 2);
      expect(selector.calls, 1);
      expect(discovery.isWebShareActive, isFalse);
      expect(transfer.isListening, isFalse);
    },
  );
}

final class _FakeCandidateSource implements LanShareLocalIpv4CandidateSource {
  _FakeCandidateSource(this.candidates);

  final List<LanShareLocalIpv4Candidate> candidates;

  @override
  Future<List<LanShareLocalIpv4Candidate>> loadCandidates() async => candidates;
}

final class _CountingSelector implements LanShareLocalAddressSelectionPort {
  int calls = 0;

  @override
  Future<LanShareLocalAddressSelectionResult> selectPreferredIpv4(
    List<LanShareLocalIpv4Candidate> candidates,
  ) async {
    calls++;
    return LanShareLocalAddressAmbiguous(candidates);
  }
}

final class _AlwaysUnavailableSelector
    implements LanShareLocalAddressSelectionPort {
  int calls = 0;

  @override
  Future<LanShareLocalAddressSelectionResult> selectPreferredIpv4(
    List<LanShareLocalIpv4Candidate> candidates,
  ) async {
    calls++;
    return const LanShareLocalAddressUnavailable();
  }
}

final class _BlockingCandidateSource
    implements LanShareLocalIpv4CandidateSource {
  _BlockingCandidateSource(this.candidates);

  final List<LanShareLocalIpv4Candidate> candidates;
  final Completer<void> firstLoadStarted = Completer<void>();
  final Completer<void> _firstLoadRelease = Completer<void>();
  int loadCalls = 0;

  void releaseFirstLoad() => _firstLoadRelease.complete();

  @override
  Future<List<LanShareLocalIpv4Candidate>> loadCandidates() async {
    loadCalls++;
    if (loadCalls == 1) {
      firstLoadStarted.complete();
      await _firstLoadRelease.future;
    }
    return candidates;
  }
}
