// SSH-only App 注入给 Connection 和 Terminal Feature 的 Port。
//
// 这些适配器只转发本 App 的直接 TCP SSH Owner，不复制 Full App 的
// SFTP、监控或网络传输服务。

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter/material.dart';
import 'package:ssh_core/ssh_core.dart';

import 'ssh_direct_session.dart';
import 'ssh_host_key_dialog.dart';
import 'ssh_terminal_capability.dart';

/// SSH-only App 的终端外观设置。
final class SshOnlySettings extends ChangeNotifier
    implements TerminalSettingsPort {
  /// 使用中文和默认终端外观创建设置。
  SshOnlySettings();

  @override
  Object language = AppLanguage.zh;

  @override
  bool isDarkMode = false;

  @override
  bool oledDark = false;

  @override
  String terminalThemeId = 'default';

  @override
  String terminalFontFamily = '';

  @override
  void toggleTheme() {
    isDarkMode = !isDarkMode;
    notifyListeners();
  }

  @override
  Future<void> setTerminalThemeId(String id) async {
    terminalThemeId = id;
    notifyListeners();
  }

  @override
  Future<void> setTerminalFontFamily(String family) async {
    terminalFontFamily = family;
    notifyListeners();
  }
}

/// SSH-only App 的内存快捷命令。
final class SshOnlyShortcuts extends ChangeNotifier
    implements TerminalShortcutPort {
  /// 使用终端页面的默认快捷键顺序。
  SshOnlyShortcuts();

  static const List<String> _defaultQuickCommandIds = <String>[
    'tab',
    'esc',
    'enter',
    'bksp',
    'up',
    'down',
    'left',
    'right',
    'ctrl_c',
  ];

  List<String> _quickCommandIds = List<String>.unmodifiable(
    _defaultQuickCommandIds,
  );
  List<TerminalShortcutCommand> _customCommands = const [];
  int _orderVersion = 0;

  @override
  int get orderVersion => _orderVersion;

  @override
  List<TerminalShortcutCommand> get customCommands => _customCommands;

  @override
  List<String> get quickCommandIds => _quickCommandIds;

  @override
  List<TerminalShortcutCommand> sortByUsage(
    List<TerminalShortcutCommand> commands,
  ) => List<TerminalShortcutCommand>.unmodifiable(commands);

  @override
  Future<void> recordUse(String id) async {}

  @override
  Future<void> reorderCommands(List<String> ids) async {
    _quickCommandIds = List<String>.unmodifiable(ids);
    _orderVersion++;
    notifyListeners();
  }

  @override
  Future<void> setQuickCommandIds(Iterable<String> ids) async {
    _quickCommandIds = List<String>.unmodifiable(ids);
    notifyListeners();
  }

  @override
  Future<void> resetQuickCommandIds() async {
    _quickCommandIds = List<String>.unmodifiable(_defaultQuickCommandIds);
    _orderVersion++;
    notifyListeners();
  }

  @override
  Future<void> addCustomCommand(String label, String code) async {
    final id = 'custom-${_customCommands.length + 1}';
    _customCommands = List<TerminalShortcutCommand>.unmodifiable([
      ..._customCommands,
      TerminalShortcutCommand(id: id, label: label, code: code, custom: true),
    ]);
    notifyListeners();
  }

  @override
  Future<void> removeCustomCommand(String id) async {
    _customCommands = List<TerminalShortcutCommand>.unmodifiable(
      _customCommands.where((command) => command.id != id),
    );
    notifyListeners();
  }
}

/// 把 Connection Core 和终端能力暴露给 Terminal 页面。
final class SshOnlyConnections implements TerminalConnectionPort {
  /// 创建连接导航适配器。
  const SshOnlyConnections({
    required this.repository,
    required this.terminal,
    required this.navigatorKey,
  });

  /// App Scope 连接仓储。
  final ConnectionRepository repository;

  /// App Scope 终端能力。
  final SshTerminalCapability terminal;

  /// 用于打开连接编辑页的导航键。
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  TerminalConnectionInfo? getConnection(String connectionId) {
    final config = repository.getConnection(connectionId);
    if (config == null) return null;
    return TerminalConnectionInfo(
      id: config.id,
      name: config.name,
      host: config.host,
      port: config.port,
      username: config.username,
    );
  }

  @override
  String defaultDisplayNameForConnection(String connectionId) {
    return repository.getConnection(connectionId)?.name ?? connectionId;
  }

  @override
  Future<String?> openSession(String connectionId, {String? displayName}) {
    return terminal.openSession(connectionId, displayName: displayName);
  }

