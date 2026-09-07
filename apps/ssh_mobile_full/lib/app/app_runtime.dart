import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:feature_ai/feature_ai.dart' as feature_ai;
import 'package:feature_developer/feature_developer.dart' as feature_developer;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:feature_webview/feature_webview.dart' as feature_webview;
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:ssh_core/ssh_core.dart';

import 'lan_share_feature_adapters.dart';
import 'ai_external_capability_adapters.dart';
import 'ai_feature_adapters.dart';
import 'mcp_feature_adapters.dart';
import 'playbook_feature_adapters.dart';
import 'rag_feature_adapters.dart';
import 'webview_feature_adapters.dart';
import 'developer_feature_adapters.dart';
import 'realtime_media_feature_adapters.dart';
import '../services/app_bootstrap_coordinator.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/network/network_identity_service.dart';
import '../services/sftp_service.dart';
import '../services/shortcut_command_service.dart';
import '../services/ssh_service.dart';
import '../services/terminal_session_metadata_store.dart';
import '../services/telemetry/network_telemetry_bridge.dart';
import '../services/telemetry/network_telemetry_connectivity.dart';
import '../services/telemetry/app_crash_telemetry_bridge.dart';
import '../services/telemetry/telemetry_span.dart';

/// 应用生命周期运行时，持有 App Scope 的基础设施和长期服务。
///
/// Runtime 只持有 App Scope 的基础设施与 Feature Module，不持有跨模块的
/// 统一数据库门面。UI 只能通过构造注入或 Provider 读取这些实例，不能
/// 自行创建同类全局对象。
final class AppRuntime implements Disposable {
  /// 创建由 AppRuntime 独占的应用级资源集合。
  AppRuntime({
    required this.appLogService,
    required this.appSettings,
    required this.connectionDatabase,
    required this.connectionRepository,
    required this.credentialRepository,
    required this.hostKeyRepository,
    required this.networkIdentityService,
    required this.networkRuntime,
    required this.networkFacade,
    required this.realtimeClient,
    required this.realtimeMediaBackend,
    required this.realtimeMediaSessionFactory,
    required this.bootstrapCoordinator,
    required this.shortcutCommandService,
    required this.terminalSessionMetadataStore,
    required this.sshSessionManager,
    required this.sshService,
    this.sshNativeStreamConnector,
    required this.sftpService,
    required this.monitoringModule,
    required this.monitoringService,
    required this.playbookModule,
    required this.playbookSettingsAdapter,
    required this.playbookConnectionCatalogAdapter,
    required this.ragModule,
    required this.ragSettingsAdapter,
    required this.mcpModule,
    required this.mcpSettingsAdapter,
    required this.lanShareModule,
    required this.lanShareSettingsAdapter,
    required this.webViewService,
    required this.webViewSettingsAdapter,
    required this.developerLogAdapter,
    required this.developerSettingsAdapter,
    required this.developerDiagnosticsAdapter,
    required this.aiModule,
    required this.aiStorageAdapter,
    required this.aiSettingsAdapter,
    required this.aiSshAdapter,
    required this.aiSftpAdapter,
    required this.aiMonitoringAdapter,
    required this.aiClientSystemAdapter,
    required this.aiHealthAdapter,
    required this.aiWebViewAdapter,
    required this.aiServerCatalogAdapter,
    required this.aiServerDiagnosticsAdapter,
    required this.aiChatRuntimeFactory,
    this.telemetryClient,
    this.telemetryConnectivityMonitor,
    this.networkTelemetryBridge,
    this.crashTelemetryBridge,
    this.telemetryLogSink,
    this.telemetryTraceRegistry,
    Future<void> Function()? awaitPendingInitialization,
    this.lifecycleObserver,
    this.disposeLogger = true,
  }) : _awaitPendingInitialization =
           awaitPendingInitialization ?? _completedFuture;

  /// App Scope 唯一的日志实现；当前由 AppLogService 适配 Core Contract。
  final AppLogService appLogService;

  /// 供新模块通过 Core Contract 获取同一个日志 Owner。
  AppLogger get logger => appLogService;

  // TODO(refactor-step-06): 替换为配置模块的公共设置契约。
  final AppSettings appSettings;

