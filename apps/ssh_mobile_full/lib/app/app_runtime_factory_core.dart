part of 'app_runtime_factory.dart';

/// Builds logging, persistence, identity, and lightweight App Shell resources.
extension _AppRuntimeFactoryCore on _AppRuntimeFactoryContext {
  Future<void> _prepareCoreResources() async {
    runtimeConnectionDatabase =
        connectionDatabase ?? connection_core.ConnectionDatabase();
    cleanup.add(
      runtimeConnectionDatabase.dispose,
      priority: _CleanupPriority.database,
    );
    runtimeConnectionRepository =
        connectionRepository ??
        connection_core.DriftConnectionRepository(
          database: runtimeConnectionDatabase,
        );
    runtimeCredentialRepository =
        credentialRepository ?? connection_core.SecureCredentialRepository();
    runtimeHostKeyRepository = AppRuntimeFactory._resolveHostKeyRepository(
      supplied: hostKeyRepository,
      connectionRepository: runtimeConnectionRepository,
    );
    // Keep identity and native configuration cold until a network action.
    runtimeNetworkIdentityService =
        networkIdentityService ?? NetworkIdentityService();
    final resources = AppNetworkResources(
      nativeRuntime: networkRuntime ?? NetworkRuntimeImpl(),
      initialize: _configureSharedNetwork,
      createRealtimeSession: ({required realtimeId, required peerId}) =>
          runtimeRealtimeClient.createSession(
            realtimeId: realtimeId,
            peerId: peerId,
          ),
    );
    runtimeNetworkRuntime = resources.networkRuntime;
    networkFacade = resources;
    cleanup.add(networkFacade.dispose, priority: _CleanupPriority.realtime);
    cleanup.add(
      runtimeNetworkRuntime.dispose,
      priority: _CleanupPriority.network,
    );
    traceRegistry = TelemetryTraceRegistry();
    cleanup.add(traceRegistry.dispose, priority: _CleanupPriority.adapter);
    runtimeRealtimeBackend = AppRealtimeSessionBackend(
      networkRuntime: runtimeNetworkRuntime,
    );
    runtimeRealtimeClient = RealtimeClientImpl(backend: runtimeRealtimeBackend);
    final endpointBackend = AppRealtimeMediaBackend(
      networkRuntime: runtimeNetworkRuntime,
    );
    runtimeRealtimeMediaBackend = switch (defaultTargetPlatform) {
      TargetPlatform.windows => WindowsRealtimeMediaBackend(
        endpointBackend: endpointBackend,
        platform: const MethodChannelWindowsRealtimeMediaPlatform(),
      ),
      TargetPlatform.android => AndroidRealtimeMediaBackend(
        endpointBackend: endpointBackend,
        platform: const MethodChannelAndroidRealtimeMediaPlatform(),
      ),
      _ => endpointBackend,
    };
    runtimeRealtimeMediaSessionFactory = AppRealtimeMediaSessionFactory(
      backend: runtimeRealtimeMediaBackend,
    );
    cleanup.add(
      runtimeRealtimeClient.dispose,
      priority: _CleanupPriority.realtime,
    );
    bootstrapClient = JsonBootstrapClient(
      executor: const AppSdkRequestExecutor(),
    );
    pendingInitialization.add(
      start: (_) => runtimeConnectionRepository.initialize(),
      description: 'Connection repository initialization failed',
    );

    // 这些任务原本由 main 并发发起，继续保持不阻塞 runApp 的行为；其
    // Future 由 Runtime 持有并在关闭前等待，避免失败后悬空运行。
    pendingInitialization.add(
      start: (_) => SharedPreferences.getInstance(),
      description: 'SharedPreferences initialization failed',
    );
    pendingInitialization.add(
      start: (_) => DisplayModeService.enableHighRefreshRate(),
      description: 'High refresh-rate setup failed',
    );

    appSettings = AppSettings();
    cleanup.add(appSettings.dispose, priority: _CleanupPriority.settings);
    webViewService = feature_webview.ClientWebViewService(
      logger: logger,
      networkLoader: feature_webview.ClientWebViewSafeNetworkLoader(
        resolver: const AppWebViewDnsResolver(),
        transport: const AppWebViewPinnedTransport(),
      ),
    );
    cleanup.add(webViewService.dispose, priority: _CleanupPriority.adapter);
    webViewSettingsAdapter = AppWebViewSettingsAdapter(appSettings);
    cleanup.add(
      webViewSettingsAdapter.dispose,
      priority: _CleanupPriority.adapter,
    );
    developerLogAdapter = AppDeveloperLogAdapter(logger);
    cleanup.add(
      developerLogAdapter.dispose,
      priority: _CleanupPriority.adapter,
    );
    developerSettingsAdapter = AppDeveloperSettingsAdapter(appSettings);
    cleanup.add(
      developerSettingsAdapter.dispose,
      priority: _CleanupPriority.adapter,
    );
    terminalMetadataStore = TerminalSessionMetadataStore();
    cleanup.add(
      terminalMetadataStore.dispose,
      priority: _CleanupPriority.metadata,
    );
    bootstrapCoordinator = AppBootstrapCoordinator(appSettings: appSettings);
    cleanup.add(
      bootstrapCoordinator.dispose,
      priority: _CleanupPriority.adapter,
    );
    pendingInitialization.add(
      start: (_) => bootstrapCoordinator.ensureBootstrap(),
      description: 'App bootstrap initialization failed',
    );

    shortcutCommandService = ShortcutCommandService()..init();
    cleanup.add(
      shortcutCommandService.dispose,
      priority: _CleanupPriority.adapter,
    );
  }
}
