part of 'lan_receiver_coordinator_test.dart';

void _registerReceiverLifecycleTests() {
  test(
    'enrollment stays light and page activation starts the deferred receiver once',
    () async {
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings();
      final identity = FakeLanShareIdentity();
      final native = FakeLanShareNetworkRuntime();
      final discovery = FakeLanDiscoveryService();
      final coordinator = LanReceiverCoordinator(
        appSettings: settings,
        logger: FakeLanShareLogger(),
        dataProtection: FakeLanShareDataProtection(),
        networkIdentity: identity,
        networkAccess: FakeLanShareNetworkAccessPort(
          networkFacade: FakeLanShareNetworkService(),
        ),
        bootstrapClient: FakeLanShareBootstrapClient(),
        historyRepository: LanShareHistoryRepository(database),
        networkRuntime: native,
        transferServiceOverride: FakeLanTransferService(),
        discoveryServiceOverride: discovery,
        startReceiverOnInitialization: false,
      );
      try {
        final enrollment = await coordinator.ensureRelayEnrollment();
        expect(await coordinator.ensureRelayEnrollment(), same(enrollment));
        expect(identity.loadCalls, 0);
        expect(coordinator.initialized, isFalse);
        expect(native.requestedCapabilities, isEmpty);
        await coordinator.ensureInitialized();
        expect(coordinator.receiverActive, isFalse);
        expect(discovery.advertisedEndpoints, isEmpty);
        expect(native.requestedCapabilities, isEmpty);
        await Future.wait([
          coordinator.activateReceiver(),
          coordinator.activateReceiver(),
        ]);
        expect(coordinator.receiverActive, isTrue);
        expect(identity.loadCalls, 1);
        expect(native.requestedCapabilities, [LanShareRuntimeRequest.runtime]);
        expect(discovery.advertisedEndpoints, isNotEmpty);
        await coordinator.deactivateReceiver();
        expect(coordinator.receiverActive, isFalse);
      } finally {
        await coordinator.close();
        settings.dispose();
        await database.dispose();
      }
      await expectLater(coordinator.ensureRelayEnrollment(), throwsStateError);
    },
  );
  test('receiver coordinator starts uninitialized', () async {
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
    final coordinator = LanReceiverCoordinator(
      appSettings: settings,
      logger: FakeLanShareLogger(),
      dataProtection: FakeLanShareDataProtection(),
      networkIdentity: FakeLanShareIdentity(),
      networkAccess: FakeLanShareNetworkAccessPort(),
      bootstrapClient: FakeLanShareBootstrapClient(),
      historyRepository: LanShareHistoryRepository(database),
      networkRuntime: FakeLanShareNetworkRuntime(),
      initializeNetwork: false,
    );

    expect(coordinator.initialized, isFalse);
    expect(coordinator.transferService, isNull);

    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });

  test('receiver initialization is shared and creates one ViewModel', () async {
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
    final identity = FakeLanShareIdentity();
    final coordinator = LanReceiverCoordinator(
      appSettings: settings,
      logger: FakeLanShareLogger(),
      dataProtection: FakeLanShareDataProtection(),
      networkIdentity: identity,
      networkAccess: FakeLanShareNetworkAccessPort(),
      bootstrapClient: FakeLanShareBootstrapClient(),
      historyRepository: LanShareHistoryRepository(database),
      networkRuntime: FakeLanShareNetworkRuntime(),
      initializeNetwork: false,
    );

    final first = coordinator.ensureInitialized();
    expect(identical(first, coordinator.ensureInitialized()), isTrue);
    await first;
    expect(coordinator.initialized, isTrue);
    expect(identity.loadCalls, 1);
    expect(coordinator.transferService, isNotNull);
    expect(coordinator.discoveryService, isNotNull);
    expect(coordinator.securityService, isNotNull);

    final viewModel = await coordinator.ensureViewModel();
    expect(identical(viewModel, await coordinator.ensureViewModel()), isTrue);
    expect(viewModel.ownsRuntime, isFalse);

    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });

  test(
    'receiver initialization requests runtime capability, not quic',
    () async {
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings();
      final networkService = FakeLanShareNetworkService();
      final networkRuntime = FakeLanShareNetworkRuntime();
      final networkAccess = FakeLanShareNetworkAccessPort(
        networkFacade: networkService,
      );
      final discovery = FakeLanDiscoveryService();
      final coordinator = LanReceiverCoordinator(
        appSettings: settings,
        logger: FakeLanShareLogger(),
        dataProtection: FakeLanShareDataProtection(),
        networkIdentity: FakeLanShareIdentity(),
        networkAccess: networkAccess,
        bootstrapClient: FakeLanShareBootstrapClient(),
        historyRepository: LanShareHistoryRepository(database),
        networkRuntime: networkRuntime,
        transferServiceOverride: FakeLanTransferService(),
        discoveryServiceOverride: discovery,
      );

      await coordinator.ensureInitialized();

      expect(
        networkRuntime.requestedCapabilities,
        contains(LanShareRuntimeRequest.runtime),
      );
      expect(
        networkRuntime.requestedCapabilities,
        everyElement(
          isIn(<LanShareRuntimeRequest>[
            LanShareRuntimeRequest.runtime,
            LanShareRuntimeRequest.webSocketRelay,
          ]),
        ),
      );
      // The App Scope owns facade startup; Feature activation only borrows it.
      expect(networkService.startCalls, 0);
      expect(networkAccess.borrowCalls, 1);
      expect(discovery.advertisedEndpoints, [
        (LanTransferService.defaultHttpPort, 43123),
      ]);

      await coordinator.close();
      settings.dispose();
      await database.dispose();
    },
  );

  test('paired native peers are restored before receiver use', () async {
    final trustStore = LanPeerTrustStore();
    await trustStore.save(_trustRecord('peer-a'));
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
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
      discoveryServiceOverride: FakeLanDiscoveryService(),
    );

    await coordinator.ensureInitialized();

    expect(networkService.registerPeerCalls, 1);
    expect(networkService.connectPeerCalls, 0);
    expect(networkService.lastPeerConfig?.peerId, 'peer-a');
    expect(networkService.lastPeerConfig?.endpointAddress, isEmpty);

    await coordinator.close();
    await trustStore.dispose();
    settings.dispose();
    await database.dispose();
  });

  test('native trust restoration is not gated by the HTTPS listener', () async {
    final trustStore = LanPeerTrustStore();
    await trustStore.save(_trustRecord('peer-a'));
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
    final networkService = FakeLanShareNetworkService();
    final networkRuntime = FakeLanShareNetworkRuntime();
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
      networkRuntime: networkRuntime,
      peerTrustStore: trustStore,
      transferServiceOverride: FakeLanTransferService(
        startListeningResult: NetworkFailure<int>(
          const NetworkError(
            code: NetworkErrorCode.ioError,
            message: 'listener unavailable',
            operation: NetworkOperation.startLanListener,
          ),
        ),
      ),
      discoveryServiceOverride: FakeLanDiscoveryService(),
    );

    await coordinator.ensureInitialized();

    expect(
      networkRuntime.requestedCapabilities,
      contains(LanShareRuntimeRequest.runtime),
    );
    expect(networkService.registerPeerCalls, 1);

    await coordinator.close();
    await trustStore.dispose();
    settings.dispose();
    await database.dispose();
  });

  test('newly paired trust is registered before endpoint discovery', () async {
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

    await coordinator.ensureInitialized();
    final pairedPeer = LanDiscoveredPeer(
      deviceId: 'peer-a',
      alias: 'Peer A',
      ip: '192.0.2.5',
      controlPort: 53317,
      deviceType: LanDeviceType.desktop,
      os: 'test',
      lastSeen: DateTime.utc(2026),
    );
    final pairingCallback = transfer.onPairingCommitted;
    expect(pairingCallback, isNotNull);
    await pairingCallback!(pairedPeer);

    expect(networkService.registerPeerCalls, 2);
    expect(networkService.lastPeerConfig?.endpointAddress, isEmpty);

    await coordinator.close();
    await trustStore.dispose();
    settings.dispose();
    await database.dispose();
  });

  test('explicit unpair removes trust and the native peer', () async {
    final trustStore = LanPeerTrustStore();
    await trustStore.save(_trustRecord('peer-a'));
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
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
      discoveryServiceOverride: FakeLanDiscoveryService(),
    );

    await coordinator.ensureInitialized();
    final result = await coordinator.removeTrustedPeer('peer-a');

    expect(result, isA<NetworkSuccess<void>>());
    expect(await trustStore.read('peer-a'), isNull);
    expect(networkService.removePeerCalls, 1);

    await coordinator.close();
    await trustStore.dispose();
    settings.dispose();
    await database.dispose();
  });

  test(
    'incomplete or malformed paired native peers are not restored',
    () async {
      for (final fixture in <Map<String, String?>>[
        <String, String?>{'identity': null, 'e2e': _encodedKey(32, 2)},
        <String, String?>{'identity': _encodedKey(32, 1), 'e2e': null},
        <String, String?>{
          'identity': _encodedKey(31, 1),
          'e2e': _encodedKey(32, 2),
        },
        <String, String?>{
          'identity': _encodedKey(32, 1),
          'e2e': _encodedKey(33, 2),
        },
      ]) {
        _seedMalformedTrust(
          identityKey: fixture['identity'],
          e2eKey: fixture['e2e'],
        );
        final trustStore = LanPeerTrustStore();
        final database = LanShareDatabase.forTesting(NativeDatabase.memory());
        final settings = FakeLanShareSettings();
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
          discoveryServiceOverride: FakeLanDiscoveryService(),
        );

        await coordinator.ensureInitialized();
        expect(networkService.registerPeerCalls, 0, reason: '$fixture');

        await coordinator.close();
        await trustStore.dispose();
        settings.dispose();
        await database.dispose();
      }
    },
  );

  test('every new receiver runtime restores paired native peers', () async {
    final trustStore = LanPeerTrustStore();
    await trustStore.save(_trustRecord('peer-a'));
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
    final firstFacade = FakeLanShareNetworkService();
    final secondFacade = FakeLanShareNetworkService();
    final coordinator = LanReceiverCoordinator(
      appSettings: settings,
      logger: FakeLanShareLogger(),
      dataProtection: FakeLanShareDataProtection(),
      networkIdentity: FakeLanShareIdentity(),
      networkAccess: FakeLanShareNetworkAccessPort(
        networkFacades: <NetworkFacade>[firstFacade, secondFacade],
      ),
      bootstrapClient: FakeLanShareBootstrapClient(),
      historyRepository: LanShareHistoryRepository(database),
      networkRuntime: FakeLanShareNetworkRuntime(),
      peerTrustStore: trustStore,
      transferServiceOverride: FakeLanTransferService(),
      discoveryServiceOverride: FakeLanDiscoveryService(),
    );

    await coordinator.ensureInitialized();
    await coordinator.deactivateReceiver();
    await coordinator.activateReceiver();

    expect(firstFacade.registerPeerCalls, 1);
    expect(secondFacade.registerPeerCalls, 1);

    await coordinator.close();
    await trustStore.dispose();
    settings.dispose();
    await database.dispose();
  });

  test(
    'deactivation detaches but does not dispose the shared facade',
    () async {
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings();
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
        transferServiceOverride: FakeLanTransferService(),
        discoveryServiceOverride: FakeLanDiscoveryService(),
      );

      await coordinator.ensureInitialized();
      await coordinator.deactivateReceiver();

      expect(coordinator.networkFacade, isNull);
      expect(networkService.startCalls, 0);
      expect(networkService.stopCalls, 0);
      expect(networkService.disposed, isFalse);

      await coordinator.close();
      expect(networkService.disposed, isFalse);
      settings.dispose();
      await database.dispose();
    },
  );
}