  /// Connection 模块独立数据库，由 Runtime 创建并在数据库阶段关闭。
  final connection_core.ConnectionDatabase connectionDatabase;

  /// Connection 结构 Repository 的 App Scope 唯一实例。
  final connection_core.ConnectionRepository connectionRepository;

  /// Connection 凭据 Repository 的 App Scope 唯一实例。
  final connection_core.CredentialRepository credentialRepository;

  /// Host Key 信任 Repository 的 App Scope 唯一实例。
  final connection_core.HostKeyRepository hostKeyRepository;

  /// App Scope 唯一的网络运行时；其 native handle 只按 Capability 延迟创建。
  final NetworkRuntime networkRuntime;

  /// App Scope 唯一的 Network V2 身份 Owner。
  ///
  /// Ed25519（native transport）和 X25519（E2E）材料由同一个服务加载并
  /// 缓存；Feature 通过 Port 借用它，不自行生成或持久化本机身份。
  final NetworkIdentityService networkIdentityService;

  /// App Scope Realtime SDK owner; its backend borrows the NetworkRuntime handle.
  final RealtimeClient realtimeClient;

  /// App Shell media adapter; it borrows the same Runtime and exposes only
  /// opaque endpoint lifecycle to screen-share callers.
  final RealtimeMediaBackend realtimeMediaBackend;

  /// Creates a generation-bound media controller from a production
  /// [RealtimeSession]. The factory never derives generation from signaling
  /// revision and shares the App-owned media adapter above.
  final AppRealtimeMediaSessionFactory realtimeMediaSessionFactory;

  /// App Scope 唯一业务网络门面；由组合根在 Feature 激活前装配。
  ///
  /// LAN、SSH、Realtime 和 Relay 只借用该门面/底层 Runtime，不能重新
  /// configure、stop 或 dispose native runtime。
  final NetworkFacade networkFacade;

  /// 启动协调器属于 App Shell，负责首帧前后的核心初始化状态。
  final AppBootstrapCoordinator bootstrapCoordinator;

  // TODO(refactor-step-18): 将快捷键配置迁移到 settings 模块。
  final ShortcutCommandService shortcutCommandService;

  /// SSH 关闭后排空并释放的 App Scope 偏好/终端元数据 Owner。
  final TerminalSessionMetadataStore terminalSessionMetadataStore;

  // 旧 API 兼容视图；实际 App Scope Owner 由下方的 SshSessionManager 字段表达。
  final SshService sshService;

  /// App Scope 唯一 SSH Manager；旧 [sshService] 是同一实例的兼容类型视图。
  final SshSessionManager sshSessionManager;

  /// App Scope 的 native SSH ReliableStream 连接器；null 表示未启用 native 传输。
  final SshNativeStreamConnector? sshNativeStreamConnector;

  // TODO(refactor-step-10): 替换为 sftp feature 的公共运行时契约。
  final SftpService sftpService;

  /// Monitoring Module 的 App Scope Owner；Module 不在激活时默认轮询。
  final monitoring.MonitoringModule monitoringModule;

  /// Monitoring Module 创建的唯一监控服务实例。
  final monitoring.MonitoringService monitoringService;

  /// Playbook Module 的唯一 App Scope Owner。
  final feature_playbook.PlaybookModule playbookModule;

  /// 供 Playbook Route Scope 使用的设置适配器，不拥有 AppSettings。
  final AppPlaybookSettingsAdapter playbookSettingsAdapter;

  /// 供 Playbook Route Scope 使用的连接目录适配器，不拥有底层 Repository。
  final AppPlaybookConnectionCatalogAdapter playbookConnectionCatalogAdapter;

  /// 旧 Runtime API 兼容视图；实际 Service Owner 是 [playbookModule]。
  feature_playbook.PlaybookService get playbookService =>
      playbookModule.service;

  /// RAG Module 的唯一 App Scope Owner。
  final feature_rag.RagModule ragModule;

  /// 供 RAG Route Scope 使用的设置适配器，不拥有 AppSettings 或安全存储。
  final AppRagSettingsAdapter ragSettingsAdapter;

  /// 旧 Runtime API 兼容视图；实际 Service Owner 是 [ragModule]。
  feature_rag.RagService get ragService => ragModule.service;

