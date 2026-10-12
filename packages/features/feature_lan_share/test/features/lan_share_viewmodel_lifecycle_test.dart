import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'pairing busy state blocks repeats and cancellation prevents late navigation',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      final sockets = server.listen(accepted.complete);
      addTearDown(() async {
        if (accepted.isCompleted) (await accepted.future).destroy();
        await sockets.cancel();
        await server.close();
      });
      final requests = <LanPairingRequest>[];
      final subscription = fixture.vm.pairingRequestStream.listen(requests.add);
      addTearDown(subscription.cancel);
      final peer = _peer().copyWith(ip: '127.0.0.1', controlPort: server.port);
      final pending = HttpOverrides.runZoned(
        () => fixture.vm.requestPairing(peer),
        createHttpClient: _RealHttpOverrides().createHttpClient,
      );
      expect(fixture.vm.isPairingConnecting('peer'), isTrue);
      await accepted.future.timeout(const Duration(seconds: 2));
      final repeated = await fixture.vm.requestPairing(peer);
      expect(
        (repeated as NetworkFailure<void>).error.code,
        NetworkErrorCode.invalidState,
      );
      fixture.vm.cancelPairingConnection('peer');
      final cancelled = await pending.timeout(const Duration(seconds: 1));
      expect(
        (cancelled as NetworkFailure<void>).error.code,
        NetworkErrorCode.cancelled,
      );
      expect(fixture.vm.isPairingConnecting('peer'), isFalse);
      expect(requests, isEmpty);
    },
  );
  test(
    'metadata read failure releases initialization subscriptions and permits a retry',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.metadata.failRead = true;
      await expectLater(fixture.vm.initialize(), throwsStateError);
      expect(fixture.settings.hasActiveListeners, isFalse);
      fixture.metadata.failRead = false;
      await fixture.vm.initialize();
      expect(fixture.discovery.advertisedPort, 55000);
    },
  );
  test(
    'scan and WebShare commands preserve listener ownership and retry results',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.discovery.failScan = true;
      expect(await fixture.vm.startScanning(), isA<NetworkFailure<void>>());
      expect(fixture.vm.lastScanError?.code, NetworkErrorCode.ioError);
      fixture.discovery.failScan = false;
      expect(await fixture.vm.startScanning(), isA<NetworkSuccess<void>>());
      expect(fixture.vm.lastScanError, isNull);
      expect(await fixture.vm.stopScanning(), isA<NetworkSuccess<void>>());
      expect(await fixture.vm.toggleWebShare(), isA<NetworkSuccess<void>>());
      expect(fixture.vm.isWebShareActive, isTrue);
      expect(await fixture.vm.toggleWebShare(), isA<NetworkSuccess<void>>());
      expect(fixture.vm.isWebShareActive, isFalse);
      await fixture.vm.shutdown();
      fixture.disposeViewModel();
      expect(await fixture.vm.startScanning(), isA<NetworkFailure<void>>());
      await expectLater(fixture.vm.initialize(), throwsStateError);
    },
  );

  test(
    'receiver lifecycle persists signals, keeps discovered pairing requests and drains keepalive',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.store.save(_trust());
      await fixture.vm.initialize();
      expect(fixture.discovery.advertisedPort, 55000);
      final peer = _peer();
      final invitation = fixture.vm.pairingRequestStream.first;
      fixture.transfer.announcements.add(peer);
      await Future<void>.delayed(Duration.zero);
      expect((await invitation).peer.peerId, 'peer');
      final validRequest = LanPairingRequest(
        peer: LanPeerViewState(discovery: peer),
        sessionId: 'incoming',
        isIncoming: true,
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      );
      fixture.transfer.invitations.add(validRequest);
      fixture.transfer.invitations.add(
        LanPairingRequest(
          peer: validRequest.peer,
          sessionId: 'expired',
          isIncoming: true,
          expiresAt: DateTime.utc(2020),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        fixture.vm.pairingRequestForSession('incoming'),
        same(validRequest),
      );
      expect(fixture.vm.pairingRequestForSession('expired'), isNull);
      final message = LanMessage(
        id: 'received',
        senderId: 'peer',
        senderAlias: 'Phone',
        receiverId: 'local',
        payloadType: LanPayloadType.text,
        textContent: 'hello',
        createdAt: DateTime.now(),
        isIncoming: true,
      );
      fixture.transfer.handleIncomingMessageFromWeb(message);
      await Future<void>.delayed(Duration.zero);
      fixture.transfer.handleMessageProgressFromWeb(
        message.copyWith(status: LanTransferStatus.completed),
      );
      fixture.transfer.connections.add(
        const LanConnectionStateChanged(deviceId: 'peer', connected: true),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 5050));
      expect(fixture.transfer.connectCalls, greaterThan(0));
      fixture.transfer.recalls.add(
        const LanRecallRequest(senderDeviceId: 'peer', messageId: 'received'),
      );
      await Future<void>.delayed(Duration.zero);
      await fixture.vm.shutdown();
      final saved = await fixture.db.lanHistoryDao.getRecord('received');
      expect(saved!.isRecalled, isTrue);
      expect(fixture.vm.devices, isEmpty);
      expect(fixture.transfer.stops, greaterThan(0));
      await fixture.vm.initialize();
      await fixture.settings.setLanDeviceAlias('Updated');
      await Future<void>.delayed(Duration.zero);
      expect(fixture.discovery.alias, 'Updated');
    },
  );

  test(
    'failed advertising can be retried without retaining old subscriptions',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.discovery.failAdvertise = true;
      await expectLater(fixture.vm.initialize(), throwsStateError);
      fixture.discovery.failAdvertise = false;
      await fixture.vm.initialize();
      expect(fixture.discovery.advertisedPort, 55000);
    },
  );

  test(
    'listener failure remains visible and shutdown still releases its owner',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.transfer.failListen = true;
      await fixture.vm.initialize();
      expect(fixture.logger.warnings, contains('LAN listener failed'));
      await fixture.vm.shutdown();
      expect(fixture.transfer.stops, greaterThan(0));
    },
  );
}

