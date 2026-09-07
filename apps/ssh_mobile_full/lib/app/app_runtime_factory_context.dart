part of 'app_runtime_factory.dart';

/// Mutable construction context used while the App Scope graph is assembled.
///
/// Keeping construction state here lets each phase own one coherent slice of the
/// graph while preserving the single cleanup stack and commit barrier.
final class _AppRuntimeFactoryContext {
  _AppRuntimeFactoryContext({
    this.suppliedAppLogService,
    this.connectionDatabase,
    this.connectionRepository,
    this.credentialRepository,
    this.hostKeyRepository,
    this.networkRuntime,
    this.networkIdentityService,
    this.lanShareDatabaseFactory,
    this.aiDatabaseFactory,
    this.playbookDatabaseFactory,
    this.ragDatabaseFactory,
    this.ragCacheStoreFactory,
    this.mcpDatabaseFactory,
    this.lanShareReceiverEnabled,
    required this.disposeLogger,
    this.lifecycleObserver,
  });

  final AppLogService? suppliedAppLogService;
  final connection_core.ConnectionDatabase? connectionDatabase;
  final connection_core.ConnectionRepository? connectionRepository;
  final connection_core.CredentialRepository? credentialRepository;
  final connection_core.HostKeyRepository? hostKeyRepository;
  final NetworkRuntime? networkRuntime;
  final NetworkIdentityService? networkIdentityService;
  final feature_lan_share.LanShareDatabaseFactory? lanShareDatabaseFactory;
  final feature_ai.AiModuleDatabaseFactory? aiDatabaseFactory;
  final feature_playbook.PlaybookModuleDatabaseFactory? playbookDatabaseFactory;
  final feature_rag.RagDatabaseFactory? ragDatabaseFactory;
  final feature_rag.RagCacheStoreFactory? ragCacheStoreFactory;
  final feature_mcp.McpModuleDatabaseFactory? mcpDatabaseFactory;
  final bool? lanShareReceiverEnabled;
  final bool disposeLogger;
  final void Function(String event)? lifecycleObserver;

  late final AppLogService logger;
  late final _CleanupStack cleanup;
  late final AppRuntimeInitializationOwner pendingInitialization;

  late final connection_core.ConnectionDatabase runtimeConnectionDatabase;
  late final connection_core.ConnectionRepository runtimeConnectionRepository;
  late final connection_core.CredentialRepository runtimeCredentialRepository;
  late final connection_core.HostKeyRepository runtimeHostKeyRepository;
  late final NetworkIdentityService runtimeNetworkIdentityService;
  late final NetworkIdentityBundle networkIdentity;
  late final NetworkRuntime runtimeNetworkRuntime;
  late final TelemetryTraceRegistry traceRegistry;
  late final RealtimeClient runtimeRealtimeClient;
  late final RealtimeMediaBackend runtimeRealtimeMediaBackend;
  late final AppRealtimeMediaSessionFactory runtimeRealtimeMediaSessionFactory;
  late final JsonBootstrapClient bootstrapClient;
  late final AppSettings appSettings;
  late final feature_webview.ClientWebViewService webViewService;
  late final AppWebViewSettingsAdapter webViewSettingsAdapter;
  late final AppDeveloperLogAdapter developerLogAdapter;
  late final AppDeveloperSettingsAdapter developerSettingsAdapter;
  late final TerminalSessionMetadataStore terminalMetadataStore;
  late final AppBootstrapCoordinator bootstrapCoordinator;
  late final ShortcutCommandService shortcutCommandService;

  late final AppSshNativeStreamConnector sshNativeStreamConnector;
  late final SshService sshService;
  late final AppTerminalSshSessionManager terminalSshManager;

  late final AppPlaybookSettingsAdapter playbookSettingsAdapter;
  late final AppPlaybookConnectionCatalogAdapter
  playbookConnectionCatalogAdapter;
  late final feature_playbook.PlaybookModule playbookModule;

  late final feature_ai.AiModule aiModule;
  late final AppAiStorageAdapter aiStorageAdapter;
  late final AppRagSettingsAdapter ragSettingsAdapter;
  late final feature_rag.RagModule ragModule;

  late final SftpService sftpService;
  late final monitoring.MonitoringModule monitoringModule;
  late final monitoring.MonitoringService monitoringService;
  late final AppAiSettingsAdapter aiSettingsAdapter;
  late final AppAiSshAdapter aiSshAdapter;
  late final AppAiSftpAdapter aiSftpAdapter;
  late final AppAiMonitoringAdapter aiMonitoringAdapter;
  late final AppAiClientSystemAdapter aiClientSystemAdapter;
  late final AppAiHealthAdapter aiHealthAdapter;
  late final AppAiWebViewAdapter aiWebViewAdapter;
  late final AppAiServerCatalogAdapter aiServerCatalogAdapter;
  late final AppAiServerDiagnosticsAdapter aiServerDiagnosticsAdapter;
  late final feature_ai.AiChatRuntimeFactory aiChatRuntimeFactory;

  late final AppMcpSettingsAdapter mcpSettingsAdapter;
  late final feature_mcp.McpModule mcpModule;
  late final AppLanShareSettingsAdapter lanShareSettingsAdapter;
  late final feature_lan_share.LanShareModule lanShareModule;
  late final NetworkFacade networkFacade;

  late final TelemetryDatabase telemetryDatabase;
  late final TelemetryClient telemetryClient;
  late final NetworkTelemetryBridge networkTelemetryBridge;
  late final TelemetryConnectivityMonitor telemetryConnectivityMonitor;
  late final AppCrashTelemetryBridge crashTelemetryBridge;
  late final TelemetryLogSink telemetryLogSink;
  late final AppDeveloperDiagnosticsAdapter developerDiagnosticsAdapter;

  Future<AppRuntime> create() async {
    logger = suppliedAppLogService ?? AppLogService();
    cleanup = _CleanupStack(observer: lifecycleObserver);
    pendingInitialization = AppRuntimeInitializationOwner(
      onError: (description, error, stackTrace) {
        logger.error(description, error: error, stackTrace: stackTrace);
      },
    );
    if (disposeLogger) {
      cleanup.add(logger.dispose, priority: _CleanupPriority.logger);
    }

    try {
      logger.install();
      logger.info('Application bootstrap started');

      await _prepareCoreResources();
      await _prepareFeatureModules();
      await _prepareNetworkResources();
      await _prepareTelemetryResources();

      final runtime = _buildRuntime();
      cleanup.commit();
      pendingInitialization.start();
      return runtime;
    } catch (error, stackTrace) {
      // Construction failed: cancel and bounded-wait every initializer before
      // releasing the partially-created App Scope graph.
      final initializersSettled = await pendingInitialization.cancelAndWait();
      if (!initializersSettled) {
        try {
          logger.warning(
            'Runtime initializer cancellation reached its bounded wait',
          );
        } catch (_) {
          // The original construction error remains authoritative.
        }
      }
      final cleanupError = await cleanup.dispose();
      if (cleanupError != null) {
        try {
          logger.error(
            'Application bootstrap cleanup failed',
            error: cleanupError.error,
            stackTrace: cleanupError.stackTrace,
          );
        } catch (_) {
          // The original construction error remains authoritative.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  String? _resolvePeerIdForConfig(connection_core.ConnectionConfig config) {
    final moduleState = lanShareModule.state;
    if (moduleState == ModuleState.registered ||
        moduleState == ModuleState.disposed) {
      return null;
    }
    return lanShareModule.coordinator.peerRegistry.peerIdForHost(config.host);
  }
}