  @override
  Future<void> openConnectionEditor(
    String connectionId, {
    bool isNew = false,
  }) async {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    if (isNew) {
      await navigator.pushNamed(ConnectionRouteNames.add);
      return;
    }
    await navigator.pushNamed(
      ConnectionRouteNames.edit,
      arguments: connectionId,
    );
  }
}

/// 把 App Logger 转成 Terminal 日志 Port。
final class SshOnlyLogger implements TerminalLoggerPort {
  /// 创建日志适配器。
  const SshOnlyLogger(this.logger);

  /// App Scope Logger。
  final AppLogger logger;

  @override
  void info(String message) => _write(LogLevel.info, message);

  @override
  void warning(String message, {Object? error, StackTrace? stackTrace}) {
    _write(LogLevel.warning, message, error: error, stackTrace: stackTrace);
  }

  @override
  void error(String message, {Object? error, StackTrace? stackTrace}) {
    _write(LogLevel.error, message, error: error, stackTrace: stackTrace);
  }

  void _write(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    logger.log(
      LogRecord(
        timestamp: DateTime.now(),
        level: level,
        source: 'ssh_app',
        message: message,
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }
}

/// 保存前的直接 TCP 登录验证。信任结果只作为候选返回。
final class SshOnlyVerificationPort implements ConnectionVerificationPort {
  /// 创建验证 Port。
  const SshOnlyVerificationPort(this._openConnection);

  final SshDirectConnector _openConnection;

  @override
  Future<ConnectionVerificationResult> verify(
    ConnectionConfig config, {
    required String? password,
    required String? privateKey,
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final session = await _openConnection(
      config,
      onUnknownHostKey: onUnknownHostKey == null
          ? null
          : (request) => onUnknownHostKey(
              ConnectionHostKeyPrompt(
                connectionId: request.connectionId,
                connectionName: request.connectionName,
                host: request.host,
                port: request.port,
                username: request.username,
                algorithm: request.algorithm,
                fingerprint: request.fingerprint,
              ),
            ),
      persistHostKeyTrust: false,
      credentials: SshCredentials(password: password, privateKey: privateKey),
    );
    try {
      return ConnectionVerificationResult(
        algorithm: config.hostKeyAlgorithm,
        fingerprint: config.hostKeyFingerprint,
        trustedAt: config.hostKeyTrustedAt,
      );
    } finally {
      await session.close();
    }
  }
}

/// 连接编辑器可调用的终端窗口操作。
final class SshOnlyRuntimePort implements ConnectionRuntimePort {
  /// 创建运行时 Port。
  const SshOnlyRuntimePort(this._terminal);

  final SshOnlyTerminalCapability _terminal;

  @override
  String? get errorMessage => _terminal.errorMessage;

  @override
  Future<int> activeWindowCount(String connectionId) async {
    return _terminal.sessions
        .where(
          (session) =>
              session.connectionId == connectionId && session.isConnected,
        )
        .length;
  }

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) async {
    final ids = _terminal.sessions
        .where((session) => session.connectionId == connectionId)
        .map((session) => session.id)
        .toList(growable: false);
    for (final id in ids) {
      await _terminal.disconnectSession(id);
    }
  }

  @override
  Future<void> cleanupConnectionResources(String connectionId) {
    return disconnectSessionsForConnection(connectionId);
  }

  @override
  Future<String?> openTerminalSession(
    String connectionId,
    String windowName, {
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) {
    return _terminal.openSession(connectionId, displayName: windowName);
  }
}

/// 连接编辑页的 Host Key 对话框和保存失败日志。
final class SshConnectionUiAdapter implements ConnectionUiAdapter {
  /// 创建 UI 适配器。
  const SshConnectionUiAdapter(this.logger);

  /// App Scope Logger。
  final AppLogger logger;

  @override
  Future<bool> confirmHostKey(
    BuildContext context,
    ConnectionHostKeyPrompt prompt,
  ) {
    return showSshHostKeyDialog(
      context: context,
      name: prompt.connectionName,
      host: prompt.host,
      port: prompt.port,
      username: prompt.username,
      algorithm: prompt.algorithm,
      fingerprint: prompt.fingerprint,
    );
  }

  @override
  void logSaveFailure({
    required Object error,
    required StackTrace stackTrace,
    required ConnectionConfig? config,
  }) {
    logger.log(
      LogRecord(
        timestamp: DateTime.now(),
        level: LogLevel.error,
        source: 'ssh_app',
        message: 'Connection save failed',
        details: config == null
            ? null
            : 'connection=${config.name} host=${config.host}:${config.port}',
        error: sshPublicError(error),
        stackTrace: stackTrace,
      ),
    );
  }
}