final class _RealHttpOverrides extends HttpOverrides {}

final class _Fixture {
  final db = LanShareDatabase.forTesting(NativeDatabase.memory());
  final store = LanPeerTrustStore();
  final settings = FakeLanShareSettings();
  final discovery = _Discovery();
  final logger = FakeLanShareLogger();
  late final metadata = _Metadata(db.lanPairingMetadataDao);
  late final transfer = _Transfer(
    LanSecurityService(
      appOwnedX25519PrivateSeed: Uint8List(32),
      peerTrustStore: store,
    ),
  );
  late final vm = LanShareViewModel(
    discoveryService: discovery,
    securityService: transfer.securityService,
    storageService: FakeLanStorageService(),
    transferService: transfer,
    historyDao: db.lanHistoryDao,
    pairingMetadataDao: metadata,
    appSettings: settings,
    dataProtection: FakeLanShareDataProtection(),
    logger: logger,
  );
  bool disposed = false;
  void disposeViewModel() {
    if (!disposed) {
      disposed = true;
      vm.dispose();
    }
  }

  Future<void> close() async {
    await vm.shutdown();
    disposeViewModel();
    await transfer.close();
    await discovery.close();
    await store.dispose();
    await db.dispose();
    settings.dispose();
  }
}

final class _Metadata extends Fake implements LanPairingMetadataDao {
  _Metadata(this.delegate);
  final LanPairingMetadataDao delegate;
  bool failRead = false;
  @override
  Future<List<LanPairingMetadataData>> getAll() async {
    if (failRead) throw StateError('Metadata unavailable');
    return delegate.getAll();
  }

  @override
  Future<void> upsert(LanPairingMetadataCompanion entry) =>
      delegate.upsert(entry);
  @override
  Future<int> deleteDevice(String id) => delegate.deleteDevice(id);
}

final class _Discovery extends Fake implements LanDiscoveryService {
  bool failScan = false;
  bool failAdvertise = false;
  @override
  int? advertisedPort;
  String alias = 'Local';
  final snapshots = StreamController<List<LanDiscoveredPeer>>.broadcast();
  final List<LanDiscoveredPeer> peers = [];
  @override
  bool isScanning = false;
  @override
  bool isWebShareActive = false;
  @override
  String get currentDeviceId => 'local';
  @override
  String get currentDeviceAlias => alias;
  @override
  List<LanDiscoveredPeer> get currentDiscoveredPeers => List.of(peers);
  @override
  Stream<List<LanDiscoveredPeer>> get discoveredPeersStream => snapshots.stream;
  @override
  Future<NetworkResult<void>> updateDeviceAlias(String value) async {
    alias = value;
    return const NetworkSuccess(null);
  }

