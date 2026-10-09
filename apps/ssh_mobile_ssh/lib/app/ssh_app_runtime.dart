// SSH-only App 的 App Scope 运行时。
//
// Runtime 持有连接数据库、直接 TCP SSH 和 Terminal Module。它不创建
// NetworkRuntime，也不初始化 Full App 的其他 Feature。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter/widgets.dart';
import 'package:ssh_core/ssh_core.dart';

import 'ssh_app_ports.dart';
import 'ssh_direct_shell.dart';
import 'ssh_host_key_dialog.dart';
import 'ssh_terminal_capability.dart';

/// SSH-only App 的资源 Owner。
final class SshOnlyAppRuntime implements Disposable {
  SshOnlyAppRuntime._({
    required this.logger,
    required this.navigatorKey,
    required this.hostKeyPrompts,
    required this.connectionDatabase,
    required this.connectionRepository,
    required this.credentialRepository,
    required this.sshSessionManager,
    required this.terminalCapability,
    required this.terminalModule,
    required this.settings,
    required this.shortcuts,
    required this.connections,
    required this.terminalLogger,
    required this.connectionViewModel,
    required this.uiAdapter,
  });

  /// App Scope Logger。
  final AppLoggerImpl logger;

  /// 根导航键，供连接编辑和 Host Key 对话框使用。
  final GlobalKey<NavigatorState> navigatorKey;

  /// Host Key 页面回调入口。
  final SshHostKeyPromptGateway hostKeyPrompts;

  /// Connection 数据库 Owner。
  final ConnectionDatabase? connectionDatabase;

  /// 连接结构仓储。
  final ConnectionRepository? connectionRepository;

  /// 凭据仓储。
  final CredentialRepository? credentialRepository;

  /// App Scope SSH Manager。
  final SshSessionManager sshSessionManager;

  /// 直接 TCP 终端能力。
  final SshOnlyTerminalCapability terminalCapability;

  /// Terminal Module；唯一拥有 terminal.db。
  final TerminalModule terminalModule;

  /// 终端设置 Port。
  final SshOnlySettings settings;

  /// 快捷命令 Port。
  final SshOnlyShortcuts shortcuts;

  /// 终端连接 Port。
  final SshOnlyConnections connections;

  /// 终端日志 Port。
  final SshOnlyLogger terminalLogger;

  /// 连接编辑状态。
  final ConnectionViewModel connectionViewModel;

  /// 连接编辑页的对话框适配器。
  final SshConnectionUiAdapter uiAdapter;

  Future<void>? _disposeFuture;
  bool _disposed = false;

  /// App Scope 关闭是否已经开始。
  bool get isDisposed => _disposed;

  /// 为生命周期测试创建不打开平台数据库的实例。
  @visibleForTesting
  SshOnlyAppRuntime.forTesting({
    required this.logger,
    required this.navigatorKey,
    required this.hostKeyPrompts,
    required this.sshSessionManager,
    required this.terminalCapability,
    required this.terminalModule,
    required this.settings,
    required this.shortcuts,
    required this.connections,
    required this.terminalLogger,
    required this.connectionViewModel,
    required this.uiAdapter,
    this.connectionDatabase,
    this.connectionRepository,
    this.credentialRepository,
  });

  /// 创建并初始化 SSH-only App 的资源。
  static Future<SshOnlyAppRuntime> create() async {
    final logger = AppLoggerImpl();
    final navigatorKey = GlobalKey<NavigatorState>();
    final hostKeyPrompts = SshHostKeyPromptGateway();
    final connectionDatabase = ConnectionDatabase();
    final connectionRepository = DriftConnectionRepository(
      database: connectionDatabase,
    );
    final credentialRepository = SecureCredentialRepository();
    final factory = SshClientFactory(
      credentialRepository: credentialRepository,
      hostKeyRepository: connectionRepository,
      logger: logger,
    );
    final terminalCapability = SshOnlyTerminalCapability(
      lookupConnection: connectionRepository.getConnection,
      openConnection: directTcpConnector(
        openClient: sshCoreClientOpener(factory),
      ),
      confirmHostKey: hostKeyPrompts.confirm,
    );
    final sshSessionManager = SshSessionManagerImpl(
      runtime: DesktopSshRuntime(),
      terminalCapability: terminalCapability,
    );
    final terminalModule = TerminalModule();
    final settings = SshOnlySettings();
    final shortcuts = SshOnlyShortcuts();
    final connections = SshOnlyConnections(
      repository: connectionRepository,
      terminal: terminalCapability,
      navigatorKey: navigatorKey,
    );
    final terminalLogger = SshOnlyLogger(logger);
    final connectionViewModel = ConnectionViewModel(
      connectionRepository: connectionRepository,
      credentialRepository: credentialRepository,
      hostKeyRepository: connectionRepository,
      runtimePort: SshOnlyRuntimePort(terminalCapability),
      verificationPort: SshOnlyVerificationPort(
        directTcpConnector(openClient: sshCoreClientOpener(factory)),
      ),
    );
    final runtime = SshOnlyAppRuntime._(
      logger: logger,
      navigatorKey: navigatorKey,
      hostKeyPrompts: hostKeyPrompts,
      connectionDatabase: connectionDatabase,
      connectionRepository: connectionRepository,
      credentialRepository: credentialRepository,
      sshSessionManager: sshSessionManager,
      terminalCapability: terminalCapability,
      terminalModule: terminalModule,
      settings: settings,
      shortcuts: shortcuts,
      connections: connections,
      terminalLogger: terminalLogger,
      connectionViewModel: connectionViewModel,
      uiAdapter: SshConnectionUiAdapter(logger),
    );

    try {
      await connectionRepository.initialize();
      await sshSessionManager.ensureInitialized();
      await terminalModule.register(
        ModuleContext.fromMap({SshSessionManager: sshSessionManager}),
      );
      await terminalModule.initialize();
      await terminalModule.activate();
      return runtime;
    } catch (error, stackTrace) {
      try {
        await runtime.dispose();
      } catch (_) {
        // 初始化失败仍以原始错误为准。
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// 按 ViewModel → Module → SSH → 数据库 → Port → Logger 释放资源。
  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeResources() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await attempt(connectionViewModel.dispose);
    await attempt(terminalModule.dispose);
    await attempt(terminalCapability.close);
    await attempt(sshSessionManager.close);
    final database = connectionDatabase;
    if (database != null) await attempt(database.dispose);
    await attempt(settings.dispose);
    await attempt(shortcuts.dispose);
    await attempt(logger.dispose);

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }
}
