// SSH-only App 的终端能力。
//
// 会话和 Shell 由这个 App Scope Owner 持有。Feature 只看到 ssh_core 的
// 公开快照，不能关闭底层 Client。

import 'dart:async';
import 'dart:convert';

import 'package:connection_core/connection_core.dart';
import 'package:ssh_core/ssh_core.dart';

import 'ssh_direct_session.dart';

/// 查找已保存的连接结构。
typedef SshConnectionLookup = ConnectionConfig? Function(String connectionId);

/// 直接 TCP SSH 的终端会话 Owner。
final class SshOnlyTerminalCapability implements SshTerminalCapability {
  /// 创建终端能力。
  SshOnlyTerminalCapability({
    required this.lookupConnection,
    required this.openConnection,
    required this.confirmHostKey,
    this.idFactory,
  });

  /// 读取连接结构；不包含凭据。
  final SshConnectionLookup lookupConnection;

  /// 打开已认证的直接 TCP 连接。
  final SshDirectConnector openConnection;

  /// 未知 Host Key 的确认回调。返回 false 时连接失败关闭。
  final SshHostKeyConfirmation confirmHostKey;

  /// 测试可替换的会话 ID 工厂。
  final String Function()? idFactory;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<_SshWindow> _windows = <_SshWindow>[];
  int _nextId = 0;
  String? _errorMessage;
  bool _closed = false;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  String? get errorMessage => _errorMessage;

  @override
  List<SshTerminalSession> get sessions =>
      _windows.map(_snapshot).toList(growable: false);

  @override
  SshTerminalSession? getSession(String sessionId) {
    final window = _find(sessionId);
    return window == null ? null : _snapshot(window);
  }

  @override
  Future<String> loadSessionHistoryText(String sessionId) async {
    return _find(sessionId)?.session.outputText ?? '';
  }

  @override
  bool isSessionNameAvailable(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final normalized = trimmed.toLowerCase();
    return _windows.every(
      (window) => window.session.displayName.trim().toLowerCase() != normalized,
    );
  }

  @override
  bool renameSession(String sessionId, String name) {
    final window = _find(sessionId);
    final trimmed = name.trim();
    if (window == null || trimmed.isEmpty) return false;
    final normalized = trimmed.toLowerCase();
    final taken = _windows.any(
      (other) =>
          other.session.id != sessionId &&
          other.session.displayName.trim().toLowerCase() == normalized,
    );
    if (taken) return false;
    window.session.displayName = trimmed;
    window.session.updatedAt = DateTime.now();
    _emit();
    return true;
  }

  @override
  void setSessionFontSize(String sessionId, double fontSize) {
    final window = _find(sessionId);
    if (window == null) return;
    window.session.fontSize = fontSize
        .clamp(SshSession.minTerminalFontSize, SshSession.maxTerminalFontSize)
        .toDouble();
    window.session.updatedAt = DateTime.now();
    _emit();
  }

  @override
  void sendData(String sessionId, String data) {
    final window = _find(sessionId);
    if (window == null || !window.session.isConnected || data.isEmpty) return;
    window.shell?.write(utf8.encode(data));
  }

  @override
  void resizeTerminal(String sessionId, int width, int height) {
    if (width <= 0 || height <= 0) return;
    _find(sessionId)?.shell?.resizeTerminal(width, height);
  }

  @override
  Future<String?> openSession(
    String connectionId, {
    String? displayName,
  }) async {
    if (_closed) return null;
    final config = lookupConnection(connectionId);
    if (config == null) {
      _errorMessage = 'Connection is unavailable.';
      _emit();
      return null;
    }
    final requested = (displayName ?? config.name).trim();
    final name = _uniqueName(requested.isEmpty ? config.name : requested);
    final session = SshSession(
      id: idFactory?.call() ?? 'ssh-${_nextId++}',
      connectionId: config.id,
      connectionName: config.name,
      displayName: name,
      tmuxSessionName: _tmuxSessionName(config, name),
      tmuxAutoDeleteSeconds: config.launchMode == TerminalLaunchMode.tmux
          ? config.tmuxAutoDeleteSeconds
          : null,
    );
    final window = _SshWindow(session: session, generation: ++_nextId);
    _windows.add(window);
    _errorMessage = null;
    _emit();
    try {
      await _attach(window, config);
      if (_closed || !_windows.contains(window)) return null;
      return session.id;
    } catch (error) {
      _errorMessage = sshPublicError(error);
      await _dropWindow(window);
      _emit();
      return null;
    }
  }

  @override
  Future<bool> ensureConnected(String connectionId) async {
    final connected = _windows.any(
      (window) =>
          window.session.connectionId == connectionId &&
          window.session.isConnected,
    );
    if (connected) return true;
    return await openSession(connectionId) != null;
  }

  @override
  Future<bool> ensureSessionConnected(
    String sessionId,
    String connectionId,
  ) async {
    final window = _find(sessionId);
    if (window == null || _closed) return false;
    if (window.session.isConnected) return true;
    final config = lookupConnection(connectionId);
    if (config == null) return false;
    window.generation = ++_nextId;
    await _closeTransport(window);
    window.session.state = SshConnectionState.connecting;
    window.session.errorMessage = null;
    _emit();
    try {
      await _attach(window, config);
      return window.session.isConnected;
    } catch (error) {
      window.session.state = SshConnectionState.error;
      window.session.errorMessage = sshPublicError(error);
      _errorMessage = window.session.errorMessage;
      _emit();
      return false;
    }
  }

