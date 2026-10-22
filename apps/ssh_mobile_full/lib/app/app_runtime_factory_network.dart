part of 'app_runtime_factory.dart';

/// Maps LAN's two runtime requests onto the App-owned [NetworkRuntime].
final class _LanShareNetworkRuntimeAdapter
    implements feature_lan_share.LanShareNetworkRuntimePort {
  const _LanShareNetworkRuntimeAdapter(this._runtime);

  final NetworkRuntime _runtime;

  @override
  Future<void> ensureRuntime() =>
      _runtime.ensureCapability(NetworkCapability.runtime);

  @override
  Future<void> ensureWebSocketRelay() =>
      _runtime.ensureCapability(NetworkCapability.webSocketRelay);

  @override
  int? get boundLocalPort => _runtime.diagnostics.boundLocalPort;
}

/// Configures the shared Network V2 facade and registers the LAN module.
extension _AppRuntimeFactoryNetwork on _AppRuntimeFactoryContext {
  Future<void> _prepareNetworkResources() async {
    lanShareSettingsAdapter = AppLanShareSettingsAdapter(appSettings);
    cleanup.add(
      lanShareSettingsAdapter.dispose,
      priority: _CleanupPriority.adapter,
    );
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
        if (Platform.isWindows)
          feature_lan_share.LanShareDiscoveryBridgePort:
              AppLanEmulatorDiscovery(
                host: AdbAndroidEmulatorHost(),
                logger: AppLanShareLoggerAdapter(logger),
              ),
        feature_lan_share.LanShareNetworkRuntimePort:
            _LanShareNetworkRuntimeAdapter(runtimeNetworkRuntime),
      }),
    );
    await lanShareModule.initialize();
    await lanShareModule.activate();
  }

  Future<NetworkFacade> _configureSharedNetwork(NetworkRuntime native) async {
    await appSettings.ensureLanIdentity();
    final networkIdentity = await runtimeNetworkIdentityService.loadOrCreate();
    final supportDirectory = await getApplicationSupportDirectory();
    final networkReceiveDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}network_receive',
    );
    await networkReceiveDirectory.create(recursive: true);
    await native.ensureCapability(NetworkCapability.runtime);
    final networkSessions = NativeNetworkService.fromGateway(
      await native.openCommandGateway(),
      traceRegistry: traceRegistry,
    );
    final facade = NetworkFacadeImpl(
      sessions: networkSessions,
      realtime: runtimeRealtimeClient,
    );
    try {
      final configured = await facade.start(
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
      // Use the already configured native owner here. Calling the lazy App
      // wrapper would await this initialization itself. Passive receivers must
      // observe invitations even if they have never issued Realtime commands.
      runtimeRealtimeBackend.observeGateway(await native.openRealtimeGateway());
      return facade;
    } catch (_) {
      await facade.dispose();
      rethrow;
    }
  }
}
