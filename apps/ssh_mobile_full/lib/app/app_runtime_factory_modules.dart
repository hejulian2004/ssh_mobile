part of 'app_runtime_factory.dart';

/// Builds SSH, feature-module, and capability-adapter owners.
extension _AppRuntimeFactoryModules on _AppRuntimeFactoryContext {
  Future<void> _prepareFeatureModules() async {
    sshNativeStreamConnector = AppSshNativeStreamConnector(
      gatewayProvider: () => runtimeNetworkRuntime.openCommandGateway(),
      openerDeviceIdProvider: () async {
        await appSettings.ensureLanIdentity();
        return appSettings.lanDeviceId;
      },
      facadeProvider: () => networkFacade,
      traceRegistry: traceRegistry,
    );
    cleanup.add(
      sshNativeStreamConnector.closeAll,
      priority: _CleanupPriority.ssh,
    );
    sshService = SshService(
      connectionRepository: runtimeConnectionRepository,
      credentialRepository: runtimeCredentialRepository,
      hostKeyRepository: runtimeHostKeyRepository,
      terminalMetadataStore: terminalMetadataStore,
      appSettings: appSettings,
      nativeStreamConnector: sshNativeStreamConnector,
      peerIdResolver: _resolvePeerIdForConfig,
    );
    terminalSshManager = AppTerminalSshSessionManager(sshService);
    cleanup.add(terminalSshManager.close, priority: _CleanupPriority.ssh);
    // SSH owns a lazy lifecycle: connection/terminal actions call
    // ensureInitialized() immediately before their first use. Starting the
    // background event bridge and tmux restoration here only adds cold-start
    // work for users who never open an SSH session.

    playbookSettingsAdapter = AppPlaybookSettingsAdapter(appSettings);
    cleanup.add(
      playbookSettingsAdapter.dispose,
      priority: _CleanupPriority.adapter,
    );
    playbookConnectionCatalogAdapter = AppPlaybookConnectionCatalogAdapter(
      runtimeConnectionRepository,
    );
    cleanup.add(
      playbookConnectionCatalogAdapter.dispose,
      priority: _CleanupPriority.adapter,
    );
    playbookModule = feature_playbook.PlaybookModule(
      databaseFactory: playbookDatabaseFactory,
    );
    cleanup.add(playbookModule.dispose, priority: _CleanupPriority.module);
    await playbookModule.register(
      ModuleContext.fromMap({
        feature_playbook.PlaybookSettingsPort: playbookSettingsAdapter,
        feature_playbook.PlaybookConnectionCatalogPort:
            playbookConnectionCatalogAdapter,
        feature_playbook.PlaybookSshPort: AppPlaybookSshAdapter(sshService),
        feature_playbook.PlaybookLoggerPort: AppPlaybookLoggerAdapter(logger),
        feature_playbook.PlaybookDataProtectionPort:
            AppPlaybookDataProtectionAdapter(DataProtectionService.instance),
      }),
    );
    await playbookModule.initialize();
    await playbookModule.activate();

    aiModule = feature_ai.AiModule(databaseFactory: aiDatabaseFactory);
    cleanup.add(aiModule.dispose, priority: _CleanupPriority.module);
    aiStorageAdapter = AppAiStorageAdapter(
      connectionRepository: runtimeConnectionRepository,
      credentialRepository: runtimeCredentialRepository,
      hostKeyRepository: runtimeHostKeyRepository,
      playbookRepository: playbookModule.repository,
      aiModule: aiModule,
      terminalMetadataStore: terminalMetadataStore,
    );
    cleanup.add(aiStorageAdapter.dispose, priority: _CleanupPriority.adapter);
    cleanup.add(aiStorageAdapter.shutdown, priority: _CleanupPriority.adapter);
    aiStorageAdapter.registerOnImportCallback(appSettings.init);
    aiStorageAdapter.registerOnImportCallback(shortcutCommandService.init);
    pendingInitialization.add(
      start: (_) => aiStorageAdapter.init(),
      cancel: aiStorageAdapter.shutdown,
      description: 'AI storage preferences initialization failed',
    );

    ragSettingsAdapter = AppRagSettingsAdapter(appSettings, aiStorageAdapter);
    cleanup.add(ragSettingsAdapter.dispose, priority: _CleanupPriority.adapter);
    ragModule = feature_rag.RagModule(
      databaseFactory: ragDatabaseFactory,
      cacheStoreFactory: ragCacheStoreFactory,
    );
    cleanup.add(ragModule.dispose, priority: _CleanupPriority.module);
    await ragModule.register(
      ModuleContext.fromMap({
        feature_rag.RagSettingsPort: ragSettingsAdapter,
        feature_rag.RagLoggerPort: AppRagLoggerAdapter(logger),
      }),
    );
    await ragModule.initialize();
    await ragModule.activate();

    sftpService = SftpService(
      connectionRepository: runtimeConnectionRepository,
      credentialRepository: runtimeCredentialRepository,
      hostKeyRepository: runtimeHostKeyRepository,
      nativeStreamConnector: sshNativeStreamConnector,
      peerIdResolver: _resolvePeerIdForConfig,
    );
    cleanup.add(sftpService.dispose, priority: _CleanupPriority.sftp);
    monitoringModule = monitoring.MonitoringModule();
    cleanup.add(monitoringModule.dispose, priority: _CleanupPriority.module);
    await monitoringModule.register(
      ModuleContext.fromMap({
        monitoring.MonitoringSshPort: AppMonitoringSshAdapter(sshService),
        monitoring.MonitoringConnectionCatalogPort:
            AppMonitoringConnectionCatalogAdapter(runtimeConnectionRepository),
        monitoring.MonitoringLoggerPort: AppMonitoringLoggerAdapter(logger),
        monitoring.MonitoringBackgroundPort: AppMonitoringBackgroundAdapter(
          appSettings,
        ),
      }),
    );
    await monitoringModule.initialize();
    await monitoringModule.activate();
    monitoringService = monitoringModule.service;
    aiSettingsAdapter = AppAiSettingsAdapter(appSettings);
    cleanup.add(aiSettingsAdapter.dispose, priority: _CleanupPriority.adapter);
    aiSshAdapter = AppAiSshAdapter(sshService);
    aiSftpAdapter = AppAiSftpAdapter(sftpService);
    aiMonitoringAdapter = AppAiMonitoringAdapter(monitoringService);
    aiClientSystemAdapter = AppAiClientSystemAdapter();
    aiHealthAdapter = AppAiHealthAdapter(aiClientSystemAdapter);
    aiWebViewAdapter = AppAiWebViewAdapter(delegate: webViewService);
    aiServerCatalogAdapter = AppAiServerCatalogAdapter(
      connectionRepository: runtimeConnectionRepository,
      credentialRepository: runtimeCredentialRepository,
      hostKeyRepository: runtimeHostKeyRepository,
      ssh: sshService,
      sftp: sftpService,
    );
    aiServerDiagnosticsAdapter = AppAiServerDiagnosticsAdapter(
      connectionRepository: runtimeConnectionRepository,
      ssh: sshService,
    );
    final aiRagCapability = AppAiRagCapabilityAdapter(ragModule.service);
    final aiDataProtectionAdapter = AppAiDataProtectionAdapter(
      DataProtectionService.instance,
    );
    final aiLoggerAdapter = AppAiLoggerAdapter(logger);
    await aiModule.register(
      ModuleContext.fromMap({
        feature_ai.AiStoragePort: aiStorageAdapter,
        feature_ai.AiSettingsPort: aiSettingsAdapter,
        feature_ai.AiTextProtectionPort: aiDataProtectionAdapter,
        feature_ai.AiLoggerPort: aiLoggerAdapter,
      }),
    );
    aiChatRuntimeFactory = feature_ai.AiChatRuntimeFactory(
      storageService: aiStorageAdapter,
      sshService: aiSshAdapter,
      sftpService: aiSftpAdapter,
      performanceMonitorService: aiMonitoringAdapter,
      playbookService: playbookModule.service,
      ragService: aiRagCapability,
      appSettings: aiSettingsAdapter,
      clientSystemToolService: aiClientSystemAdapter,
      clientHealthAdvisor: aiHealthAdapter,
      clientWebViewService: aiWebViewAdapter,
      serverCatalogService: aiServerCatalogAdapter,
      serverDiagnosticsService: aiServerDiagnosticsAdapter,
    );
    mcpSettingsAdapter = AppMcpSettingsAdapter(appSettings);
    cleanup.add(mcpSettingsAdapter.dispose, priority: _CleanupPriority.adapter);
    mcpModule = feature_mcp.McpModule(databaseFactory: mcpDatabaseFactory);
    cleanup.add(mcpModule.dispose, priority: _CleanupPriority.module);
    await mcpModule.register(
      ModuleContext.fromMap({
        feature_mcp.McpSettingsPort: mcpSettingsAdapter,
        feature_mcp.McpLoggerPort: AppMcpLoggerAdapter(logger),
        feature_mcp.McpToolRuntimePort: AppMcpToolRuntimeAdapter(
          () => AppAiToolExecutorAdapter(
            aiChatRuntimeFactory.createToolService(),
          ),
        ),
      }),
    );
    await mcpModule.initialize();
    await mcpModule.activate();
  }
}
