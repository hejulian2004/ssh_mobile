import 'dart:async';

import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_connection/feature_connection.dart'
    as feature_connection;
import 'package:feature_ai/feature_ai.dart' as feature_ai;
import 'package:app_core/app_core.dart' as app_core;
import 'package:feature_developer/feature_developer.dart' as feature_developer;
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:feature_sftp/feature_sftp.dart' as feature_sftp;
import 'package:feature_terminal/feature_terminal.dart';
import 'package:feature_webview/feature_webview.dart' as feature_webview;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart';

import '../features/settings/viewmodels/settings_viewmodel.dart';
import '../features/startup/viewmodels/startup_viewmodel.dart';
import 'package:ssh_mobile/features/home/views/home_screen.dart';
import 'package:ssh_mobile/features/startup/views/startup_screen.dart';
import '../services/app_settings.dart';
import 'package:app_ui/app_ui.dart';
import 'app_runtime.dart';
import 'connection_feature_adapters.dart';
import 'lan_share_feature_adapters.dart';
import 'terminal_feature_adapters.dart';
import 'sftp_feature_adapters.dart';
import 'rag_feature_adapters.dart';
import 'screen_share_route_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'navigation/app_route_contributions.dart';

part 'ssh_mobile_app_theme.dart';
part 'ssh_mobile_app_routes.dart';

/// App Shell。它只消费由 [AppRuntime] 创建的 App Scope 实例。
class SshMobileApp extends StatefulWidget {
  const SshMobileApp({super.key, this.runtime});

  /// 真实入口始终传入 Runtime；可空仅保留旧的构造型 smoke test 兼容面。
  final AppRuntime? runtime;

  @override
  State<SshMobileApp> createState() => _SshMobileAppState();
}