  @override
  Future<void> disconnectSession(String sessionId) async {
    final window = _find(sessionId);
    if (window == null) return;
    await _dropWindow(window);
    _emit();
  }

  @override
  Future<void> disconnect() async {
    final windows = List<_SshWindow>.of(_windows);
    for (final window in windows) {
      await _dropWindow(window);
    }
    _emit();
  }

  /// 关闭全部 Shell 和通知流。重复调用幂等。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await disconnect();
    await _changes.close();
  }

  Future<void> _attach(_SshWindow window, ConnectionConfig config) async {
    final generation = window.generation;
    final connection = await openConnection(
      config,
      onUnknownHostKey: confirmHostKey,
      persistHostKeyTrust: true,
      credentials: null,
    );
    window.connection = connection;
    if (!_isCurrent(window, generation)) {
      await _closeTransport(window);
      return;
    }
    final shell = await connection.openShell(
      width: config.terminalWidth <= 0 ? 80 : config.terminalWidth,
      height: config.terminalHeight <= 0 ? 24 : config.terminalHeight,
      terminalType: config.serverPlatform == ServerPlatform.windows
          ? 'ms-terminal'
          : 'xterm-256color',
    );
    window.shell = shell;
    if (!_isCurrent(window, generation)) {
      await _closeTransport(window);
      return;
    }
    final tmuxName = window.session.tmuxSessionName;
    if (config.launchMode == TerminalLaunchMode.tmux &&
        tmuxName != null &&
        tmuxName.isNotEmpty) {
      final escaped = tmuxName.replaceAll("'", "'\"'\"'");
      shell.write(utf8.encode("exec tmux new-session -A -s '$escaped'\r"));
    }
    window.stdout = shell.stdout.listen((data) {
      if (!_isCurrent(window, generation)) return;
      window.session.addOutput(utf8.decode(data, allowMalformed: true));
      _emit();
    });
    window.stderr = shell.stderr.listen((data) {
      if (!_isCurrent(window, generation)) return;
      window.session.addOutput(utf8.decode(data, allowMalformed: true));
      _emit();
    });
    unawaited(
      shell.done.then((_) {
        if (!_isCurrent(window, generation)) return;
        window.session.state = SshConnectionState.disconnected;
        window.session.updatedAt = DateTime.now();
        _emit();
      }),
    );
    window.session.state = SshConnectionState.connected;
    window.session.errorMessage = null;
    window.session.updatedAt = DateTime.now();
    _emit();
  }

  Future<void> _dropWindow(_SshWindow window) async {
    window.closed = true;
    window.generation = ++_nextId;
    _windows.remove(window);
    await _closeTransport(window);
    await window.session.close();
  }

  Future<void> _closeTransport(_SshWindow window) async {
    final stdout = window.stdout;
    final stderr = window.stderr;
    final shell = window.shell;
    final connection = window.connection;
    window.stdout = null;
    window.stderr = null;
    window.shell = null;
    window.connection = null;
    await stdout?.cancel();
    await stderr?.cancel();
    if (shell != null) await shell.close();
    if (connection != null) await connection.close();
  }

  bool _isCurrent(_SshWindow window, int generation) {
    return !_closed &&
        !window.closed &&
        window.generation == generation &&
        _windows.contains(window);
  }

  _SshWindow? _find(String sessionId) {
    for (final window in _windows) {
      if (window.session.id == sessionId) return window;
    }
    return null;
  }

  String _uniqueName(String requested) {
    final base = requested.trim().isEmpty ? 'SSH' : requested.trim();
    if (isSessionNameAvailable(base)) return base;
    for (var index = 2; index < 100; index++) {
      final candidate = '$base $index';
      if (isSessionNameAvailable(candidate)) return candidate;
    }
    throw StateError('Session name is already in use.');
  }

  String? _tmuxSessionName(ConnectionConfig config, String displayName) {
    if (config.launchMode != TerminalLaunchMode.tmux) return null;
    final slug = displayName.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9_-]'),
      '',
    );
    final base = slug.isEmpty ? 'ssh' : slug;
    return base.length > 32 ? base.substring(0, 32) : base;
  }

  SshTerminalSession _snapshot(_SshWindow window) {
    final session = window.session;
    return SshTerminalSession(
      id: session.id,
      connectionId: session.connectionId,
      connectionName: session.connectionName,
      displayName: session.displayName,
      tmuxSessionName: session.tmuxSessionName,
      tmuxAutoDeleteSeconds: session.tmuxAutoDeleteSeconds,
      fontSize: session.fontSize,
      state: session.state,
      errorMessage: session.errorMessage,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      output: session.output,
      outputText: session.outputText,
      estimatedMemoryBytes: session.estimatedMemoryBytes,
    );
  }

  void _emit() {
    if (!_closed && !_changes.isClosed) _changes.add(null);
  }
}

final class _SshWindow {
  _SshWindow({required this.session, required this.generation});

  final SshSession session;
  int generation;
  SshDirectSession? connection;
  SshDirectShell? shell;
  StreamSubscription<List<int>>? stdout;
  StreamSubscription<List<int>>? stderr;
  bool closed = false;
}
