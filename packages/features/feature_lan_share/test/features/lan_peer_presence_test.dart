import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'metadata cleanup failure returns a typed result after revoking trust',
    () async {
      final fixture = await _Fixture.create(failMetadataDelete: true);
      addTearDown(fixture.close);
      await fixture.vm.initialize();
      fixture.discovery.registerDiscoveredPeer(_peer(DateTime.now()));
      await Future<void>.delayed(Duration.zero);
      final result = await fixture.vm.forgetDevice('peer');
      expect(result, isA<NetworkFailure<void>>());
      expect(
        (result as NetworkFailure<void>).error.code,
        NetworkErrorCode.ioError,
      );
      expect(await fixture.store.read('peer'), isNull);
      expect(fixture.vm.peerStateFor('peer'), isNull);
    },
  );
  test(
    'binary commands persist native results and chat cleanup does not revoke trust',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      await fixture.store.setRelayAuthorization('peer', true);
      await fixture.vm.initialize();
      final directory = await Directory.systemTemp.createTemp('lan-vm-file-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/payload.bin')
        ..writeAsStringSync('payload');
      final result = await fixture.vm.sendFile(
        peerId: 'peer',
        filePath: file.path,
      );
      expect(result, isA<NetworkSuccess<TransferSession>>());
      final session = (result as NetworkSuccess<TransferSession>).data;
      fixture.facade.controller.add(
        TransferCompleted(
          eventId: 'completed',
          timestamp: DateTime.now(),
          transferId: session.transferId,
          peerId: 'peer',
          localPath: file.path,
        ),
      );
      await fixture.vm.shutdown();
      expect(
        (await fixture.database.lanHistoryDao.getRecord(
          session.transferId,
        ))!.status,
        'completed',
      );
      await fixture.coordinator.dispose();
      expect(
        await fixture.vm.sendFile(peerId: 'peer', filePath: file.path),
        isA<NetworkFailure<TransferSession>>(),
      );
      final records = await fixture.database.lanHistoryDao.getAllRecords();
      expect(
        records.any((record) => record.failureReason == 'cancelled'),
        isTrue,
      );
      await fixture.vm.clearChatHistory('peer');
      expect(await fixture.database.lanHistoryDao.getAllRecords(), isEmpty);
      expect(await fixture.store.read('peer'), isNotNull);
    },
  );
  test(
    'Relay presence supplies online evidence independently from pairing authorization',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      await fixture.vm.initialize();
      fixture.facade.controller.add(
        PeerPresenceChanged(
          eventId: 'online',
          timestamp: DateTime.now(),
          peerId: 'peer',
          generation: 1,
          state: PeerPresenceState.online,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final online = fixture.vm.peerStateFor('peer')!;
      expect(online.isOnline, isTrue);
      expect(online.lastOnlineAt, isNotNull);
      expect(online.trust!.authorization.relay, isFalse);
      fixture.facade.controller.add(
        PeerStateChanged(
          eventId: 'relay-connected',
          timestamp: DateTime.now(),
          peerId: 'peer',
          state: PeerConnectionState.connected,
          routeType: NetworkRouteType.relay,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      fixture.facade.controller.add(
        RelayStateChanged(
          eventId: 'offline',
          timestamp: DateTime.now(),
          state: RelayConnectionState.disconnected,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.vm.peerStateFor('peer')!.isOffline, isTrue);
      fixture.facade.controller.add(
        PeerStateChanged(
          eventId: 'direct-connected',
          timestamp: DateTime.now(),
          peerId: 'peer',
          state: PeerConnectionState.connected,
          routeType: NetworkRouteType.quicDirect,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.vm.peerStateFor('peer')!.isOnline, isTrue);
    },
  );
  test(
    'paired offline devices retain alias and the latest observed online time across restart',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final seen = DateTime.utc(2026, 10, 12, 2);
      fixture.discovery.registerDiscoveredPeer(_peer(seen));
      await fixture.vm.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(fixture.vm.peerStateFor('peer')!.isOnline, isTrue);
      expect(fixture.vm.peerStateFor('peer')!.lastOnlineAt, seen);
      fixture.discovery.registerDiscoveredPeer(
        _peer(seen.add(const Duration(minutes: 1))),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        fixture.vm.peerStateFor('peer')!.lastOnlineAt,
        seen,
        reason: 'Heartbeats must not change the latest came-online time.',
      );
      fixture.discovery.removeDiscoveredPeer('peer');
      await fixture.vm.shutdown();
      final saved =
          (await fixture.database.lanPairingMetadataDao.getAll()).single;
      expect(saved.alias, 'My phone');
      expect(saved.lastSeen, seen.millisecondsSinceEpoch);
      expect(saved.ip, isNull);
      expect(saved.port, isNull);
      await fixture.vm.initialize();
      final offline = fixture.vm.peerStateFor('peer')!;
      expect(offline.isOffline, isTrue);
      expect(offline.displayAlias, 'My phone');
      expect(offline.lastOnlineAt, seen);
      final latest = seen.add(const Duration(minutes: 2));
      fixture.discovery.registerDiscoveredPeer(_peer(latest));
      await Future<void>.delayed(Duration.zero);
      expect(fixture.vm.peerStateFor('peer')!.lastOnlineAt, latest);
      fixture.discovery.registerDiscoveredPeer(_peer(seen));
      await Future<void>.delayed(Duration.zero);
      expect(fixture.vm.peerStateFor('peer')!.lastOnlineAt, latest);
    },
  );

  test(
    'explicit unpair removes the list entry and metadata; rediscovery remains unpaired',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      await fixture.vm.initialize();
      fixture.discovery.registerDiscoveredPeer(_peer(DateTime.now()));
      await Future<void>.delayed(Duration.zero);
      expect(
        await fixture.vm.forgetDevice('peer'),
        isA<NetworkSuccess<void>>(),
      );
      expect(fixture.vm.peerStateFor('peer'), isNull);
      expect(await fixture.store.read('peer'), isNull);
      expect(await fixture.database.lanPairingMetadataDao.getAll(), isEmpty);
      expect(fixture.facade.removed, ['peer']);
      fixture.discovery.registerDiscoveredPeer(_peer(DateTime.now()));
      await Future<void>.delayed(Duration.zero);
      final rediscovered = fixture.vm.peerStateFor('peer')!;
      expect(rediscovered.isOnline, isTrue);
      expect(rediscovered.isTrusted, isFalse);
    },
  );

  test(
    'incoming transfer terminal states publish one notification each',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      await fixture.vm.initialize();
      final events = <LanNotificationEvent>[];
      final subscription = fixture.vm.notificationEvents.listen(events.add);
      addTearDown(subscription.cancel);
      await fixture.database.lanHistoryDao.insertRecord(
        LanTransferRecordsCompanion.insert(
          id: 'tx-in',
          senderId: 'peer',
          senderAlias: 'Phone',
          receiverId: 'test-device',
          payloadType: 'file',
          status: 'transferring',
          createdAt: 1,
          isIncoming: const Value(true),
        ),
      );
      await fixture.database.lanHistoryDao.insertRecord(
        LanTransferRecordsCompanion.insert(
          id: 'tx-out',
          senderId: 'test-device',
          senderAlias: 'Me',
          receiverId: 'peer',
          payloadType: 'file',
          status: 'transferring',
          createdAt: 2,
          isIncoming: const Value(false),
        ),
      );

      fixture.facade.controller.add(
        TransferProgress(
          eventId: 'progress',
          timestamp: DateTime.utc(2026),
          transferId: 'tx-in',
          peerId: 'peer',
          bytesTransferred: 1,
          totalBytes: 4,
        ),
      );
      await pumpEventQueue();
      expect(events, isEmpty);

      fixture.facade.controller.add(
        TransferCompleted(
          eventId: 'done',
          timestamp: DateTime.utc(2026),
          transferId: 'tx-in',
          peerId: 'peer',
          localPath: '',
        ),
      );
      await pumpEventQueue();
      expect(events.map((event) => event.kind), [
        LanNotificationKind.transferSucceeded,
      ]);
      expect(events.single.displayName, 'Phone');

      fixture.facade.controller.add(
        TransferFailed(
          eventId: 'fail',
          timestamp: DateTime.utc(2026),
          transferId: 'tx-in',
          peerId: 'peer',
          error: const NetworkError(
            code: NetworkErrorCode.ioError,
            message: 'disk',
            operation: NetworkOperation.respondToIncoming,
          ),
        ),
      );
      fixture.facade.controller.add(
        TransferCompleted(
          eventId: 'out',
          timestamp: DateTime.utc(2026),
          transferId: 'tx-out',
          peerId: 'peer',
          localPath: '',
        ),
      );
      await pumpEventQueue();
      expect(events.map((event) => event.kind), [
        LanNotificationKind.transferSucceeded,
        LanNotificationKind.transferFailed,
      ]);
    },
  );
}

LanDiscoveredPeer _peer(DateTime seen) => LanDiscoveredPeer(
  deviceId: 'peer',
  alias: 'My phone',
  ip: '127.0.0.1',
  controlPort: 55001,
  advertisedNativePort: 55002,
  os: 'android',
  deviceType: LanDeviceType.mobile,
  lastSeen: seen,
);

final class _Fixture {
  _Fixture(
    this.database,
    this.store,
    this.facade,
    this.coordinator,
    this.discovery,
    this.transfer,
    this.settings,
    this.vm,
  );
  final LanShareDatabase database;
  final LanPeerTrustStore store;
  final _Facade facade;
  final LanNativeTransferCoordinator coordinator;
  final LanDiscoveryService discovery;
  final LanTransferService transfer;
  final FakeLanShareSettings settings;
  final LanShareViewModel vm;
  static Future<_Fixture> create({bool failMetadataDelete = false}) async {
    final db = LanShareDatabase.forTesting(NativeDatabase.memory());
    final store = LanPeerTrustStore();
    await store.save(
      LanPeerTrustRecord(
        deviceId: 'peer',
        certificateFingerprint: 'a' * 64,
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
      ),
    );
    final security = LanSecurityService(
      appOwnedX25519PrivateSeed: Uint8List(32),
      peerTrustStore: store,
    );
    final facade = _Facade();
    final registry = LanNativePeerRegistry(
      trustStore: store,
      networkFacade: facade,
    );
    final transfer = LanTransferService(
      currentDeviceId: 'test-device',
      securityService: security,
      storageService: FakeLanStorageService(),
    );
    final coordinator = LanNativeTransferCoordinator(
      transferService: transfer,
      networkFacade: facade,
      policyPort: registry,
      storageService: FakeLanStorageService(),
    );
    final discovery = LanDiscoveryService(
      currentDeviceId: 'test-device',
      currentDeviceAlias: 'Test device',
      localAddressSelectionPort:
          const LanShareSingleCandidateLocalAddressSelection(),
    );
    final settings = FakeLanShareSettings();
    final vm = LanShareViewModel(
      discoveryService: discovery,
      securityService: security,
      storageService: FakeLanStorageService(),
      transferService: transfer,
      nativeTransferCoordinator: coordinator,
      historyDao: db.lanHistoryDao,
      pairingMetadataDao: failMetadataDelete
          ? _FailingMetadataDelete(db.lanPairingMetadataDao)
          : db.lanPairingMetadataDao,
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
      ownsRuntime: false,
    );
    return _Fixture(
      db,
      store,
      facade,
      coordinator,
      discovery,
      transfer,
      settings,
      vm,
    );
  }

  Future<void> close() async {
    await vm.shutdown();
    vm.dispose();
    await coordinator.dispose();
    await transfer.close();
    await discovery.close();
    await store.dispose();
    await database.dispose();
    await facade.controller.close();
    settings.dispose();
  }
}

final class _Facade extends Fake implements NetworkFacade {
  final controller = StreamController<SdkEvent>.broadcast();
  final List<String> removed = [];
  @override
  Stream<SdkEvent> get events => controller.stream;
  @override
  Future<NetworkResult<void>> registerPeer(PeerConfig peer) async =>
      const NetworkSuccess(null);
  @override
  Future<NetworkResult<void>> connectPeer(
    String id, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async => const NetworkSuccess(null);
  @override
  Future<NetworkResult<TransferSession>> transferFile({
    required String transferId,
    required String peerId,
    required String filePath,
    CommunicationClass communicationClass = CommunicationClass.bulkTransfer,
  }) async => NetworkSuccess(
    TransferSession(
      transferId: transferId,
      peerId: peerId,
      filePath: filePath,
      routeType: NetworkRouteType.relay,
    ),
  );
  @override
  Future<NetworkResult<void>> disconnectPeer(String id) async =>
      const NetworkSuccess(null);
  @override
  Future<NetworkResult<void>> removePeer(String id) async {
    removed.add(id);
    return const NetworkSuccess(null);
  }
}

final class _FailingMetadataDelete extends Fake
    implements LanPairingMetadataDao {
  _FailingMetadataDelete(this.delegate);
  final LanPairingMetadataDao delegate;
  @override
  Future<List<LanPairingMetadataData>> getAll() => delegate.getAll();
  @override
  Future<void> upsert(LanPairingMetadataCompanion entry) =>
      delegate.upsert(entry);
  @override
  Future<int> deleteDevice(String id) async =>
      throw StateError('Metadata cleanup failed');
}