class _SshMobileAppState extends State<SshMobileApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  AppTerminalSettingsAdapter? _terminalSettingsAdapter;
  AppTerminalShortcutAdapter? _terminalShortcutAdapter;
  AppConnectionRepositoryAdapter? _connectionRepositoryAdapter;
  AppConnectionCredentialAdapter? _connectionCredentialAdapter;
  AppConnectionHostKeyAdapter? _connectionHostKeyAdapter;
  AppConnectionRuntimeAdapter? _connectionRuntimeAdapter;
  AppConnectionVerificationAdapter? _connectionVerificationAdapter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_runtime.mcpServerController.startIfEnabled());
    });
  }

  AppRuntime get _runtime {
    final runtime = widget.runtime;
    if (runtime == null) {
      throw StateError('SshMobileApp requires an AppRuntime to build.');
    }
    return runtime;
  }

  DateTime? _pausedAt;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final now = DateTime.now();
      final bgDuration = _pausedAt != null
          ? now.difference(_pausedAt!).inMilliseconds
          : 0;
      _pausedAt = null;
      _runtime.telemetryClient?.onAppForeground();
      unawaited(
        _runtime.telemetryClient?.record(
          event: app_core.TelemetryEvents.appLifecycleForegrounded,
          properties: {'background_duration_ms': bgDuration},
        ),
      );
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_pausedAt == null && state == AppLifecycleState.paused) {
        _pausedAt = DateTime.now();
      }
      _runtime.telemetryClient?.onAppBackground();
      unawaited(
        _runtime.telemetryClient?.record(
          event: app_core.TelemetryEvents.appLifecycleBackgrounded,
          properties: {
            'active_sessions': _runtime.sshService.activeSubscriptionCount,
          },
        ),
      );
      unawaited(_runtime.aiStorageAdapter.flushPendingWrites());
    }
    if (state == AppLifecycleState.detached) {
      unawaited(_runtime.mcpServerController.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _terminalSettingsAdapter?.dispose();
    _terminalShortcutAdapter?.dispose();
    final runtime = widget.runtime;
    if (runtime != null) {
      unawaited(runtime.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime;
    final terminalSettings = _terminalSettingsAdapter ??=
        AppTerminalSettingsAdapter(runtime.appSettings);
    final terminalShortcuts = _terminalShortcutAdapter ??=
        AppTerminalShortcutAdapter(runtime.shortcutCommandService);
    final terminalConnections = AppTerminalConnectionAdapter(
      navigatorKey: _navigatorKey,
      connectionRepository: runtime.connectionRepository,
      sshService: runtime.sshService,
    );
    final terminalLogger = AppTerminalLoggerAdapter(runtime.appLogService);
    final lanLogger = AppLanShareLoggerAdapter(runtime.appLogService);
    _connectionRepositoryAdapter ??= AppConnectionRepositoryAdapter(
      primary: runtime.connectionRepository,
    );
    _connectionCredentialAdapter ??= AppConnectionCredentialAdapter(
      primary: runtime.credentialRepository,
    );
    _connectionHostKeyAdapter ??= AppConnectionHostKeyAdapter(
      primary: runtime.hostKeyRepository,
    );
    _connectionRuntimeAdapter ??= AppConnectionRuntimeAdapter(
      sshServiceFactory: () => runtime.sshService,
      sftpServiceFactory: () => runtime.sftpService,
      monitoringServiceFactory: () => runtime.monitoringService,
    );
    _connectionVerificationAdapter ??= AppConnectionVerificationAdapter(
      credentialRepository: runtime.credentialRepository,
      hostKeyRepository: runtime.hostKeyRepository,
      logger: runtime.appLogService,
    );
    return MultiProvider(
      providers: [
        // Runtime 已经拥有这些实例，.value 防止 Provider 误替它们释放。
        Provider<AppRuntime>.value(value: runtime),
        Provider<connection_core.ConnectionRepository>.value(
          value: runtime.connectionRepository,
        ),
        Provider<connection_core.CredentialRepository>.value(
          value: runtime.credentialRepository,
        ),
        Provider<connection_core.HostKeyRepository>.value(
          value: runtime.hostKeyRepository,
        ),
        Provider<SshSessionManager>.value(value: runtime.sshSessionManager),
        ListenableProvider<TerminalSettingsPort>.value(value: terminalSettings),
        ListenableProvider<TerminalShortcutPort>.value(
          value: terminalShortcuts,
        ),
        Provider<TerminalConnectionPort>.value(value: terminalConnections),
        Provider<TerminalLoggerPort>.value(value: terminalLogger),
        ChangeNotifierProvider.value(value: runtime.appLogService),
        ChangeNotifierProvider.value(value: runtime.aiStorageAdapter),
        ChangeNotifierProvider.value(value: runtime.appSettings),
        ChangeNotifierProvider<feature_webview.ClientWebViewService>.value(
          value: runtime.webViewService,
        ),
        ListenableProvider<feature_webview.WebViewSettingsPort>.value(
          value: runtime.webViewSettingsAdapter,
        ),
        ListenableProvider<feature_developer.DeveloperLogPort>.value(
          value: runtime.developerLogPort,
        ),
        ListenableProvider<feature_developer.DeveloperSettingsPort>.value(
          value: runtime.developerSettingsPort,
        ),
        ListenableProvider<feature_developer.DeveloperDiagnosticsPort>.value(
          value: runtime.developerDiagnosticsPort,
        ),
        InheritedProvider<feature_ai.AiStoragePort>.value(
          value: runtime.aiStorageAdapter,
        ),
        ListenableProvider<feature_ai.AiSettingsPort>.value(
          value: runtime.aiSettingsAdapter,
        ),
        Provider<feature_ai.AiSshPort>.value(value: runtime.aiSshAdapter),
        Provider<feature_ai.AiSftpPort>.value(value: runtime.aiSftpAdapter),
        Provider<feature_ai.AiMonitoringPort>.value(
          value: runtime.aiMonitoringAdapter,
        ),
        Provider<feature_ai.AiClientSystemPort>.value(
          value: runtime.aiClientSystemAdapter,
        ),
        Provider<feature_ai.AiHealthPort>.value(value: runtime.aiHealthAdapter),
        Provider<feature_ai.AiWebViewPort>.value(
          value: runtime.aiWebViewAdapter,
        ),
        Provider<feature_ai.AiServerCatalogPort>.value(
          value: runtime.aiServerCatalogAdapter,
        ),
        Provider<feature_ai.AiServerDiagnosticsPort>.value(
          value: runtime.aiServerDiagnosticsAdapter,
        ),
        Provider<feature_ai.AiChatRuntimeFactory>.value(
          value: runtime.aiChatRuntimeFactory,
        ),
        Provider<app_core.RagCapability>.value(
          value: AppAiRagCapabilityAdapter(runtime.ragService),
        ),
        ListenableProvider<feature_lan_share.LanShareSettingsPort>.value(
          value: runtime.lanShareSettingsAdapter,
        ),
        Provider<feature_lan_share.LanShareLoggerPort>.value(value: lanLogger),
        Provider<feature_lan_share.LanShareModule>.value(
          value: runtime.lanShareModule,
        ),
        ListenableProvider<feature_playbook.PlaybookSettingsPort>.value(
          value: runtime.playbookSettingsAdapter,
        ),
        ListenableProvider<
          feature_playbook.PlaybookConnectionCatalogPort
        >.value(value: runtime.playbookConnectionCatalogAdapter),
        ChangeNotifierProvider.value(value: runtime.bootstrapCoordinator),
        ChangeNotifierProvider.value(value: runtime.shortcutCommandService),
        ChangeNotifierProvider.value(value: runtime.sshService),
        ChangeNotifierProvider.value(value: runtime.sftpService),
        ChangeNotifierProvider.value(value: runtime.monitoringService),
        ChangeNotifierProvider.value(value: runtime.playbookService),
        ListenableProvider<feature_playbook.PlaybookAutomationPort>.value(
          value: runtime.playbookService,
        ),
        ListenableProvider<feature_rag.RagSettingsPort>.value(
          value: runtime.ragSettingsAdapter,
        ),
        ChangeNotifierProvider<feature_rag.RagService>.value(
          value: runtime.ragService,
        ),
        ListenableProvider<feature_rag.RagCapability>.value(
          value: runtime.ragService,
        ),
        ChangeNotifierProvider<feature_mcp.McpServerController>.value(
          value: runtime.mcpModule.service,
        ),
        ListenableProvider<feature_mcp.McpSettingsPort>.value(
          value: runtime.mcpSettingsAdapter,
        ),
        ChangeNotifierProvider<feature_lan_share.LanReceiverCoordinator>.value(
          value: runtime.lanReceiverCoordinator,
        ),
      ],
      child: Builder(builder: (context) => _buildApp(context)),
    );
  }

  Widget _buildApp(BuildContext context) => _buildAppWithRoutes(context);
}
