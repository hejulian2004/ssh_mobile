part of 'app_runtime_factory.dart';

/// Configures the shared Network V2 facade and registers the LAN module.
extension _AppRuntimeFactoryNetwork on _AppRuntimeFactoryContext {
  Future<void> _prepareNetworkResources() async {
    lanShareSettingsAdapter = AppLanShareSettingsAdapter(appSettings);
    cleanup.add(
      lanShareSettingsAdapter.dispose,
      priority: _CleanupPriority.adapter,
    );
    await appSettings.ensureLanIdentity();
    final supportDirectory = await getApplicationSupportDirectory();
    final networkReceiveDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}network_receive',
    );
    await networkReceiveDirectory.create(recursive: true);
    await runtimeNetworkRuntime.ensureCapability(NetworkCapability.runtime);
    final networkSessions = NativeNetworkService.fromGateway(
      await runtimeNetworkRuntime.openCommandGateway(),
      traceRegistry: traceRegistry,
    );
    networkFacade = NetworkFacadeImpl(
      sessions: networkSessions,
      realtime: runtimeRealtimeClient,
    );
    cleanup.add(networkFacade.dispose, priority: _CleanupPriority.realtime);
    final configured = await networkFacade.start(
      NetworkRuntimeConfig(
        deviceId: appSettings.lanDeviceId,
        identityPrivateKey: networkIdentity.ed25519PrivateSeed,
        e2ePrivateKey: networkIdentity.x25519PrivateSeed,
        listenAddress: '0.0.0.0:0',
        receiveDirectory: networkReceiveDirectory.path,
      ),
    );
    if (configured is NetworkFailure<void>) {
      throw StateError(
        'App network runtime configuration failed: '
        '${configured.error.code.name}',
      );
    }
    lanShareModule = feature_lan_share.LanShareModule(
      receiverEnabled: lanShareReceiverEnabled,
      databaseFactory: lanShareDatabaseFactory,
    );
    cleanup.add(lanShareModule.dispose, priority: _CleanupPriority.module);
    await lanShareModule.register(
      ModuleContext.fromMap({
        feature_lan_share.LanShareSettingsPort: lanShareSettingsAdapter,
        feature_lan_share.LanShareLoggerPort: AppLanShareLoggerAdapter(logger),
        feature_lan_share.LanShareDataProtectionPort:
            AppLanShareDataProtectionAdapter(DataProtectionService.instance),
        feature_lan_share.LanShareNetworkIdentityPort:
            AppLanShareNetworkIdentityAdapter(runtimeNetworkIdentityService),
        feature_lan_share.LanShareNetworkAccessPort:
            AppLanShareNetworkAccessAdapter(networkFacade),
        feature_lan_share.LanShareLocalAddressSelectionPort:
            createLanShareLocalAddressSelectionPort(
              isWindows: Platform.isWindows,
            ),
        BootstrapClient: bootstrapClient,
        NetworkRuntime: runtimeNetworkRuntime,
      }),
    );
    await lanShareModule.initialize();
    await lanShareModule.activate();
  }
}