  /// MCP Module 的唯一 App Scope Owner；Module 独占 mcp.db 和 Server。
  final feature_mcp.McpModule mcpModule;

  /// MCP Module 使用的设置适配器，不拥有 AppSettings。
  final AppMcpSettingsAdapter mcpSettingsAdapter;

  /// 旧 Runtime API 兼容视图；实际 Owner 是 [mcpModule]。
  feature_mcp.McpServerController get mcpServerController => mcpModule.service;

  /// LAN Share Module 的唯一 App Scope Owner。
  final feature_lan_share.LanShareModule lanShareModule;

  /// 由 Runtime 持有的设置适配器；Module 只消费其 Port。
  final AppLanShareSettingsAdapter lanShareSettingsAdapter;

  /// WebView Feature 的 App Scope 会话服务；按聊天 ID 管理 Controller。
  final feature_webview.ClientWebViewService webViewService;

  /// WebView 页面消费的设置 Port，不拥有底层 AppSettings。
  final AppWebViewSettingsAdapter webViewSettingsAdapter;

  /// Developer Feature 的 App Shell Port 适配器；不把旧服务类型泄漏给页面。
  final AppDeveloperLogAdapter developerLogAdapter;
  final AppDeveloperSettingsAdapter developerSettingsAdapter;
  final AppDeveloperDiagnosticsAdapter developerDiagnosticsAdapter;

  /// 供 Provider 注册的开发者日志能力。
  feature_developer.DeveloperLogPort get developerLogPort =>
      developerLogAdapter;

  /// 供 Provider 注册的开发者设置能力。
  feature_developer.DeveloperSettingsPort get developerSettingsPort =>
      developerSettingsAdapter;

  /// 供 Provider 注册的开发者诊断能力。
  feature_developer.DeveloperDiagnosticsPort get developerDiagnosticsPort =>
      developerDiagnosticsAdapter;

  /// Telemetry 客户端运行时（若已启用）。
  final TelemetryClient? telemetryClient;

  /// App Scope owner of the connectivity subscription that triggers recovery.
  final TelemetryConnectivityMonitor? telemetryConnectivityMonitor;

  /// App Scope network telemetry borrower; disposed before its telemetry client.
  final NetworkTelemetryBridge? networkTelemetryBridge;

  /// App Scope owner of the process-global Flutter/platform crash wrappers.
  /// It is disposed before [telemetryClient] so queued reports can finish
  /// their durable SQLite write and asynchronous flush.
  final AppCrashTelemetryBridge? crashTelemetryBridge;

  /// Structured error sink attached to [appLogService] by the composition
  /// root. The sink is independent from the local app-log database and is
  /// closed before the TelemetryClient it borrows.
  final TelemetryLogSink? telemetryLogSink;

  /// App Scope owner for SSH↔network operation trace contexts.
  final TelemetryTraceRegistry? telemetryTraceRegistry;

  /// AI Module 的唯一 App Scope Owner；ai.db 只在首次 AI 使用时打开。
  final feature_ai.AiModule aiModule;

  /// AI Route 使用的 App Shell Port 适配器；它们不拥有底层 App 资源。
  final AppAiStorageAdapter aiStorageAdapter;
  final AppAiSettingsAdapter aiSettingsAdapter;
  final AppAiSshAdapter aiSshAdapter;
  final AppAiSftpAdapter aiSftpAdapter;
  final AppAiMonitoringAdapter aiMonitoringAdapter;
  final AppAiClientSystemAdapter aiClientSystemAdapter;
  final AppAiHealthAdapter aiHealthAdapter;
  final AppAiWebViewAdapter aiWebViewAdapter;
  final AppAiServerCatalogAdapter aiServerCatalogAdapter;
  final AppAiServerDiagnosticsAdapter aiServerDiagnosticsAdapter;
  final feature_ai.AiChatRuntimeFactory aiChatRuntimeFactory;

  /// 旧 API 兼容外观；实际接收器 Owner 是 [lanShareModule]。
  feature_lan_share.LanReceiverCoordinator get lanReceiverCoordinator =>
      lanShareModule.coordinator;