  @override
  void registerDiscoveredPeer(LanDiscoveredPeer peer) {
    peers.removeWhere((entry) => entry.deviceId == peer.deviceId);
    peers.add(peer);
    snapshots.add(List.of(peers));
  }

  @override
  bool touchDiscoveredPeer(String id, {DateTime? now}) =>
      peers.any((peer) => peer.deviceId == id);
  @override
  Future<NetworkResult<void>> startDiscovery() async {
    if (failScan) {
      return const NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'Scan failed',
          operation: NetworkOperation.startDiscovery,
        ),
      );
    }
    isScanning = true;
    return const NetworkSuccess(null);
  }

  @override
  Future<NetworkResult<void>> stopDiscovery() async {
    isScanning = false;
    return const NetworkSuccess(null);
  }

  @override
  Future<NetworkResult<void>> startAdvertising({
    int port = 53317,
    int? nativePort,
  }) async {
    if (failAdvertise) throw StateError('Advertising failed');
    advertisedPort = port;
    return const NetworkSuccess(null);
  }

  @override
  Future<NetworkResult<void>> stopAdvertising() async =>
      const NetworkSuccess(null);
  @override
  Future<NetworkResult<String>> startWebShareServer({
    int port = 53319,
    required LanSecurityService securityService,
    required LanStorageService storageService,
    required LanTransferService transferService,
  }) async {
    isWebShareActive = true;
    return const NetworkSuccess('https://192.0.2.1:53319');
  }

  @override
  Future<NetworkResult<void>> stopWebShareServer() async {
    isWebShareActive = false;
    return const NetworkSuccess(null);
  }

  @override
  Future<void> close() async {
    if (!snapshots.isClosed) await snapshots.close();
  }
}

final class _Transfer extends LanTransferService {
  _Transfer(LanSecurityService security)
    : super(
        currentDeviceId: 'local',
        securityService: security,
        storageService: FakeLanStorageService(),
      );
  bool failListen = false;
  int stops = 0;
  int connectCalls = 0;
  final announcements = StreamController<LanDiscoveredPeer>.broadcast();
  final invitations = StreamController<LanPairingRequest>.broadcast();
  final recalls = StreamController<LanRecallRequest>.broadcast();
  final connections = StreamController<LanConnectionStateChanged>.broadcast();
  @override
  Stream<LanDiscoveredPeer> get announcedPeerStream => announcements.stream;
  @override
  Stream<LanPairingRequest> get pairingInviteStream => invitations.stream;
  @override
  Stream<LanRecallRequest> get recalledMessageIdStream => recalls.stream;
  @override
  Stream<LanConnectionStateChanged> get connectionStateStream =>
      connections.stream;
  @override
  bool hasPendingPairing(String peerId) => true;
  @override
  Future<NetworkResult<void>> connectWebSocket(LanDiscoveredPeer peer) async {
    connectCalls++;
    return const NetworkSuccess(null);
  }

  @override
  Future<NetworkResult<int>> startListening({int port = 53317}) async =>
      failListen
      ? const NetworkFailure(
          NetworkError(
            code: NetworkErrorCode.ioError,
            message: 'Listen failed',
            operation: NetworkOperation.startLanListener,
          ),
        )
      : const NetworkSuccess(55000);
  @override
  Future<NetworkResult<void>> stopListening() async {
    stops++;
    return const NetworkSuccess(null);
  }

  @override
  Future<void> close() async {
    await super.close();
    await Future.wait([
      if (!announcements.isClosed) announcements.close(),
      if (!invitations.isClosed) invitations.close(),
      if (!recalls.isClosed) recalls.close(),
      if (!connections.isClosed) connections.close(),
    ]);
  }
}

LanDiscoveredPeer _peer() => LanDiscoveredPeer(
  deviceId: 'peer',
  alias: 'Phone',
  ip: '192.0.2.5',
  controlPort: 53317,
  os: 'android',
  lastSeen: DateTime.now(),
);
LanPeerTrustRecord _trust() => LanPeerTrustRecord(
  deviceId: 'peer',
  certificateFingerprint: 'a' * 64,
  inboundAccessToken: 'inbound',
  outboundAccessToken: 'outbound',
  x25519PublicKey: Uint8List(32),
  networkIdentityPublicKey: Uint8List(32),
  origin: PeerTrustOrigin.localPin,
  authorization: const PeerRouteAuthorization(localDirect: true, relay: false),
  createdAt: DateTime.utc(2026),
);
