part of 'app_runtime_factory.dart';

/// Builds durable telemetry, crash reporting, and developer diagnostics owners.
extension _AppRuntimeFactoryTelemetry on _AppRuntimeFactoryContext {
  Future<void> _prepareTelemetryResources() async {
    // The Relay gate is evaluated during composition, before the deferred
    // AppSettings initializer runs. Load the persisted endpoint here so a
    // previously enrolled device is not treated as unconfigured on startup.
    await appSettings.ensureCoreLoaded();

    // 这里只登记 AppRuntime 能直接观测到的数据库；Terminal/SFTP 数据库
    // 由 Route Scope 持有，不在 App Scope 诊断中伪装成已打开资源。
    const connectionDatabaseName = 'connection.sqlite';
    const appLogDatabaseName = 'app_logs';
    const aiDatabaseName = 'ai.db';
    const playbookDatabaseName = 'playbook.db';
    const ragDatabaseName = 'rag.db';
    const mcpDatabaseName = 'mcp.db';
    const lanShareDatabaseName = 'lan_share.db';
    // telemetryDatabaseName 由 telemetry_database_constants.dart 提供。

    // 生产遥测存储：SQLite（Drift），绝不使用内存或 JSONL。
    telemetryDatabase = TelemetryDatabase();
    cleanup.add(telemetryDatabase.dispose, priority: _CleanupPriority.module);
    final telemetryStorage = DriftTelemetryStorage(database: telemetryDatabase);
    final telemetryBuildMetadata = await DeviceInfoBuildMetadataProvider(
      logger: logger,
    ).load();
    // The LAN module keeps receiver activation optional, so its coordinator
    // may not have initialized the Relay enrollment owner yet. Initialize the
    // coordinator's lightweight dependencies here before evaluating the App
    // Scope telemetry gate; this does not start discovery or native listening.
    await lanShareModule.coordinator.ensureInitialized();
    final relayEnrollmentService =
        lanShareModule.coordinator.relayEnrollmentService;
    final telemetryEnrollmentProvider = relayEnrollmentService == null
        ? null
        : RelayTelemetryEnrollmentProvider(
            relayEnrollment: relayEnrollmentService,
            expectedDeviceId: appSettings.lanDeviceId,
          );
    var telemetryEnabled = await _isRelayTelemetryEnabled(
      relayEnrollmentService,
      appSettings.relayEndpoint,
    );
    if (!telemetryEnabled) {
      try {
        await telemetryEnrollmentProvider?.clearPersistedSecret();
      } on Object catch (error) {
        logger.warning(
          'Telemetry secret cleanup failed',
          details: 'errorType=${error.runtimeType}',
        );
      }
    }
    final telemetryRuntime = await createTelemetryRuntime(
      deviceId: appSettings.lanDeviceId,
      relayEndpoint: appSettings.relayEndpoint,
      buildMetadata: telemetryBuildMetadata,
      deviceEnrollmentProvider: telemetryEnrollmentProvider,
      storage: telemetryStorage,
      telemetryEnabled: telemetryEnabled,
    );
    telemetryClient = telemetryRuntime.client;
    cleanup.add(telemetryClient.dispose, priority: _CleanupPriority.module);

    // Relay enrollment is the sole App Shell activation signal. A valid
    // stored enrollment enables telemetry even while the Relay socket is
    // disconnected; clearing/expiring it disables recording immediately.
    final relayCoordinator = lanShareModule.coordinator;
    var relayGateRevision = 0;
    void onRelayChanged() {
      final revision = ++relayGateRevision;
      unawaited(
        () async {
          final enabled = await _isRelayTelemetryEnabled(
            relayEnrollmentService,
            appSettings.relayEndpoint,
          );
          if (revision != relayGateRevision || enabled == telemetryEnabled) {
            return;
          }
          telemetryEnabled = enabled;
          if (!enabled) {
            try {
              await telemetryEnrollmentProvider?.clearPersistedSecret();
            } on Object catch (error) {
              logger.warning(
                'Telemetry secret cleanup failed',
                details: 'errorType=${error.runtimeType}',
              );
            }
          }
          await telemetryClient.setTelemetryEnabled(enabled);
        }().catchError((Object error, StackTrace stackTrace) {
          logger.warning(
            'Telemetry Relay gate sync failed',
            details: 'errorType=${error.runtimeType}',
          );
        }),
      );
    }

    relayCoordinator.addListener(onRelayChanged);
    cleanup.add(() {
      relayCoordinator.removeListener(onRelayChanged);
    }, priority: _CleanupPriority.adapter);
    // 业务遥测生产者挂载：SSH / SFTP / 网络路由回退 / 崩溃捕获。
    sshService.telemetryClient = telemetryClient;
    sftpService.telemetryClient = telemetryClient;
    networkTelemetryBridge = NetworkTelemetryBridge(
      telemetryClient: telemetryClient,
      events: networkFacade.events,
      traceRegistry: traceRegistry,
    );
    networkTelemetryBridge.attach();
    cleanup.add(
      networkTelemetryBridge.dispose,
      priority: _CleanupPriority.adapter,
    );
    crashTelemetryBridge = AppCrashTelemetryBridge(
      telemetryClient: telemetryClient,
    );
    crashTelemetryBridge.install();
    cleanup.add(
      crashTelemetryBridge.dispose,
      priority: _CleanupPriority.module,
    );
    telemetryLogSink = TelemetryLogSink(client: telemetryClient);
    logger.addSink(telemetryLogSink);
    cleanup.add(() async {
      logger.removeSink(telemetryLogSink);
      await telemetryLogSink.close();
    }, priority: _CleanupPriority.module);
    pendingInitialization.add(
      start: (_) => telemetryClient.record(
        event: TelemetryEvents.appLifecycleStarted,
        properties: {'start_type': 'cold', 'cold_start': true},
      ),
      description: 'Telemetry initial lifecycle event failed',
    );

    developerDiagnosticsAdapter = AppDeveloperDiagnosticsAdapter(
      sshService: sshService,
      ragService: ragModule.service,
      mcpServer: mcpModule.service,
      performanceMonitor: monitoringService,
      logService: logger,
      telemetryClient: telemetryClient,
      modules: [
        aiModule,
        playbookModule,
        ragModule,
        mcpModule,
        lanShareModule,
        monitoringModule,
      ],
      networkRuntime: runtimeNetworkRuntime,
      databaseDescriptors: [
        developer.DeveloperDatabaseDescriptor(
          moduleId: 'connection_core',
          databaseName: connectionDatabaseName,
          isOpen: () => true,
        ),
        developer.DeveloperDatabaseDescriptor(
          moduleId: 'app_shell',
          databaseName: appLogDatabaseName,
          isOpen: () => logger.databaseOpen,
        ),
        developer.DeveloperDatabaseDescriptor(
          moduleId: 'feature_ai',
          databaseName: aiDatabaseName,
          isOpen: () => AppRuntimeFactory._isModuleDatabaseOpen(aiModule),
        ),
        developer.DeveloperDatabaseDescriptor(
          moduleId: 'feature_playbook',
          databaseName: playbookDatabaseName,
          isOpen: () => AppRuntimeFactory._isModuleDatabaseOpen(playbookModule),
        ),
        developer.DeveloperDatabaseDescriptor(
          moduleId: 'feature_rag',
          databaseName: ragDatabaseName,
          isOpen: () => AppRuntimeFactory._isModuleDatabaseOpen(ragModule),
        ),
        developer.DeveloperDatabaseDescriptor(
          moduleId: 'feature_mcp',
          databaseName: mcpDatabaseName,
          isOpen: () => AppRuntimeFactory._isModuleDatabaseOpen(mcpModule),
        ),
        developer.DeveloperDatabaseDescriptor(
          moduleId: 'feature_lan_share',
          databaseName: lanShareDatabaseName,
          isOpen: () => AppRuntimeFactory._isModuleDatabaseOpen(lanShareModule),
        ),
        developer.DeveloperDatabaseDescriptor(
          moduleId: 'telemetry',
          databaseName: telemetryDatabaseName,
          isOpen: () => true,
        ),
      ],
    );
    cleanup.add(
      developerDiagnosticsAdapter.dispose,
      priority: _CleanupPriority.adapter,
    );

    // Start recovery only after every telemetry producer and sink is attached.
    // An online-at-startup recovery can flush durable backlog immediately, so
    // starting it earlier would race bridge/sink installation.
    telemetryConnectivityMonitor = TelemetryConnectivityMonitor(
      client: telemetryClient,
      source: PlatformTelemetryConnectivitySource(),
    );
    cleanup.add(
      telemetryConnectivityMonitor.dispose,
      priority: _CleanupPriority.adapter,
    );
    // Connectivity recovery is not required to render the App Shell. Start
    // it with the existing post-commit initializer barrier so the platform
    // connectivity query cannot extend Runtime construction or first use.
    pendingInitialization.add(
      start: (_) => telemetryConnectivityMonitor.start(),
      cancel: telemetryConnectivityMonitor.dispose,
      description: 'Telemetry connectivity monitor initialization failed',
    );
  }
}

Future<bool> _isRelayTelemetryEnabled(
  feature_lan_share.LanRelayEnrollmentPort? enrollment,
  String endpointText,
) async {
  if (enrollment == null) return false;
  final endpoint = TelemetryEndpoints.validateOrigin(endpointText);
  if (endpoint == null) return false;
  try {
    return await enrollment.isEnrolled(
      feature_lan_share.RelaySettings(endpoint: endpoint),
    );
  } on Object {
    return false;
  }
}