  /// AppRuntimeFactory 追踪的非阻塞首帧初始化屏障。
  ///
  /// 该屏障只等待已经启动的任务，不会在关闭阶段重新调用任何初始化入口。
  final Future<void> Function() _awaitPendingInitialization;

  /// 仅供生命周期回归测试观察 Owner 释放顺序；观察器异常不能改变释放行为。
  final void Function(String event)? lifecycleObserver;

  /// 是否在释放阶段关闭 AppLogService。
  ///
  /// 默认 [true]，保持生产行为（Logger 最后释放）。AppLogService 是全局单例，
  /// dispose 后无法再次使用；回归测试可以关闭该开关，避免销毁跨用例共享的
  /// 单例日志实例。
  final bool disposeLogger;

  Future<void>? _disposeFuture;
  bool _disposed = false;

  /// 当前 Runtime 是否已经开始释放资源。
  bool get isDisposed => _disposed;

  /// 按“适配器 → Module → Realtime → SFTP → SSH → Network → 数据库/设置 → Logger”顺序释放资源。
  ///
  /// 每个资源组即使释放失败也会继续执行后续释放，最后重新抛出第一个
  /// 错误，避免一个异常导致其他连接、Timer 或数据库句柄永久泄漏。
  @override
  Future<void> dispose() {
    final inFlight = _disposeFuture;
    if (inFlight != null) return inFlight;

    _disposed = true;
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeResources() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(String name, FutureOr<void> Function() action) async {
      _observe('$name.start');
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      } finally {
        _observe('$name.end');
      }
    }

    // 所有仍可能消费 App Scope 资源的异步初始化必须先完成；这里不能
    // 再调用 ensureBootstrap() 或 Repository.initialize()，否则关闭流程会
    // 在已释放的设置/数据库上重新启动一次初始化。
    await attempt('pending-initialization', _awaitPendingInitialization);

    // 先解除所有适配器订阅和设置入口，再停止它们背后的 Module。
    await attempt(
      'developer-diagnostics.dispose',
      developerDiagnosticsAdapter.dispose,
    );
    await attempt(
      'developer-diagnostics.assert-released',
      developerDiagnosticsAdapter.debugAssertReleased,
    );
    await attempt('developer-log.dispose', developerLogAdapter.dispose);
    await attempt(
      'developer-settings.dispose',
      developerSettingsAdapter.dispose,
    );
    await attempt('bootstrap.dispose', bootstrapCoordinator.dispose);
    await attempt('ai-settings.dispose', aiSettingsAdapter.dispose);
    await attempt('ai-storage.shutdown', aiStorageAdapter.shutdown);
    await attempt('ai-storage.dispose', aiStorageAdapter.dispose);
    await attempt('webview-settings.dispose', webViewSettingsAdapter.dispose);
    await attempt('webview.dispose', webViewService.dispose);
    await attempt('mcp-settings.dispose', mcpSettingsAdapter.dispose);
    await attempt(
      'lan-share-settings.dispose',
      lanShareSettingsAdapter.dispose,
    );
    await attempt('rag-settings.dispose', ragSettingsAdapter.dispose);
    await attempt('playbook-settings.dispose', playbookSettingsAdapter.dispose);
    await attempt(
      'playbook-connection-catalog.dispose',
      playbookConnectionCatalogAdapter.dispose,
    );

    await attempt(
      'telemetry-connectivity-monitor.dispose',
      () => telemetryConnectivityMonitor?.dispose() ?? Future<void>.value(),
    );
    await attempt(
      'network-telemetry-bridge.dispose',
      () => networkTelemetryBridge?.dispose() ?? Future<void>.value(),
    );

    await attempt(
      'crash-telemetry-bridge.dispose',
      () => crashTelemetryBridge?.dispose() ?? Future<void>.value(),
    );
    await attempt('telemetry-log-sink.dispose', () async {
      final sink = telemetryLogSink;
      if (sink == null) return;
      appLogService.removeSink(sink);
      await sink.close();
    });

