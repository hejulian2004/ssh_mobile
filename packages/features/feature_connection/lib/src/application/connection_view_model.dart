import 'dart:convert';
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:connection_core/connection_core.dart';

import 'connection_persistence_coordinator.dart';
import 'connection_ports.dart';
import 'connection_credential_editor.dart';

part 'connection_view_model_save.dart';

/// Connection Feature 的应用状态协调器。
///
/// ViewModel 只编排 Repository 和 Capability Contract，不创建数据库、
/// Secure Storage、SSH、SFTP 或监控服务。它的生命周期由 Route/Provider
/// 管理，释放时仅解除自身监听，避免误关闭 App Scope 资源。
class ConnectionViewModel extends ChangeNotifier {
  ConnectionViewModel({
    required ConnectionRepository connectionRepository,
    required CredentialRepository credentialRepository,
    required HostKeyRepository hostKeyRepository,
    required ConnectionRuntimePort runtimePort,
    required ConnectionVerificationPort verificationPort,
  }) : _connectionRepository = connectionRepository,
       _credentialRepository = credentialRepository,
       _runtimePort = runtimePort,
       _verificationPort = verificationPort,
       _persistenceCoordinator = ConnectionPersistenceCoordinator(
         connectionRepository,
         credentialRepository,
         hostKeyRepository,
       );

  final ConnectionRepository _connectionRepository;
  final CredentialRepository _credentialRepository;
  final ConnectionRuntimePort _runtimePort;
  final ConnectionVerificationPort _verificationPort;
  final ConnectionPersistenceCoordinator _persistenceCoordinator;

  List<ConnectionConfig> _connections = const [];
  bool _isLoading = false;
  bool _isSaving = false;
  bool _isVerifying = false;
  String? _errorMessage;
  bool _disposed = false;
  int _operationGeneration = 0;
  Future<void> _mutationTail = Future<void>.value();

  List<ConnectionConfig> get connections => _connections;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  bool get isVerifying => _isVerifying;
  String? get errorMessage => _errorMessage;

  /// 编辑页只拥有此控制器，不拥有 Repository、密钥或平台认证通道。
  ConnectionCredentialEditor createCredentialEditor(String connectionId) =>
      ConnectionCredentialEditor(
        connectionId: connectionId,
        connectionRepository: _connectionRepository,
        credentialRepository: _credentialRepository,
        runMutation: (action) => _runMutationExclusive(action),
      );

  /// 从 Repository 重新加载结构快照，避免首屏只看到尚未初始化的空列表。
  Future<void> fetchConnections() async {
    final generation = _beginOperation();
    if (generation == null) return;
    _isLoading = true;
    _errorMessage = null;
    _notifyIfCurrent(generation);
    if (!_isCurrent(generation)) return;
    try {
      final connections = await _connectionRepository.loadConnections();
      if (!_isCurrent(generation)) return;
      _connections = List.unmodifiable(connections);
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _errorMessage = error.toString();
    } finally {
      if (_isCurrent(generation)) {
        _isLoading = false;
        _notifyIfCurrent(generation);
      }
    }
  }

  /// 删除单个连接并清理 SSH/SFTP/监控资源及凭据。
  Future<void> deleteConnectionWithCleanup(String connectionId) async {
    final generation = _beginOperation();
    if (generation == null) return;
    _errorMessage = null;
    _notifyIfCurrent(generation);
    if (!_isCurrent(generation)) return;
    try {
      await _runtimePort.cleanupConnectionResources(connectionId);
      if (!_isCurrent(generation)) return;
      await _runMutationExclusive(() async {
        if (!_isCurrent(generation)) return;

        // destructive persistence 一旦开始，即使 Route generation 被新操作接管，
        // 也必须把结构删除和凭据删除作为一个连续 mutation 做完。
        await _connectionRepository.deleteConnection(connectionId);
        await _credentialRepository.deleteCredentials(connectionId);
        if (_isCurrent(generation)) {
          _connections = List.unmodifiable(_connectionRepository.connections);
        }
      });
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _errorMessage = error.toString();
    } finally {
      _notifyIfCurrent(generation);
    }
  }

  /// 批量删除连接，保持用户选择的顺序完成资源清理。
  Future<void> deleteConnectionsWithCleanup(List<String> connectionIds) async {
    final generation = _beginOperation();
    if (generation == null) return;
    _errorMessage = null;
    _notifyIfCurrent(generation);
    if (!_isCurrent(generation)) return;
    try {
      for (final id in connectionIds) {
        await _runtimePort.cleanupConnectionResources(id);
        if (!_isCurrent(generation)) return;
      }
      await _runMutationExclusive(() async {
        if (!_isCurrent(generation)) return;

        // 批量结构删除后不得按 UI generation 中途退出，否则会留下孤儿凭据。
        await _connectionRepository.deleteConnections(connectionIds);
        for (final id in connectionIds) {
          await _credentialRepository.deleteCredentials(id);
        }
        if (_isCurrent(generation)) {
          _connections = List.unmodifiable(_connectionRepository.connections);
        }
      });
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _errorMessage = error.toString();
    } finally {
      _notifyIfCurrent(generation);
    }
  }

