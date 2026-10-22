part of 'lan_receiver_coordinator_test.dart';

void _registerReceiverRelayTests() {
  test(
    'relay configuration requests webSocketRelay before configuring relay',
    () async {
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
        transferServiceOverride: FakeLanTransferService(),
        discoveryServiceOverride: FakeLanDiscoveryService(),
      );
      await coordinator.ensureInitialized();

      final result = await coordinator.enrollRelay(
        endpoint: Uri.parse('https://relay.example.test'),
        enrollmentToken: '0123456789abcdef',
      );

      expect(result, isA<NetworkSuccess<void>>());
      expect(
        networkRuntime.requestedCapabilities,
        contains(LanShareRuntimeRequest.webSocketRelay),
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
      expect(networkService.configureRelayCalls, 1);

      await coordinator.close();
      settings.dispose();
      await database.dispose();
    },
  );

  test(
    'webSocketRelay-disabled runtime refuses relay configuration fast',
    () async {
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings(
        relayEndpoint: 'https://relay.example.test',
      );
      final networkService = FakeLanShareNetworkService();
      final networkRuntime = FakeLanShareNetworkRuntime(
        refuseWebSocketRelay: true,
      );
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
        transferServiceOverride: FakeLanTransferService(),
        discoveryServiceOverride: FakeLanDiscoveryService(),
      );
      await coordinator.ensureInitialized();

      final result = await coordinator.connectConfiguredRelay();

      expect(result, isA<NetworkFailure<void>>());
      expect(
        (result as NetworkFailure<void>).error.code,
        NetworkErrorCode.relayError,
      );
      expect(
        networkRuntime.requestedCapabilities,
        contains(LanShareRuntimeRequest.webSocketRelay),
      );
      expect(networkService.configureRelayCalls, 0);
      expect(networkService.disconnectRelayCalls, 0);

      await coordinator.close();
      settings.dispose();
      await database.dispose();
    },
  );

  test(
    'data-plane credentialExpired triggers silent refresh and reconfigure',
    () async {
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings(
        relayEndpoint: 'https://relay.example.test',
      );
      final networkService = FakeLanShareNetworkService();
      final bootstrap = FakeLanShareBootstrapClient();
      final coordinator = _buildRelayCoordinator(
        database,
        settings,
        networkService,
        bootstrap,
      );
      await coordinator.ensureInitialized();

      final enroll = await coordinator.enrollRelay(
        endpoint: Uri.parse('https://relay.example.test'),
        enrollmentToken: '0123456789abcdef',
      );
      expect(enroll, isA<NetworkSuccess<void>>());
      expect(networkService.configureRelayCalls, 1);

      networkService.emitRelayState(
        RelayConnectionState.failed,
        error: const NetworkError(
          code: NetworkErrorCode.credentialExpired,
          message: 'Relay credential expired.',
          operation: NetworkOperation.connectRelay,
          retryDisposition: RetryDisposition.refreshCredentialThenRetry,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(bootstrap.refreshCalls, 1);
      expect(networkService.configureRelayCalls, 2);
      expect(coordinator.relayStatus.enrolled, isTrue);
      expect(coordinator.relayStatus.error, isNull);

      await coordinator.close();
      settings.dispose();
      await database.dispose();
    },
  );

  test('refresh 404 stops retry and surfaces a re-enroll signal', () async {
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings(
      relayEndpoint: 'https://relay.example.test',
    );
    final networkService = FakeLanShareNetworkService();
    final bootstrap = FakeLanShareBootstrapClient(
      onRefresh: (endpoint, request) async => SdkFailure(
        const NetworkError(
          code: NetworkErrorCode.noRoute,
          message: 'Relay device is not enrolled.',
          operation: NetworkOperation.refreshCredential,
        ),
      ),
    );
    final coordinator = _buildRelayCoordinator(
      database,
      settings,
      networkService,
      bootstrap,
    );
    await coordinator.ensureInitialized();
    await coordinator.enrollRelay(
      endpoint: Uri.parse('https://relay.example.test'),
      enrollmentToken: '0123456789abcdef',
    );

    networkService.emitRelayState(
      RelayConnectionState.failed,
      error: const NetworkError(
        code: NetworkErrorCode.credentialExpired,
        message: 'Relay credential expired.',
        operation: NetworkOperation.connectRelay,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(bootstrap.refreshCalls, 1);
    expect(networkService.configureRelayCalls, 1);
    expect(coordinator.relayStatus.enrolled, isFalse);
    expect(coordinator.relayStatus.error?.code, NetworkErrorCode.noRoute);
    expect(coordinator.relayStatus.reconnectAttempt, 0);

    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });

  test(
    'retryAfter disposition schedules a reconnect after server seconds',
    () async {
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings(
        relayEndpoint: 'https://relay.example.test',
      );
      final networkService = FakeLanShareNetworkService();
      final coordinator = _buildRelayCoordinator(
        database,
        settings,
        networkService,
        FakeLanShareBootstrapClient(),
      );
      await coordinator.ensureInitialized();
      await coordinator.enrollRelay(
        endpoint: Uri.parse('https://relay.example.test'),
        enrollmentToken: '0123456789abcdef',
      );
      expect(networkService.configureRelayCalls, 1);

      networkService.emitRelayState(
        RelayConnectionState.failed,
        error: const NetworkError(
          code: NetworkErrorCode.relayError,
          message: 'Relay is busy.',
          operation: NetworkOperation.connectRelay,
          retryDisposition: RetryDisposition.retryAfter,
          retryAfterSeconds: 1,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // 重连尚未到达服务器建议的 1 秒。
      expect(networkService.configureRelayCalls, 1);
      expect(coordinator.relayStatus.reconnectAttempt, 1);

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(networkService.configureRelayCalls, 2);

      await coordinator.close();
      settings.dispose();
      await database.dispose();
    },
  );

  test('noRetry disposition stops automatic reconnect', () async {
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings(
      relayEndpoint: 'https://relay.example.test',
    );
    final networkService = FakeLanShareNetworkService();
    final coordinator = _buildRelayCoordinator(
      database,
      settings,
      networkService,
      FakeLanShareBootstrapClient(),
    );
    await coordinator.ensureInitialized();
    await coordinator.enrollRelay(
      endpoint: Uri.parse('https://relay.example.test'),
      enrollmentToken: '0123456789abcdef',
    );

    networkService.emitRelayState(
      RelayConnectionState.failed,
      error: const NetworkError(
        code: NetworkErrorCode.relayError,
        message: 'Do not retry.',
        operation: NetworkOperation.connectRelay,
        retryDisposition: RetryDisposition.noRetry,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(networkService.configureRelayCalls, 1);
    expect(coordinator.relayStatus.reconnectAttempt, 0);
    expect(
      coordinator.relayStatus.error?.retryDisposition,
      RetryDisposition.noRetry,
    );

    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });

  test('identityConflict is terminal and is surfaced without retry', () async {
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings(
      relayEndpoint: 'https://relay.example.test',
    );
    final networkService = FakeLanShareNetworkService();
    final coordinator = _buildRelayCoordinator(
      database,
      settings,
      networkService,
      FakeLanShareBootstrapClient(),
    );
    await coordinator.ensureInitialized();
    await coordinator.enrollRelay(
      endpoint: Uri.parse('https://relay.example.test'),
      enrollmentToken: '0123456789abcdef',
    );

    networkService.emitRelayState(
      RelayConnectionState.failed,
      error: const NetworkError(
        code: NetworkErrorCode.identityConflict,
        message: 'Relay device identity conflicts.',
        operation: NetworkOperation.connectRelay,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(networkService.configureRelayCalls, 1);
    expect(
      coordinator.relayStatus.error?.code,
      NetworkErrorCode.identityConflict,
    );
    expect(coordinator.relayStatus.reconnectAttempt, 0);

    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });
}
