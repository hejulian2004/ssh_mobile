part of '../ssh_service.dart';

/// Owns target resolution and the per-session connect operation.
extension _SshServiceConnection on SshService {
  Future<void> _connectSession(
    String connectionId, {
    String? sessionId,
    String? displayName,
    SshHostKeyConfirmation? onUnknownHostKey,
  }) {
    if (_shutdownRequested) {
      return Future<void>.error(
        StateError('SshService is shutting down or already closed.'),
      );
    }
    final id = sessionId ?? _createSessionId(connectionId);
    final existing = _connectOperations[id];
    if (existing != null) {
      if (_connectOperationTargets[id] != connectionId) {
        return Future<void>.error(
          StateError(
            'SSH session $id is already connecting to a different target.',
          ),
        );
      }
      return existing;
    }

    late final Future<void> operation;
    operation =
        _connectOnce(
          connectionId,
          sessionId: id,
          displayName: displayName,
          onUnknownHostKey: onUnknownHostKey,
        ).whenComplete(() {
          if (identical(_connectOperations[id], operation)) {
            _connectOperations.remove(id);
            _connectOperationTargets.remove(id);
          }
        });
    _connectOperations[id] = operation;
    _connectOperationTargets[id] = connectionId;
    return operation;
  }

  Future<void> _connectOnce(
    String connectionId, {
    required String sessionId,
    String? displayName,
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final id = sessionId;
    ConnectionRuntimeTarget runtimeTarget;
    try {
      await Future<void>.delayed(Duration.zero);
      if (_shutdownRequested) return;
      runtimeTarget = await RemoteTargetScope.resolveIfBound(
        connectionRepository: _connectionRepository,
        credentialRepository: _credentialRepository,
        connectionId: connectionId,
        allowCredentialUnlock: true,
      );
    } on RemoteTargetScopeException catch (e) {
      if (_shutdownRequested) return;
      AppLogService.instance.error(
        'SSH connection target unavailable',
        error: e,
        details: 'connectionId=$connectionId sessionId=$id code=${e.code}',
      );
      await _setSessionError(id, connectionId, 'Unknown', e.message);
      return;
    }
    if (_shutdownRequested) return;
    final config = runtimeTarget.config;
    final resolvedPeerId = _resolvePeerId(config);
    final usesBackgroundService = _isMobilePlatform && resolvedPeerId == null;
    final credentials = SshCredentials(
      password: runtimeTarget.password,
      privateKey: runtimeTarget.privateKey,
    );

    final requestedDisplayName = displayName?.trim();
    if (requestedDisplayName?.isNotEmpty == true &&
        _isSessionNameTaken(requestedDisplayName!, exceptSessionId: id)) {
      AppLogService.instance.warning(
        'Window name already exists',
        details: 'name=$requestedDisplayName sessionId=$id',
      );
      await _setSessionError(
        id,
        connectionId,
        config.name,
        'Window name already exists',
      );
      return;
    }
    final defaultDisplayName = requestedDisplayName?.isNotEmpty == true
        ? requestedDisplayName!
        : _defaultDisplayName(config.host, connectionId);
    final session = _sessions.putIfAbsent(
      id,
      () => SshSession(
        id: id,
        connectionId: connectionId,
        connectionName: config.name,
        displayName: defaultDisplayName,
        outputController: StreamController<String>.broadcast(),
      ),
    );
    _refreshSessionsView();

    if (kIsWeb) {
      await _setSessionError(
        id,
        connectionId,
        config.name,
        'Web 浏览器由于沙盒安全限制，不支持直接建立原始 TCP 连接。如果您需要使用 SSH 功能，请下载并使用 Android 客户端或桌面端（Windows/macOS/Linux）应用。\n\nWeb browsers do not support direct TCP connections due to sandbox constraints. To use SSH, please download and run the Android or Desktop client.',
      );
      return;
    }

    if (session.state == SshConnectionState.connecting &&
        _connectCompleters.containsKey(id)) {
      await _connectCompleters[id]!.future;
      return;
    }

    _sessionTargetBindings[id] = runtimeTarget.binding;
    _sessionUsesBackgroundService[id] = usesBackgroundService;
    session.state = SshConnectionState.connecting;
    session.errorMessage = null;
    session.tmuxAutoDeleteSeconds = config.tmuxAutoDeleteSeconds;
    session.updatedAt = DateTime.now();
    _lastErrorMessage = null;
    _lastSessionId = id;
    await _startSessionTelemetry(session, config);
    final traceId = _telemetryTraceIds[id];
    final launchMode = _effectiveLaunchMode(config);
    final connectCompleter = Completer<void>();
    _connectCompleters[id] = connectCompleter;
    _schedulePersistence(
      () => _saveTerminalHistoryRecord(session),
      description: 'Failed to save terminal history record',
    );
    AppLogService.instance.info(
      'Session connecting',
      details:
          'sessionId=$id connection=${config.name} '
          'mode=${launchMode.name} platform=${config.serverPlatform.name}',
    );
    _notifySessionMetadataChanged();

    try {
      // Allow UI to render the connecting state and connection dialog entrance
      await Future<void>.delayed(const Duration(milliseconds: 16));
      if (_shutdownRequested) throw const _SshServiceClosing();

      if (launchMode == TerminalLaunchMode.tmux) {
        session.tmuxSessionName ??= _uniqueTmuxSessionName(
          _tmuxSessionNameForSession(session),
          exceptSessionId: id,
        );
      } else {
        session.tmuxSessionName = null;
      }
      if (session.tmuxSessionName != null) {
        AppLogService.instance.info(
          'Using tmux session',
          details: 'sessionId=$id tmux=${session.tmuxSessionName}',
        );
      }
      if (usesBackgroundService) {
        if (config.hostKeyFingerprint?.isNotEmpty != true) {
          await _verifyHostKeyBeforeBackground(
            config: config,
            credentials: credentials,
            onUnknownHostKey: onUnknownHostKey,
            traceId: traceId,
            peerId: resolvedPeerId,
            validateTarget: runtimeTarget.validateCurrent,
          );
        }
        await BackgroundServiceManager.start(
          connectionName: _notificationSummary(),
          showConnectionName:
              _appSettings?.showServerNamesInNotifications ?? false,
        );
        // Let the UI render while foreground service is starting up
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (_shutdownRequested) throw const _SshServiceClosing();
        await runtimeTarget.validateCurrent(config);
        _backgroundService.invoke('sshConnect', {
          'sessionId': id,
          'id': config.id,
          'name': config.name,
          'host': config.host,
          'port': config.port,
          'username': config.username,
          'password': credentials.password,
          'privateKey': credentials.privateKey,
          'authMethod': config.authMethod.name,
          'hostKeyFingerprint': config.hostKeyFingerprint,
          'hostKeyAlgorithm': config.hostKeyAlgorithm,
          'hostKeyTrustedAt': config.hostKeyTrustedAt?.toIso8601String(),
          'peerId': resolvedPeerId,
          'showServerNameInNotification':
              _appSettings?.showServerNamesInNotifications ?? false,
          'terminalWidth': config.terminalWidth,
          'terminalHeight': config.terminalHeight,
          'keepAliveInterval': 3,
          'launchMode': launchMode.name,
          'tmuxSessionName': session.tmuxSessionName,
          'tmuxAutoDeleteSeconds': config.tmuxAutoDeleteSeconds,
        });
      } else {
        // Allow UI rendering before initiating local cryptographic handshake
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (_shutdownRequested) throw const _SshServiceClosing();
        await _connectLocalSession(
          session: session,
          config: config,
          credentials: credentials,
          launchMode: launchMode,
          onUnknownHostKey: onUnknownHostKey,
          peerId: resolvedPeerId,
          traceId: traceId,
          validateTarget: runtimeTarget.validateCurrent,
        );
      }

      await connectCompleter.future.timeout(const Duration(seconds: 30));
      if (_shutdownRequested) throw const _SshServiceClosing();
    } on _SshServiceClosing {
      final pending = _connectCompleters.remove(id);
      if (pending != null && !pending.isCompleted) pending.complete();
    } on TimeoutException {
      if (_shutdownRequested) return;
      final pending = _connectCompleters.remove(id);
      if (pending != null && !pending.isCompleted) pending.complete();
      AppLogService.instance.error(
        'Session connect timed out',
        details: 'sessionId=$id connection=${config.name}',
      );
      await _failSessionTelemetry(
        _sessions[id] ?? session,
        'connect',
        errorCode: TelemetryErrorCodes.sshTimeout,
        errorMessage: 'Connection timed out',
      );
      await _setSessionError(
        id,
        connectionId,
        config.name,
        'Connection timed out',
      );
    } catch (e, stackTrace) {
      if (_shutdownRequested) return;
      final pending = _connectCompleters.remove(id);
      if (pending != null && !pending.isCompleted) pending.complete();
      AppLogService.instance.error(
        'Session connect failed',
        error: e,
        stackTrace: stackTrace,
        details: 'sessionId=$id connection=${config.name}',
      );
      final errorCode = _mapSshErrorCode(e, config);
      await _failSessionTelemetry(
        _sessions[id] ?? session,
        'connect',
        errorCode: errorCode,
        errorMessage: '$e',
      );
      await _setSessionError(
        id,
        connectionId,
        config.name,
        'Connection failed: $e',
      );
    }
  }
}