  /// 只改变连接列表顺序，UI 先乐观更新，Repository 负责最终持久化。
  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    final generation = _beginOperation();
    if (generation == null) return;
    if (oldIndex >= 0 &&
        oldIndex < _connections.length &&
        newIndex >= 0 &&
        newIndex <= _connections.length) {
      final mutable = List<ConnectionConfig>.from(_connections);
      final item = mutable.removeAt(oldIndex);
      mutable.insert(newIndex, item);
      _connections = List.unmodifiable(mutable);
      _notifyIfCurrent(generation);
    }
    if (!_isCurrent(generation)) return;
    try {
      await _runMutationExclusive(() async {
        if (!_isCurrent(generation)) return;
        final persistedCount = _connectionRepository.connections.length;
        if (oldIndex < 0 ||
            oldIndex >= persistedCount ||
            newIndex < 0 ||
            newIndex > persistedCount) {
          _connections = List.unmodifiable(_connectionRepository.connections);
          return;
        }
        await _connectionRepository.reorderConnections(oldIndex, newIndex);
        if (_isCurrent(generation)) {
          _connections = List.unmodifiable(_connectionRepository.connections);
        }
      });
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _errorMessage = error.toString();
      _notifyIfCurrent(generation);
    }
  }

  /// 验证并保存；受保护凭据只使用不含明文的回滚租约。
  Future<bool> verifyAndSaveConnection({
    required ConnectionConfig config,
    required bool isEditing,
    required String? rawPassword,
    required String? rawPrivateKey,
    required Future<bool> Function(int activeWindows) confirmDisconnectCallback,
    ConnectionHostKeyConfirmation? onUnknownHostKey,
    String? expectedCredentialRevision,
    bool Function()? isCredentialAccessCurrent,
  }) => _verifyAndSaveConnection(
    config: config,
    isEditing: isEditing,
    rawPassword: rawPassword,
    rawPrivateKey: rawPrivateKey,
    confirmDisconnectCallback: confirmDisconnectCallback,
    onUnknownHostKey: onUnknownHostKey,
    expectedCredentialRevision: expectedCredentialRevision,
    isCredentialAccessCurrent: isCredentialAccessCurrent,
  );

  /// 串行化所有会改变 Connection 结构、Host Key 或凭据的 mutation。
  Future<T> _runMutationExclusive<T>(Future<T> Function() operation) {
    final previous = _mutationTail;
    final next = previous.catchError((_) {}).then((_) => operation());
    _mutationTail = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  ConnectionConfig? getConnection(String id) =>
      _connectionRepository.getConnection(id);

  Future<String?> getPassword(String id) =>
      _credentialRepository.getPassword(id);

  Future<String?> getPrivateKey(String id) =>
      _credentialRepository.getPrivateKey(id);

  /// 请求 App Scope 打开终端；失败信息仍由注入的运行时能力提供。
  Future<String?> openTerminalSession(
    String connectionId,
    String windowName, {
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final generation = _beginOperation();
    if (generation == null) return null;
    _errorMessage = null;
    _notifyIfCurrent(generation);
    if (!_isCurrent(generation)) return null;
    try {
      final sessionId = await _runtimePort.openTerminalSession(
        connectionId,
        windowName,
        onUnknownHostKey: onUnknownHostKey,
      );
      if (!_isCurrent(generation)) return null;
      if (sessionId == null) _errorMessage = _runtimePort.errorMessage;
      return sessionId;
    } catch (error) {
      if (!_isCurrent(generation)) return null;
      _errorMessage = error.toString();
      return null;
    } finally {
      _notifyIfCurrent(generation);
    }
  }

  int? _beginOperation() {
    if (_disposed) return null;
    _operationGeneration++;
    // 新操作接管 Route 状态，旧操作的 finally 不能再清理这些标志。
    _isLoading = false;
    _isSaving = false;
    _isVerifying = false;
    return _operationGeneration;
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _operationGeneration;

  void _notifyIfCurrent(int generation) {
    if (_isCurrent(generation)) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _operationGeneration++;
    super.dispose();
  }

  ConnectionConfig _copyForVerification(
    ConnectionConfig config, {
    required String? password,
    required String? privateKey,
  }) {
    return ConnectionConfig(
      id: config.id,
      name: config.name,
      host: config.host,
      port: config.port,
      username: config.username,
      password: password,
      privateKey: privateKey,
      authMethod: config.authMethod,
      terminalWidth: config.terminalWidth,
      terminalHeight: config.terminalHeight,
      keepAlive: config.keepAlive,
      keepAliveInterval: config.keepAliveInterval,
      launchMode: config.launchMode,
      serverPlatform: config.serverPlatform,
      tmuxAutoDeleteSeconds: config.tmuxAutoDeleteSeconds,
      hostKeyFingerprint: config.hostKeyFingerprint,
      hostKeyAlgorithm: config.hostKeyAlgorithm,
      hostKeyTrustedAt: config.hostKeyTrustedAt,
      createdAt: config.createdAt,
      updatedAt: config.updatedAt,
      jumpHost: config.jumpHost,
      jumpPort: config.jumpPort,
      jumpUsername: config.jumpUsername,
      group: config.group,
    );
  }
}
