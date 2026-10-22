// Terminal 窗口管理页的 Route Scope ViewModel。
//
// SSH 会话只从注入的 SshSessionManager Capability 读取；页面离开时取消
// changes 订阅，不关闭 App Scope SSH Manager。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart';

import '../domain/terminal_models.dart';
import '../domain/terminal_ports.dart';
import 'terminal_window_snapshot.dart';

/// 终端窗口列表和批量选择状态。
final class TerminalWindowsViewModel extends ChangeNotifier {
  /// 创建窗口管理 ViewModel。
  TerminalWindowsViewModel({
    required this._sshSessionManager,
    required this._settings,
  }) {
    _changesSubscription = _terminal.changes.listen((_) => _onServiceChanged());
    _settings.addListener(_onSettingsChanged);
  }

  /// 从 Scope 中已注入的 SSH Manager 创建窗口 ViewModel。
  factory TerminalWindowsViewModel.fromContext(
    BuildContext context, {
    required TerminalSettingsPort settings,
  }) {
    return TerminalWindowsViewModel(
      sshSessionManager: context.read<SshSessionManager>(),
      settings: settings,
    );
  }

  final SshSessionManager _sshSessionManager;
  final TerminalSettingsPort _settings;
  final Set<String> _selectedSessionIds = <String>{};
  StreamSubscription<void>? _changesSubscription;
  bool _selectionMode = false;
  bool _disposed = false;

  /// 可选的连接过滤器。
  String? connectionId;

  SshTerminalCapability get _terminal =>
      _sshSessionManager.terminalCapability ??
      (throw StateError('SSH Manager has no Terminal capability.'));

  @override
  void dispose() {
    _disposed = true;
    _changesSubscription?.cancel();
    _settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (_disposed) return;
    final availableIds = sessions.map((session) => session.id).toSet();
    _selectedSessionIds.retainAll(availableIds);
    _selectionMode = _selectedSessionIds.isNotEmpty;
    notifyListeners();
  }

  void _onSettingsChanged() {
    if (!_disposed) notifyListeners();
  }

  /// 当前过滤后的窗口快照。
  List<TerminalWindowSnapshot> get sessions => [
    for (final session in _terminal.sessions)
      if (connectionId == null || session.connectionId == connectionId)
        terminalWindowSnapshotOf(session),
  ];

  /// 最近一次 Capability 级错误。
  String? get capabilityError =>
      _sshSessionManager.terminalCapability?.errorMessage;

  /// 按会话 ID 查找窗口，不受当前连接过滤影响。
  TerminalWindowSnapshot? windowById(String id) {
    final session = _terminal.getSession(id);
    if (session == null) return null;
    return terminalWindowSnapshotOf(session);
  }

  Set<String> get selectedSessionIds => _selectedSessionIds;
  bool get selectionMode => _selectionMode;
  Object get language => _settings.language;

  /// 切换一个窗口的选择状态。
  void toggleSelection(String sessionId) {
    if (_selectedSessionIds.contains(sessionId)) {
      _selectedSessionIds.remove(sessionId);
    } else {
      _selectedSessionIds.add(sessionId);
    }
    _selectionMode = _selectedSessionIds.isNotEmpty;
    notifyListeners();
  }

  /// 选择当前列表中的全部窗口。
  void selectAll() {
    _selectionMode = true;
    _selectedSessionIds
      ..clear()
      ..addAll(sessions.map((session) => session.id));
    notifyListeners();
  }

  /// 清除批量选择。
  void clearSelection() {
    _selectionMode = false;
    _selectedSessionIds.clear();
    notifyListeners();
  }

  /// 关闭一个窗口。
  Future<void> closeSession(String sessionId) async {
    await _terminal.disconnectSession(sessionId);
    _selectedSessionIds.remove(sessionId);
    if (_selectedSessionIds.isEmpty) _selectionMode = false;
    notifyListeners();
  }

  /// 按选择顺序关闭窗口。
  Future<void> closeSelectedSessions() async {
    final ids = _selectedSessionIds.toList(growable: false);
    clearSelection();
    for (final id in ids) {
      await _terminal.disconnectSession(id);
    }
  }

  /// 校验窗口名是否与当前列表冲突。
  bool isSessionNameAvailable(String sessionId, String name) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    return sessions.every(
      (session) =>
          session.id == sessionId ||
          session.displayName.trim().toLowerCase() != normalized,
    );
  }

  /// 保存新的窗口名。
  bool renameSession(String sessionId, String name) {
    return _terminal.renameSession(sessionId, name);
  }

  /// 复制清理命令。
  Future<void> copyCleanupCommand(String command) {
    return Clipboard.setData(ClipboardData(text: command));
  }
}
