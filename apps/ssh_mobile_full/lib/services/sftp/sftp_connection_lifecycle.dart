part of 'sftp_service_io.dart';

extension _SftpConnectionLifecycle on SftpService {
  Future<void> _disconnectCurrent({required bool notify}) async {
    final id = _activeConnectionId;
    if (id != null) await _disconnectId(id, notify: notify);
  }

  Future<void> _disconnectId(
    String id, {
    required bool notify,
    bool forgetPath = false,
  }) async {
    _connectAttempts.remove(id);
    _connectTasks.remove(id);
    final session = _sessions.remove(id);
    if (session != null && !forgetPath) _lastPaths[id] = session.currentPath;
    session?.close();
    if (_activeConnectionId == id) _activeConnectionId = null;
    if (forgetPath) {
      _lastPaths.remove(id);
      await SftpFileCache.clearConnection(id);
    }
    if (notify) notifyListeners();
  }

  Future<void> _disconnectEvery({required bool notify}) async {
    _connectAttempts.clear();
    _connectTasks.clear();
    for (final session in _sessions.values) {
      _lastPaths[session.connectionId] = session.currentPath;
      session.close();
    }
    _sessions.clear();
    _activeConnectionId = null;
    if (notify) notifyListeners();
  }

  Future<void> _connectForConnection(
    String connectionId, {
    dynamic onUnknownHostKey,
  }) {
    if (_disposed) {
      return Future<void>.error(StateError('SFTP service is disposed.'));
    }
    final existing = _connectTasks[connectionId];
    if (existing != null) return existing;
    final token = Object();
    final completed = Completer<void>();
    _connectAttempts[connectionId] = token;
    _connectTasks[connectionId] = completed.future;
    _activeConnectionId = connectionId;
    void finish() {
      if (identical(_connectAttempts[connectionId], token)) {
        _connectAttempts.remove(connectionId);
      }
      if (identical(_connectTasks[connectionId], completed.future)) {
        _connectTasks.remove(connectionId);
      }
    }

    // Own the full attempt before any credential lookup or biometric await.
    final operation = Future<void>.sync(
      () => _resolveConnectAttempt(
        connectionId,
        token,
        onUnknownHostKey: onUnknownHostKey,
      ),
    );
    unawaited(
      operation.then<void>(
        (_) {
          finish();
          completed.complete();
        },
        onError: (Object error, StackTrace stack) {
          finish();
          completed.completeError(error, stack);
        },
      ),
    );
    return completed.future;
  }

  bool _isConnectCurrent(String id, Object token) =>
      !_disposed && identical(_connectAttempts[id], token);

  Future<void> _resolveConnectAttempt(
    String connectionId,
    Object token, {
    dynamic onUnknownHostKey,
  }) async {
    ConnectionRuntimeTarget runtimeTarget;
    try {
      runtimeTarget = await RemoteTargetScope.resolveIfBound(
        connectionRepository: _connectionRepository,
        credentialRepository: _credentialRepository,
        connectionId: connectionId,
        allowCredentialUnlock: true,
      );
    } on RemoteTargetScopeException catch (e) {
      if (!_isConnectCurrent(connectionId, token)) return;
      _activeConnectionId = connectionId;
      final session = _sessions.putIfAbsent(
        connectionId,
        () => _SftpSession(
          connectionId: connectionId,
          connectionName: connectionId,
          currentPath: _lastPaths[connectionId] ?? '.',
        ),
      );
      session.state = SftpConnectionState.error;
      session.errorMessage = e.message;
      notifyListeners();
      return;
    } catch (_) {
      if (!_isConnectCurrent(connectionId, token)) return;
      rethrow;
    }
    if (!_isConnectCurrent(connectionId, token)) return;
    final config = runtimeTarget.config;
    var existing = _sessions[connectionId];
    if (existing != null &&
        existing.targetBinding?.fingerprint !=
            runtimeTarget.binding.fingerprint) {
      existing.close();
      _sessions.remove(connectionId);
      existing = null;
    }
    if (existing?.sftp != null) {
      _activeConnectionId = connectionId;
      notifyListeners();
      return;
    }
    final session = _SftpSession(
      connectionId: connectionId,
      connectionName: config.name,
      currentPath: _lastPaths[connectionId] ?? '.',
      targetBinding: runtimeTarget.binding,
    );
    _sessions[connectionId] = session;
    _activeConnectionId = connectionId;
    session.state = SftpConnectionState.connecting;
    session.errorMessage = null;
    notifyListeners();
    await _connect(session, runtimeTarget, onUnknownHostKey: onUnknownHostKey);
  }

  Future<void> _connect(
    _SftpSession session,
    ConnectionRuntimeTarget target, {
    dynamic onUnknownHostKey,
  }) async {
    final config = target.config;
    final credentials = SshCredentials(
      password: target.password,
      privateKey: target.privateKey,
    );
    try {
      final client = await _clientFactory.connectClient(
        config,
        credentials: credentials,
        onUnknownHostKey: onUnknownHostKey,
        peerId: _peerIdResolver?.call(config),
        validateTarget: target.validateCurrent,
      );
      if (!session.isCurrent(_sessions)) {
        client.close();
        return;
      }
      session.client = client;
      final sftp = await client.sftp().timeout(const Duration(seconds: 15));
      if (!session.isCurrent(_sessions)) {
        sftp.close();
        client.close();
        return;
      }
      session.sftp = sftp;
      session.state = SftpConnectionState.connected;
      AppLogService.instance.info(
        'SFTP connected',
        details: SftpLogSafety.details(
          operation: 'connect',
          connectionId: session.connectionId,
        ),
      );
      notify();
      await _openLastKnownPath(session);
    } catch (e) {
      AppLogService.instance.error(
        'SFTP connect failed',
        details: SftpLogSafety.details(
          operation: 'connect',
          connectionId: session.connectionId,
          error: e,
        ),
      );
      session.close();
      session.client = null;
      session.sftp = null;
      session.state = SftpConnectionState.error;
      session.errorMessage = 'SFTP connection failed: $e';
      notify();
    }
  }
}
