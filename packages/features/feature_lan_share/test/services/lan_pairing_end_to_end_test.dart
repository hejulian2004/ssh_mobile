import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:drift/native.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });
  test(
    'terminating PIN verification invalidates proof before it can commit trust',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final service = LanTransferService(
        currentDeviceId: 'local',
        securityService: LanSecurityService(
          appOwnedX25519PrivateSeed: Uint8List(32),
        ),
        storageService: LanStorageService(),
        networkIdentityPublicKeyProvider: () async {
          started.complete();
          await release.future;
          return Uint8List(32);
        },
      );
      addTearDown(service.close);
      final pending = service.sendHandshake(
        _peer('remote', 1, 'Remote'),
        '123456',
        'Local',
      );
      await started.future;
      service.cancelPairingAuthentication('remote');
      release.complete();
      expect(
        (await pending as NetworkFailure<LanPairingHandshakeProgress>)
            .error
            .code,
        NetworkErrorCode.cancelled,
      );
      expect(
        await service.securityService.peerTrustStore.read('remote'),
        isNull,
      );
    },
  );

  test(
    'invitation is single flight and termination closes its pending socket',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      final subscription = server.listen((socket) => accepted.complete(socket));
      addTearDown(() async {
        if (accepted.isCompleted) (await accepted.future).destroy();
        await subscription.cancel();
        await server.close();
      });
      final service = LanTransferService(
        currentDeviceId: 'local',
        securityService: LanSecurityService(
          appOwnedX25519PrivateSeed: Uint8List(32),
        ),
        storageService: LanStorageService(),
      );
      addTearDown(service.close);
      final peer = _peer('remote', server.port, 'Remote');
      Future<NetworkResult<LanPairingEndpoint>> invite() =>
          service.sendPairingInvite(
            peer,
            'Local',
            sessionId: 'invitation',
            expiresAt: DateTime.now().add(const Duration(minutes: 1)),
          );
      final pending = _runWithRealHttpClient(invite);
      await accepted.future;
      expect(
        (await invite() as NetworkFailure<LanPairingEndpoint>).error.code,
        NetworkErrorCode.invalidState,
      );
      service.cancelPairingInvite('remote');
      final result = await pending.timeout(const Duration(seconds: 1));
      expect(
        (result as NetworkFailure<LanPairingEndpoint>).error.code,
        NetworkErrorCode.cancelled,
      );
    },
  );

  test(
    'PIN termination closes a pending TLS socket and blocks duplicate verification',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      final subscription = server.listen(accepted.complete);
      addTearDown(() async {
        if (accepted.isCompleted) (await accepted.future).destroy();
        await subscription.cancel();
        await server.close();
      });
      final service = LanTransferService(
        currentDeviceId: 'local',
        securityService: LanSecurityService(
          appOwnedX25519PrivateSeed: Uint8List(32),
        ),
        storageService: LanStorageService(),
        networkIdentityPublicKeyProvider: () async => Uint8List(32),
      );
      addTearDown(service.close);
      final peer = _peer('remote', server.port, 'Remote');
      final pending = _runWithRealHttpClient(
        () => service.sendHandshake(peer, '123456', 'Local'),
      );
      final duplicate = await service.sendHandshake(peer, '123456', 'Local');
      expect(
        (duplicate as NetworkFailure<LanPairingHandshakeProgress>).error.code,
        NetworkErrorCode.invalidState,
      );
      await accepted.future.timeout(const Duration(seconds: 5));
      service.cancelPairingAuthentication('remote');
      expect(
        (await pending.timeout(const Duration(seconds: 1))
                as NetworkFailure<LanPairingHandshakeProgress>)
            .error
            .code,
        NetworkErrorCode.cancelled,
      );
      expect(
        await service.securityService.peerTrustStore.read('remote'),
        isNull,
      );
    },
  );

  test(
    'unpair invalidates an in-flight PIN attempt before it can establish trust',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final service = LanTransferService(
        currentDeviceId: 'device-a',
        securityService: LanSecurityService(
          appOwnedX25519PrivateSeed: Uint8List(32),
        ),
        storageService: LanStorageService(),
        networkIdentityPublicKeyProvider: () async {
          started.complete();
          await release.future;
          return Uint8List(32);
        },
      );
      addTearDown(service.close);
      final handshake = service.sendHandshake(
        _peer('device-b', 1, 'B'),
        '123456',
        'A',
      );
      await started.future;
      final unpair = service.disconnectPairedPeer('device-b');
      release.complete();
      await unpair;
      final result = await handshake;
      expect(
        (result as NetworkFailure<LanPairingHandshakeProgress>).error.code,
        NetworkErrorCode.cancelled,
      );
      expect(
        await service.securityService.peerTrustStore.read('device-b'),
        isNull,
      );
      expect(service.hasPendingPairing('device-b'), isFalse);
    },
  );

  test(
    'pairing invitations retain the contacted port through a TCP mapping',
    () async {
      final serviceA = LanTransferService(
        currentDeviceId: 'device-a',
        securityService: LanSecurityService(
          appOwnedX25519PrivateSeed: Uint8List.fromList(List.filled(32, 1)),
        ),
        storageService: LanStorageService(),
      );
      final serviceB = LanTransferService(
        currentDeviceId: 'device-b',
        securityService: LanSecurityService(
          appOwnedX25519PrivateSeed: Uint8List.fromList(List.filled(32, 2)),
        ),
        storageService: LanStorageService(),
      );
      addTearDown(serviceA.close);
      addTearDown(serviceB.close);
      await serviceA.startListening(port: 0);
      await serviceB.startListening(port: 0);
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final subscription = proxy.listen((incoming) async {
        sockets.add(incoming);
        final outgoing = await Socket.connect(
          InternetAddress.loopbackIPv4,
          serviceB.activePort,
        );
        sockets.add(outgoing);
        unawaited(
          incoming
              .cast<List<int>>()
              .pipe(outgoing)
              .catchError((Object _) => outgoing),
        );
        unawaited(
          outgoing
              .cast<List<int>>()
              .pipe(incoming)
              .catchError((Object _) => incoming),
        );
      });
      addTearDown(() async {
        await subscription.cancel();
        await proxy.close();
        for (final socket in sockets) {
          socket.destroy();
        }
      });
      final incomingInvite = serviceB.pairingInviteStream.first;
      final result = await _runWithRealHttpClient(
        () => serviceA.sendPairingInvite(
          _peer('device-b', proxy.port, 'Device B'),
          'Device A',
          sessionId: 'mapped-session',
          expiresAt: DateTime.now().add(const Duration(minutes: 1)),
        ),
      );
      expect(result, isA<NetworkSuccess<LanPairingEndpoint>>());
      expect(
        (result as NetworkSuccess<LanPairingEndpoint>).data.remotePort,
        proxy.port,
      );
      expect((await incomingInvite).peer.peerId, 'device-a');
      expect(
        await serviceA.securityService.peerTrustStore.read('device-b'),
        isNull,
      );
      final selfInvite = await _runWithRealHttpClient(
        () => serviceA.sendPairingInvite(
          _peer('device-a', serviceA.activePort, 'Device A'),
          'Device A',
          sessionId: 'self-session',
          expiresAt: DateTime.now().add(const Duration(minutes: 1)),
        ),
      );
      expect(selfInvite, isA<NetworkFailure<LanPairingEndpoint>>());
      final invalidPin = await serviceA.sendHandshake(
        _peer('device-b', proxy.port, 'B'),
        'bad',
        'A',
      );
      expect(
        (invalidPin as NetworkFailure<LanPairingHandshakeProgress>).error.code,
        NetworkErrorCode.invalidArgument,
      );
      final missingIdentity = await serviceA.sendHandshake(
        _peer('device-b', proxy.port, 'B'),
        '123456',
        'A',
      );
      expect(
        (missingIdentity as NetworkFailure<LanPairingHandshakeProgress>)
            .error
            .code,
        NetworkErrorCode.ioError,
      );
    },
  );

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

    final announced = serviceB.announcedPeerStream.first;
    final announcement = await _runWithRealHttpClient(
      () => serviceA.sendAnnouncement(peerB, 'Device A'),
    );
    expect(announcement, isA<NetworkSuccess<LanPairingEndpoint>>());
    expect(
      (announcement as NetworkSuccess<LanPairingEndpoint>).data.remotePort,
      peerB.controlPort,
    );
    expect((await announced).deviceId, 'device-a');
    final connected = serviceB.connectionStateStream.first;
    expect(
      await _runWithRealHttpClient(() => serviceA.connectWebSocket(peerB)),
      isA<NetworkSuccess<void>>(),
    );
    expect((await connected).connected, isTrue);
    expect(serviceA.isWebSocketConnected('device-b'), isTrue);
    final incoming = serviceB.incomingMessageStream.first;
    final message = LanMessage(
      id: 'paired-text',
      senderId: 'device-a',
      senderAlias: 'Device A',
      receiverId: 'device-b',
      payloadType: LanPayloadType.text,
      textContent: 'hello',
      createdAt: DateTime.now(),
      isIncoming: false,
    );
    final recipientKey = await securityB.getStaticX25519PublicKeyBytes();
    expect(
      await _runWithRealHttpClient(
        () => serviceA.sendMeta(
          peerB,
          message,
          recipientPubKeyBytes: recipientKey,
        ),
      ),
      isA<NetworkSuccess<void>>(),
    );
    expect((await incoming).textContent, 'hello');
    final recalled = serviceB.recalledMessageIdStream.first;
    expect(
      await _runWithRealHttpClient(
        () => serviceA.sendRecall(peerB, message.id),
      ),
      isA<NetworkSuccess<void>>(),
    );
    expect((await recalled).messageId, message.id);

    final db = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
    final discovery = LanDiscoveryService(
      currentDeviceId: 'device-a',
      currentDeviceAlias: 'Device A',
      localAddressSelectionPort:
          const LanShareSingleCandidateLocalAddressSelection(),
    );
    final vm = LanShareViewModel(
      discoveryService: discovery,
      securityService: securityA,
      storageService: FakeLanStorageService(),
      transferService: serviceA,
      historyDao: db.lanHistoryDao,
      pairingMetadataDao: db.lanPairingMetadataDao,
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
      ownsRuntime: false,
    );
    addTearDown(() async {
      await vm.shutdown();
      vm.dispose();
      await discovery.close();
      await db.dispose();
      settings.dispose();
    });
    await vm.initialize();
    expect(
      await _runWithRealHttpClient(() => vm.sendText(peerB, 'view model text')),
      isA<NetworkSuccess<void>>(),
    );
    expect(
      await _runWithRealHttpClient(
        () => vm.sendClipboard(peerB, 'view model clipboard'),
      ),
      isA<NetworkSuccess<void>>(),
    );
    final records = await db.lanHistoryDao.getAllRecords();
    expect(records, hasLength(2));
    expect(records.every((record) => record.status == 'completed'), isTrue);
    final outgoing = message.copyWith(id: records.first.id);
    expect(
      await _runWithRealHttpClient(() => vm.recallMessage(outgoing, peerB)),
      isA<NetworkSuccess<void>>(),
    );
    expect((await db.lanHistoryDao.getRecord(outgoing.id))!.isRecalled, isTrue);
    final directory = await Directory.systemTemp.createTemp('lan-vm-command-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/payload.bin')
      ..writeAsStringSync('payload');
    final unavailable = await vm.sendFileToDiscoveredPeer(peerB, source.path);
    expect(
      (unavailable as NetworkFailure<TransferSession>).error.code,
      NetworkErrorCode.noRoute,
    );
    expect(
      await vm.setRelayAuthorization('device-b', true),
      isA<NetworkFailure<void>>(),
    );
    await vm.clearChatHistory('device-b');
    expect(await db.lanHistoryDao.getAllRecords(), isEmpty);
    expect(await securityA.peerTrustStore.read('device-b'), isNotNull);
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