    // App Scope Module 先停止对外提供服务，避免释放基础设施时仍有新请求进入。
    if (telemetryClient != null) {
      await attempt('telemetry.flush', telemetryClient!.flush);
      await attempt('telemetry.dispose', telemetryClient!.dispose);
    }
    await attempt('mcp-module.dispose', mcpModule.dispose);
    await attempt(
      'mcp-module.assert-disposed',
      () => _debugAssertModuleDisposed(mcpModule),
    );
    await attempt('lan-share-module.dispose', lanShareModule.dispose);
    await attempt(
      'lan-share-module.assert-disposed',
      () => _debugAssertModuleDisposed(lanShareModule),
    );
    await attempt('ai-module.dispose', aiModule.dispose);
    await attempt(
      'ai-module.assert-disposed',
      () => _debugAssertModuleDisposed(aiModule),
    );
    await attempt('playbook-module.dispose', playbookModule.dispose);
    await attempt(
      'playbook-module.assert-disposed',
      () => _debugAssertModuleDisposed(playbookModule),
    );
    await attempt('rag-module.dispose', ragModule.dispose);
    await attempt(
      'rag-module.assert-disposed',
      () => _debugAssertModuleDisposed(ragModule),
    );
    await attempt('monitoring-module.dispose', monitoringModule.dispose);
    await attempt(
      'monitoring-module.assert-disposed',
      () => _debugAssertModuleDisposed(monitoringModule),
    );
    await attempt('monitoring-service.assert-stopped', () {
      assert(!monitoringService.isRunning);
    });

    // Feature borrowers 已停止后，先释放共享 Facade 的 Session/event 订阅。
    await attempt('network-facade.dispose', networkFacade.dispose);

    // Realtime adapter 先取消命令和事件订阅；它只借用 NetworkRuntime。
    await attempt('realtime.dispose', realtimeClient.dispose);

    // SFTP 仍是 App Shell 兼容服务，必须在 SSH Manager 释放前停止自己的工作。
    await attempt('sftp.dispose', sftpService.dispose);

    // SSH Manager 统一关闭共享 Session Pool、Runtime 和旧 API 兼容资源。
    await attempt('ssh.close', sshSessionManager.close);
    await attempt('ssh.assert-released', () {
      assert(() {
        if (sshService.activeSubscriptionCount != 0 ||
            sshService.activeTimerCount != 0 ||
            sshService.leaseCount != 0) {
          throw StateError('SSH resources were not released.');
        }
        return true;
      }());
    });
    await attempt(
      'telemetry-trace-registry.dispose',
      () => telemetryTraceRegistry?.dispose(),
    );

    await attempt(
      'terminal-metadata.dispose',
      terminalSessionMetadataStore.dispose,
    );

    // SSH/SFTP 停止后再关闭网络 Runtime，避免仍有会话向 native handle 发命令。
    await attempt('network.dispose', networkRuntime.dispose);
    await attempt('network.assert-native-handles-released', () {
      assert(() {
        if (networkRuntime.diagnostics.nativeHandles != 0) {
          throw StateError('Network native handles were not released.');
        }
        return true;
      }());
    });

    // 关闭数据库前不再重试 Repository 初始化；pending barrier 已经等待了
    // 原有首载任务，避免 shutdown 后重新打开 Drift 句柄。
    await attempt('shortcut-command.dispose', shortcutCommandService.dispose);
    await attempt('connection-database.dispose', connectionDatabase.dispose);
    await attempt('app-settings.dispose', appSettings.dispose);

    // Logger 必须最后释放，因为上面的资源可能仍需记录关闭失败。
    if (disposeLogger) {
      await attempt('app-log.dispose', appLogService.dispose);
      await attempt('app-log.assert-released', () {
        assert(appLogService.activeTimerCount == 0);
      });
    }

    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStackTrace ?? StackTrace.current);
    }
  }

  static Future<void> _completedFuture() async {}

  void _observe(String event) {
    try {
      lifecycleObserver?.call(event);
    } catch (_) {
      // 生命周期观察仅用于诊断/测试，不能改变资源释放结果。
    }
  }

  /// Debug 模式下确认 Module 的生命周期 Owner 已完成资源释放。
  static void _debugAssertModuleDisposed(AppModule module) {
    assert(() {
      if (module.state != ModuleState.disposed) {
        throw StateError('Module ${module.id} was not disposed.');
      }
      return true;
    }());
  }
}
