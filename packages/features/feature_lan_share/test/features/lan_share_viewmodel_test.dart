import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('LanDiscoveredPeer preserves the independent native transfer port', () {
    final peer = LanDiscoveredPeer(
      deviceId: 'peer-1',
      alias: 'Peer 1',
      ip: '192.168.1.5',
      controlPort: 5432,
      advertisedNativePort: 6543,
      deviceType: LanDeviceType.mobile,
      os: 'android',
      lastSeen: DateTime.utc(2026, 8, 25),
    );

    final decoded = LanDiscoveredPeer.fromJson(peer.toJson());

    expect(decoded.controlPort, 5432);
    expect(decoded.advertisedNativePort, 6543);
  });

  test(
    'LanShareViewModel forgetDevice fails closed without coordinator',
    () async {
      final security = FakeLanSecurityService();
      final settings = FakeLanShareSettings();
      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: security,
        storageService: FakeLanStorageService(),
        transferService: FakeLanTransferService(),
        historyDao: FakeLanHistoryDao(),
        appSettings: settings,
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );

      final result = await viewModel.forgetDevice('test-device-id');
      expect(result, isA<NetworkFailure<void>>());
      final failure = result as NetworkFailure<void>;
      expect(failure.error.code, NetworkErrorCode.noRoute);
      expect(failure.error.operation, NetworkOperation.removePeer);

      viewModel.dispose();
      settings.dispose();
    },
  );

  test(
    'text and clipboard fail closed when E2E capability is absent',
    () async {
      final security = _MissingKeySecurityService();
      final transfer = LanTransferService(
        currentDeviceId: 'sender-1',
        securityService: security,
        storageService: FakeLanStorageService(),
      );
      final settings = FakeLanShareSettings();
      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: security,
        storageService: FakeLanStorageService(),
        transferService: transfer,
        historyDao: FakeLanHistoryDao(),
        appSettings: settings,
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );
      final device = LanDiscoveredPeer(
        deviceId: 'peer-1',
        alias: 'Peer 1',
        ip: '192.168.1.5',
        controlPort: 5432,
        deviceType: LanDeviceType.mobile,
        os: 'android',
        lastSeen: DateTime.now(),
      );

      final results = (
        await viewModel.sendText(device, 'hello'),
        await viewModel.sendClipboard(device, 'clipboard'),
      );
      expect(results.$1, isA<NetworkFailure<void>>());
      expect(
        (results.$1 as NetworkFailure<void>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
      expect(results.$2, isA<NetworkFailure<void>>());

      viewModel.dispose();
      settings.dispose();
      await transfer.close();
    },
  );

  test(
    'setRelayAuthorization routes through coordinator and updates projection',
    () async {
      final store = LanPeerTrustStore();
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
        peerTrustStore: store,
      );
      final settings = FakeLanShareSettings();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );

      final record = LanPeerTrustRecord(
        deviceId: 'peer-1',
        certificateFingerprint:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        inboundAccessToken: 'inbound',
        outboundAccessToken: 'outbound',
        x25519PublicKey: Uint8List(32),
        networkIdentityPublicKey: Uint8List(32),
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: true,
          relay: false,
        ),
        createdAt: DateTime.utc(2026),
      );
      await store.save(record);
      await registry.reconcilePersistedTrust(record);

      final transfer = LanTransferService(
        currentDeviceId: 'sender-1',
        securityService: security,
        storageService: FakeLanStorageService(),
      );

      final coordinator = LanNativeTransferCoordinator(
        transferService: transfer,
        networkFacade: facade,
        policyPort: registry,
        storageService: FakeLanStorageService(),
      );

      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: security,
        storageService: FakeLanStorageService(),
        transferService: transfer,
        nativeTransferCoordinator: coordinator,
        historyDao: FakeLanHistoryDao(),
        appSettings: settings,
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );

      await viewModel.initialize();

      expect(
        viewModel.peerStateFor('peer-1')?.trust?.authorization.relay,
        isFalse,
      );

      final grantResult = await viewModel.setRelayAuthorization('peer-1', true);
      expect(grantResult, isA<NetworkSuccess<void>>());
      expect(
        viewModel.peerStateFor('peer-1')?.trust?.authorization.relay,
        isTrue,
      );

      final revokeResult = await viewModel.setRelayAuthorization(
        'peer-1',
        false,
      );
      expect(revokeResult, isA<NetworkSuccess<void>>());
      expect(
        viewModel.peerStateFor('peer-1')?.trust?.authorization.relay,
        isFalse,
      );

      viewModel.dispose();
      await coordinator.dispose();
      await transfer.close();
      await store.dispose();
      settings.dispose();
    },
  );

  test(
    'toggling relay authorization repeatedly does not leak trustStore subscriptions',
    () async {
      final store = LanPeerTrustStore();
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
        peerTrustStore: store,
      );
      final settings = FakeLanShareSettings();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );

      final record = LanPeerTrustRecord(
        deviceId: 'peer-1',
        certificateFingerprint:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        inboundAccessToken: 'inbound',
        outboundAccessToken: 'outbound',
        x25519PublicKey: Uint8List(32),
        networkIdentityPublicKey: Uint8List(32),
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: true,
          relay: false,
        ),
        createdAt: DateTime.utc(2026),
      );
      await store.save(record);
      await registry.reconcilePersistedTrust(record);

      final transfer = LanTransferService(
        currentDeviceId: 'sender-1',
        securityService: security,
        storageService: FakeLanStorageService(),
      );

      final coordinator = LanNativeTransferCoordinator(
        transferService: transfer,
        networkFacade: facade,
        policyPort: registry,
        storageService: FakeLanStorageService(),
      );

      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: security,
        storageService: FakeLanStorageService(),
        transferService: transfer,
        nativeTransferCoordinator: coordinator,
        historyDao: FakeLanHistoryDao(),
        appSettings: settings,
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );

      await viewModel.initialize();

      // Toggle relay 10 times
      for (var i = 0; i < 10; i++) {
        await viewModel.setRelayAuthorization('peer-1', i.isEven);
      }

      int notifyCount = 0;
      viewModel.addListener(() {
        notifyCount++;
      });

      // Saving one update to trustStore directly should trigger stream change
      // and cause exactly ONE notifyListeners call, rather than 10+ duplicate callbacks.
      await store.save(
        record.copyWith(
          authorization: const PeerRouteAuthorization(
            localDirect: true,
            relay: true,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(notifyCount, 1);

      viewModel.dispose();
      await coordinator.dispose();
      await transfer.close();
      await store.dispose();
      settings.dispose();
    },
  );

  test(
    'deleteMessage deletes sandbox file and clears database record',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'lan-vm-delete-msg-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final sandboxDir = Directory('${tempDir.path}/sandbox')..createSync();
      final outsideDir = Directory('${tempDir.path}/outside')..createSync();

      final storage = LanStorageService(
        sandboxDirectoryProvider: () async => sandboxDir,
      );

      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.dispose);
      final historyDao = database.lanHistoryDao;

      final sandboxFile = File('${sandboxDir.path}/incoming.jpg')
        ..writeAsStringSync('img');
      final outsideFile = File('${outsideDir.path}/outgoing.jpg')
        ..writeAsStringSync('out-img');

      await historyDao.insertRecord(
        LanTransferRecordsCompanion.insert(
          id: 'msg-sandbox',
          senderId: 'peer-1',
          senderAlias: 'Peer 1',
          receiverId: 'self',
          payloadType: 'image',
          status: 'completed',
          createdAt: 1000,
          isIncoming: const Value(true),
          localPath: Value(sandboxFile.path),
        ),
      );

      await historyDao.insertRecord(
        LanTransferRecordsCompanion.insert(
          id: 'msg-outside',
          senderId: 'self',
          senderAlias: 'Self',
          receiverId: 'peer-1',
          payloadType: 'image',
          status: 'completed',
          createdAt: 2000,
          isIncoming: const Value(false),
          localPath: Value(outsideFile.path),
        ),
      );

      final settings = FakeLanShareSettings();
      addTearDown(settings.dispose);
      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: _MissingKeySecurityService(),
        storageService: storage,
        transferService: FakeLanTransferService(),
        historyDao: historyDao,
        appSettings: settings,
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );

      // Delete sandbox message -> sandbox file deleted, record deleted
      await viewModel.deleteMessage('msg-sandbox');
      expect(sandboxFile.existsSync(), isFalse);
      expect(await historyDao.getRecord('msg-sandbox'), isNull);

      // Delete outside message -> outside file retained, record deleted
      await viewModel.deleteMessage('msg-outside');
      expect(outsideFile.existsSync(), isTrue);
      expect(await historyDao.getRecord('msg-outside'), isNull);
    },
  );

  test(
    'clearHistory deletes all sandbox files and clears all database records',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'lan-vm-clear-hist-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final sandboxDir = Directory('${tempDir.path}/sandbox')..createSync();

      final storage = LanStorageService(
        sandboxDirectoryProvider: () async => sandboxDir,
      );

      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.dispose);
      final historyDao = database.lanHistoryDao;

      final file1 = File('${sandboxDir.path}/file1.bin')
        ..writeAsStringSync('f1');
      final file2 = File('${sandboxDir.path}/file2.bin')
        ..writeAsStringSync('f2');

      await historyDao.insertRecord(
        LanTransferRecordsCompanion.insert(
          id: 'msg-1',
          senderId: 'peer-1',
          senderAlias: 'Peer 1',
          receiverId: 'self',
          payloadType: 'file',
          status: 'completed',
          createdAt: 1000,
          isIncoming: const Value(true),
          localPath: Value(file1.path),
        ),
      );
      await historyDao.insertRecord(
        LanTransferRecordsCompanion.insert(
          id: 'msg-2',
          senderId: 'peer-1',
          senderAlias: 'Peer 1',
          receiverId: 'self',
          payloadType: 'file',
          status: 'completed',
          createdAt: 2000,
          isIncoming: const Value(true),
          localPath: Value(file2.path),
        ),
      );

      final settings = FakeLanShareSettings();
      addTearDown(settings.dispose);
      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: _MissingKeySecurityService(),
        storageService: storage,
        transferService: FakeLanTransferService(),
        historyDao: historyDao,
        appSettings: settings,
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );

      await viewModel.clearHistory();
      expect(file1.existsSync(), isFalse);
      expect(file2.existsSync(), isFalse);
      expect(await historyDao.getAllRecords(), isEmpty);
    },
  );

  test('pairing observation keeps the advertised native endpoint', () async {
    final discovery = LanDiscoveryService(
      currentDeviceId: 'test-device',
      currentDeviceAlias: 'Test Device',
      localAddressSelectionPort:
          const LanShareSingleCandidateLocalAddressSelection(),
    );
    final transfer = FakeLanTransferService();
    final settings = FakeLanShareSettings();
    final viewModel = LanShareViewModel(
      discoveryService: discovery,
      securityService: FakeLanSecurityService(),
      storageService: FakeLanStorageService(),
      transferService: transfer,
      historyDao: FakeLanHistoryDao(),
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
      ownsRuntime: false,
    );
    addTearDown(() async {
      viewModel.dispose();
      settings.dispose();
      await transfer.close();
      await discovery.close();
    });

    final seen = DateTime.utc(2026, 1, 1);
    discovery.registerDiscoveredPeer(
      LanDiscoveredPeer(
        deviceId: 'peer-1',
        alias: 'Windows PC',
        ip: '192.168.1.20',
        controlPort: 53317,
        advertisedNativePort: 43123,
        os: 'windows',
        lastSeen: seen,
      ),
    );
    await viewModel.initialize();

    transfer.emitObservedPeer(
      LanDiscoveredPeer(
        deviceId: 'peer-1',
        alias: 'Windows PC',
        ip: '10.0.0.8',
        controlPort: 53317,
        os: 'windows',
        lastSeen: seen,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final peer = discovery.currentDiscoveredPeers.single;
    expect(peer.ip, '192.168.1.20');
    expect(peer.advertisedNativePort, 43123);
    expect(peer.lastSeen.isAfter(seen), isTrue);

    transfer.emitObservedPeer(
      LanDiscoveredPeer(
        deviceId: 'peer-2',
        alias: 'New Phone',
        ip: '192.168.1.30',
        controlPort: 53317,
        os: 'android',
        lastSeen: seen,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final created = discovery.currentDiscoveredPeers.singleWhere(
      (candidate) => candidate.deviceId == 'peer-2',
    );
    expect(created.ip, '192.168.1.30');
    expect(created.advertisedNativePort, isNull);
  });
}

final class _MissingKeySecurityService extends Fake
    implements LanSecurityService {
  @override
  Future<Uint8List?> getPeerX25519PublicKey(String deviceId) async => null;

  @override
  Future<Uint8List?> getPeerNetworkIdentityPublicKey(String deviceId) async =>
      null;

  @override
  Future<String?> getPeerCertificateFingerprint(String deviceId) async => null;

  @override
  Future<String?> getOutboundAccessToken(String deviceId) async => 'token';

  @override
  Future<bool> isDevicePaired(
    String deviceId, {
    String? ip,
    int? port,
    String? localDeviceId,
  }) async => true;
}

final class _RecordingFacade extends Fake implements NetworkFacade {
  final List<PeerConfig> registrations = <PeerConfig>[];

  @override
  Future<NetworkResult<void>> registerPeer(PeerConfig peer) async {
    registrations.add(peer);
    return const NetworkSuccess<void>(null);
  }

  @override
  Future<NetworkResult<void>> removePeer(String peerId) async {
    return const NetworkSuccess<void>(null);
  }

  @override
  Future<NetworkResult<void>> disconnectPeer(String peerId) async {
    return const NetworkSuccess<void>(null);
  }

  @override
  Stream<SdkEvent> get events => const Stream<SdkEvent>.empty();
}
