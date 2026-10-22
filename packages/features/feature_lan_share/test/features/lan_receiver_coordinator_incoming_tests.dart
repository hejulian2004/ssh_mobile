part of 'lan_receiver_coordinator_test.dart';

void _registerReceiverIncomingTests() {
  test(
    'incoming attachment classification creates properly typed LanMessage',
    () async {
      final trustStore = LanPeerTrustStore();
      await trustStore.save(_trustRecord('peer-a'));
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings();
      final networkService = FakeLanShareNetworkService();
      final transfer = FakeLanTransferService();
      final coordinator = LanReceiverCoordinator(
        appSettings: settings,
        logger: FakeLanShareLogger(),
        dataProtection: FakeLanShareDataProtection(),
        networkIdentity: FakeLanShareIdentity(),
        networkAccess: FakeLanShareNetworkAccessPort(
          networkFacade: networkService,
        ),
        bootstrapClient: FakeLanShareBootstrapClient(),
        historyRepository: LanShareHistoryRepository(database),
        networkRuntime: FakeLanShareNetworkRuntime(),
        peerTrustStore: trustStore,
        transferServiceOverride: transfer,
        storageServiceOverride: FakeLanStorageService(),
        discoveryServiceOverride: FakeLanDiscoveryService(),
      );

      await coordinator.ensureInitialized();

      final cases = <(String, LanPayloadType)>[
        ('photo.jpg', LanPayloadType.image),
        ('video.mp4', LanPayloadType.video),
        ('voice.mp3', LanPayloadType.audio),
        ('archive.zip', LanPayloadType.file),
        ('no_extension_file', LanPayloadType.file),
      ];

      for (final (fileName, expectedType) in cases) {
        final offer = IncomingTransferOffer(
          eventId: 'ev-$fileName',
          timestamp: DateTime.now(),
          transferId: 'tx-$fileName',
          peerId: 'peer-a',
          fileName: fileName,
          fileSize: 1024,
          routeType: NetworkRouteType.quicDirect,
        );

        final result = await coordinator.acceptNativeIncomingTransfer(offer);
        expect(
          result,
          isA<NetworkSuccess<void>>(),
          reason: result is NetworkFailure<void>
              ? result.error.toString()
              : null,
        );

        final record = await database.lanHistoryDao.getRecord('tx-$fileName');
        expect(record, isNotNull);
        expect(record!.payloadType, expectedType.toJson());
        expect(record.fileName, fileName);
        expect(record.isIncoming, isTrue);
      }

      await coordinator.close();
      await trustStore.dispose();
      settings.dispose();
      await database.dispose();
    },
  );

  test(
    'accept after trust revoked performs native reject and returns authenticationFailed',
    () async {
      final trustStore = LanPeerTrustStore();
      addTearDown(trustStore.dispose);
      await trustStore.save(_trustRecord('peer-a'));
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.dispose);
      final settings = FakeLanShareSettings();
      addTearDown(settings.dispose);
      final networkService = FakeLanShareNetworkService();
      final coordinator = LanReceiverCoordinator(
        appSettings: settings,
        logger: FakeLanShareLogger(),
        dataProtection: FakeLanShareDataProtection(),
        networkIdentity: FakeLanShareIdentity(),
        networkAccess: FakeLanShareNetworkAccessPort(
          networkFacade: networkService,
        ),
        bootstrapClient: FakeLanShareBootstrapClient(),
        historyRepository: LanShareHistoryRepository(database),
        networkRuntime: FakeLanShareNetworkRuntime(),
        peerTrustStore: trustStore,
        transferServiceOverride: FakeLanTransferService(),
        storageServiceOverride: FakeLanStorageService(),
        discoveryServiceOverride: FakeLanDiscoveryService(),
      );
      addTearDown(coordinator.close);

      await coordinator.ensureInitialized();

      final offer = IncomingTransferOffer(
        eventId: 'ev-revoked',
        timestamp: DateTime.now(),
        transferId: 'tx-revoked',
        peerId: 'peer-a',
        fileName: 'secret.pdf',
        fileSize: 1024,
        routeType: NetworkRouteType.quicDirect,
      );

      // Explicitly unpair / remove trust
      await coordinator.removeTrustedPeer('peer-a');
      expect(await trustStore.read('peer-a'), isNull);

      // Accept after trust revoked
      final result = await coordinator.acceptNativeIncomingTransfer(offer);
      expect(result, isA<NetworkFailure<void>>());
      final failure = result as NetworkFailure<void>;
      expect(failure.error.code, NetworkErrorCode.authenticationFailed);
      // Native reject was called exactly once
      expect(networkService.incomingResponses, contains(('tx-revoked', false)));
      expect(
        networkService.incomingResponses.where((r) => r.$2 == true),
        isEmpty,
      );
    },
  );

  test(
    'accept after Relay authorization revoked rejects offer with authenticationFailed',
    () async {
      final trustStore = LanPeerTrustStore();
      addTearDown(trustStore.dispose);
      await trustStore.save(_trustRecord('peer-a'));
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.dispose);
      final settings = FakeLanShareSettings();
      addTearDown(settings.dispose);
      final networkService = FakeLanShareNetworkService();
      final coordinator = LanReceiverCoordinator(
        appSettings: settings,
        logger: FakeLanShareLogger(),
        dataProtection: FakeLanShareDataProtection(),
        networkIdentity: FakeLanShareIdentity(),
        networkAccess: FakeLanShareNetworkAccessPort(
          networkFacade: networkService,
        ),
        bootstrapClient: FakeLanShareBootstrapClient(),
        historyRepository: LanShareHistoryRepository(database),
        networkRuntime: FakeLanShareNetworkRuntime(),
        peerTrustStore: trustStore,
        transferServiceOverride: FakeLanTransferService(),
        storageServiceOverride: FakeLanStorageService(),
        discoveryServiceOverride: FakeLanDiscoveryService(),
      );
      addTearDown(coordinator.close);

      await coordinator.ensureInitialized();

      // peer-a has relay=false by default in _trustRecord
      final relayOffer = IncomingTransferOffer(
        eventId: 'ev-relay-unauth',
        timestamp: DateTime.now(),
        transferId: 'tx-relay-unauth',
        peerId: 'peer-a',
        fileName: 'relay_file.bin',
        fileSize: 2048,
        routeType: NetworkRouteType.relay,
      );

      final result = await coordinator.acceptNativeIncomingTransfer(relayOffer);
      expect(result, isA<NetworkFailure<void>>());
      final failure = result as NetworkFailure<void>;
      expect(failure.error.code, NetworkErrorCode.authenticationFailed);
      expect(
        networkService.incomingResponses,
        contains(('tx-relay-unauth', false)),
      );
    },
  );

  test(
    'incoming transferId collision from different peer fails closed and preserves history',
    () async {
      final trustStore = LanPeerTrustStore();
      addTearDown(trustStore.dispose);
      await trustStore.save(_trustRecord('peer-a'));
      await trustStore.save(_trustRecord('peer-b'));
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.dispose);
      final settings = FakeLanShareSettings();
      addTearDown(settings.dispose);
      final networkService = FakeLanShareNetworkService();
      final coordinator = LanReceiverCoordinator(
        appSettings: settings,
        logger: FakeLanShareLogger(),
        dataProtection: FakeLanShareDataProtection(),
        networkIdentity: FakeLanShareIdentity(),
        networkAccess: FakeLanShareNetworkAccessPort(
          networkFacade: networkService,
        ),
        bootstrapClient: FakeLanShareBootstrapClient(),
        historyRepository: LanShareHistoryRepository(database),
        networkRuntime: FakeLanShareNetworkRuntime(),
        peerTrustStore: trustStore,
        transferServiceOverride: FakeLanTransferService(),
        storageServiceOverride: FakeLanStorageService(),
        discoveryServiceOverride: FakeLanDiscoveryService(),
      );
      addTearDown(coordinator.close);

      await coordinator.ensureInitialized();

      // peer-a offer accepted
      final offerA = IncomingTransferOffer(
        eventId: 'ev-peer-a',
        timestamp: DateTime.now(),
        transferId: 'tx-collision-1',
        peerId: 'peer-a',
        fileName: 'doc_a.pdf',
        fileSize: 1000,
        routeType: NetworkRouteType.quicDirect,
      );
      final resultA = await coordinator.acceptNativeIncomingTransfer(offerA);
      expect(resultA, isA<NetworkSuccess<void>>());

      final recordA = await database.lanHistoryDao.getRecord('tx-collision-1');
      expect(recordA, isNotNull);
      expect(recordA!.senderId, 'peer-a');

      // peer-b offer with SAME transferId
      final offerB = IncomingTransferOffer(
        eventId: 'ev-peer-b',
        timestamp: DateTime.now(),
        transferId: 'tx-collision-1',
        peerId: 'peer-b',
        fileName: 'doc_b.pdf',
        fileSize: 2000,
        routeType: NetworkRouteType.quicDirect,
      );
      final resultB = await coordinator.acceptNativeIncomingTransfer(offerB);
      expect(resultB, isA<NetworkFailure<void>>());
      final failureB = resultB as NetworkFailure<void>;
      expect(failureB.error.code, NetworkErrorCode.identityConflict);

      // Old history record from peer-a is untouched
      final recordAfter = await database.lanHistoryDao.getRecord(
        'tx-collision-1',
      );
      expect(recordAfter, isNotNull);
      expect(recordAfter!.senderId, 'peer-a');
      expect(recordAfter.fileName, 'doc_a.pdf');

      // Rejecting a pending matching offer cleans up history
      final offerPending = IncomingTransferOffer(
        eventId: 'ev-peer-a-pending',
        timestamp: DateTime.now(),
        transferId: 'tx-pending-1',
        peerId: 'peer-a',
        fileName: 'pending.pdf',
        fileSize: 100,
        routeType: NetworkRouteType.quicDirect,
      );
      // Simulate failed accept creating connecting record
      networkService.failRespond = true;
      await coordinator.acceptNativeIncomingTransfer(offerPending);
      expect(await database.lanHistoryDao.getRecord('tx-pending-1'), isNotNull);

      // Rejecting matching offer cleans up history
      networkService.failRespond = false;
      final rejectResult = await coordinator.rejectNativeIncomingTransfer(
        offerPending,
      );
      expect(rejectResult, isA<NetworkSuccess<void>>());
      expect(await database.lanHistoryDao.getRecord('tx-pending-1'), isNull);
    },
  );

  test(
    'incoming transfer with unspecified route is rejected fail-closed',
    () async {
      final trustStore = LanPeerTrustStore();
      await trustStore.save(_trustRecord('peer-a'));
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings();
      final networkService = FakeLanShareNetworkService();
      final transfer = FakeLanTransferService();
      final coordinator = LanReceiverCoordinator(
        appSettings: settings,
        logger: FakeLanShareLogger(),
        dataProtection: FakeLanShareDataProtection(),
        networkIdentity: FakeLanShareIdentity(),
        networkAccess: FakeLanShareNetworkAccessPort(
          networkFacade: networkService,
        ),
        bootstrapClient: FakeLanShareBootstrapClient(),
        historyRepository: LanShareHistoryRepository(database),
        networkRuntime: FakeLanShareNetworkRuntime(),
        peerTrustStore: trustStore,
        transferServiceOverride: transfer,
        discoveryServiceOverride: FakeLanDiscoveryService(),
      );

      final receivedOffers = <IncomingTransferOffer>[];
      final sub = coordinator.nativeIncomingTransferOffers.listen(
        receivedOffers.add,
      );

      await coordinator.ensureInitialized();

      final unspecifiedOffer = IncomingTransferOffer(
        eventId: 'ev-unspecified',
        timestamp: DateTime.now(),
        transferId: 'tx-unspecified',
        peerId: 'peer-a',
        fileName: 'test.txt',
        fileSize: 100,
        routeType: NetworkRouteType.unspecified,
      );

      networkService.emitEvent(unspecifiedOffer);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(receivedOffers, isEmpty);

      final acceptResult = await coordinator.acceptNativeIncomingTransfer(
        unspecifiedOffer,
      );
      expect(acceptResult, isA<NetworkFailure<void>>());

      await sub.cancel();
      await coordinator.close();
      await trustStore.dispose();
      settings.dispose();
      await database.dispose();
    },
  );
}
