part of '../ssh_service.dart';

extension _SshConnectionRuntime on SshService {
  Future<RemoteCommandResult> _runOneShotCommandForTarget({
    required ConnectionRuntimeTarget target,
    required String command,
    required Duration timeout,
    required SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final config = target.config;
    final credentials = SshCredentials(
      password: target.password,
      privateKey: target.privateKey,
    );
    // AI tools and diagnostics must use plain SSH exec. Do not attach tmux or
    // reuse terminal sessions here; tmux is only for interactive terminal UI.
    final client = await _clientFactory.connectClient(
      config,
      credentials: credentials,
      onUnknownHostKey: onUnknownHostKey,
      peerId: _resolvePeerId(config),
      validateTarget: target.validateCurrent,
    );
    try {
      final result = await client.runWithResult(command).timeout(timeout);
      final decoded = await decodeRemoteCommandBytes(
        stdout: result.stdout,
        stderr: result.stderr,
      );
      return RemoteCommandResult(
        exitCode: result.exitCode,
        stdout: decoded.stdout,
        stderr: decoded.stderr,
      );
    } finally {
      client.close();
    }
  }

  /// Mobile background isolates cannot ask the user to trust an unknown host
  /// key, so the UI isolate performs the first TOFU check before handoff.
  Future<void> _verifyHostKeyBeforeBackground({
    required ConnectionConfig config,
    required SshCredentials credentials,
    required SshHostKeyConfirmation? onUnknownHostKey,
    String? peerId,
    String? traceId,
    Future<void> Function(ConnectionConfig? authenticatedConfig)?
    validateTarget,
  }) async {
    final client = await _clientFactory.connectClient(
      config,
      credentials: credentials,
      timeout: const Duration(seconds: 12),
      onUnknownHostKey: onUnknownHostKey,
      peerId: peerId,
      traceId: traceId,
      validateTarget: validateTarget,
    );
    try {
      await client.ping().timeout(const Duration(seconds: 8));
    } finally {
      client.close();
    }
  }

  /// 本地（桌面端）SSH 连接逻辑。建立 SSH client → 创建 Shell（xterm-256color）→
  /// 如果使用 tmux 模式则发送 attach 命令 -> 启动 keep-alive 心跳。
  ///
  /// 三种监听流：stdout（数据输出）、stderr（错误输出）、keepAlive（保活探测）
  Future<void> _connectLocalSession({
    required SshSession session,
    required ConnectionConfig config,
    required SshCredentials credentials,
    required TerminalLaunchMode launchMode,
    SshHostKeyConfirmation? onUnknownHostKey,
    String? peerId,
    String? traceId,
    Future<void> Function(ConnectionConfig? authenticatedConfig)?
    validateTarget,
  }) async {
    final connectToken = _localConnectGate.begin(session.id);
    final owner = SshConnectionAttemptOwner();
    try {
      await _closeLocalSession(
        session.id,
        destroyTmux: false,
        cancelPending: false,
      );
      _ensureLocalConnectCurrent(session, connectToken);
      AppLogService.instance.info(
        'Connecting SSH locally',
        details: 'sessionId=${session.id} host=${config.host}',
      );

      final client = await _clientFactory.connectClient(
        config,
        credentials: credentials,
        onUnknownHostKey: onUnknownHostKey,
        peerId: peerId,
        traceId: traceId,
        validateTarget: validateTarget,
      );
      owner.ownClient(client.close);
      _ensureLocalConnectCurrent(session, connectToken);
      final isTmux = launchMode == TerminalLaunchMode.tmux;
      final termType = config.serverPlatform == ServerPlatform.windows
          ? 'ms-terminal'
          : 'xterm-256color';

      final shell = await client
          .shell(
            pty: SSHPtyConfig(
              width: config.terminalWidth,
              height: config.terminalHeight,
              type: termType,
            ),
          )
          .timeout(const Duration(seconds: 15));
      owner.ownShell(shell.close);
      _ensureLocalConnectCurrent(session, connectToken);

      if (isTmux) {
        final sessionName = session.tmuxSessionName!;
        final escapedName = sessionName.replaceAll("'", "'\"'\"'");
        final attachCmd = 'exec tmux new-session -A -s \'$escapedName\'\r';
        shell.write(utf8.encode(attachCmd));
      }

      final runtime = _LocalSshRuntime(
        sessionId: session.id,
        client: client,
        shell: shell,
        tmuxSessionName: session.tmuxSessionName,
      );
      owner.ownRuntime(runtime.close);

      runtime.stdoutSub = shell.stdout.listen((data) {
        final text = utf8.decode(data, allowMalformed: true);
        _onLocalSessionData(session.id, text);
      });

      runtime.stderrSub = shell.stderr.listen((data) {
        final text = utf8.decode(data, allowMalformed: true);
        _onLocalSessionErrorData(session.id, text);
      });

      unawaited(
        shell.done.then((_) {
          _onLocalSessionDone(runtime);
        }),
      );

      _startLocalKeepAlive(runtime);
      _ensureLocalConnectCurrent(session, connectToken);
      _localRuntimes[session.id] = runtime;
      owner.commit();

      session.state = SshConnectionState.connected;
      session.errorMessage = null;
      session.updatedAt = DateTime.now();
      await _recordSessionConnectedTelemetry(session);

      final completer = _connectCompleters.remove(session.id);
      if (completer != null && !completer.isCompleted) completer.complete();

      _schedulePersistence(
        () => _saveRestorableTmuxSession(session),
        description: 'Failed to save restorable SSH session',
      );
      _notifySessionMetadataChanged();
    } finally {
      try {
        await owner.rollback();
      } catch (error, stackTrace) {
        AppLogService.instance.error(
          'Failed to release local SSH connection attempt',
          error: error,
          stackTrace: stackTrace,
          details: 'sessionId=${session.id}',
        );
      }
      _localConnectGate.finish(session.id, connectToken);
    }
  }

  void _ensureLocalConnectCurrent(SshSession session, int connectToken) {
    if (_shutdownRequested ||
        _closingSessionIds.contains(session.id) ||
        !_localConnectGate.isCurrent(session.id, connectToken) ||
        !identical(_sessions[session.id], session)) {
      throw const _SshServiceClosing();
    }
  }

  void _onLocalSessionData(String sessionId, String text) {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.addOutput(text);
    unawaited(_historyService.append(sessionId, text));
  }

  void _onLocalSessionErrorData(String sessionId, String text) {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.addOutput(text);
    unawaited(_historyService.append(sessionId, text));
  }

  void _onLocalSessionDone(_LocalSshRuntime runtime) {
    final sessionId = runtime.sessionId;
    if (_shutdownRequested || !identical(_localRuntimes[sessionId], runtime)) {
      return;
    }
    if (_closingSessionIds.contains(sessionId)) {
      _closingSessionIds.remove(sessionId);
      return;
    }
    AppLogService.instance.warning(
      'Local SSH session closed unexpectedly',
      details: 'sessionId=$sessionId',
    );
    if (_reconnectOperations.containsKey(sessionId)) return;
    late final Future<void> operation;
    operation = _reconnectLocalSession(sessionId).whenComplete(() {
      if (identical(_reconnectOperations[sessionId], operation)) {
        _reconnectOperations.remove(sessionId);
      }
    });
    _reconnectOperations[sessionId] = operation;
    unawaited(operation);
  }

  Future<void> _reconnectLocalSession(String sessionId) async {
    if (_shutdownRequested) return;
    final session = _sessions[sessionId];
    if (session == null) return;
    session.state = SshConnectionState.connecting;
    _notifySessionMetadataChanged();

    for (var i = 1; i <= 5; i++) {
      if (_shutdownRequested ||
          !_sessions.containsKey(sessionId) ||
          _closingSessionIds.contains(sessionId)) {
        return;
      }
      try {
        AppLogService.instance.info(
          'Reconnecting local SSH session',
          details: 'sessionId=$sessionId attempt=$i',
        );
        final binding =
            _sessionTargetBindings[sessionId] ??
            _captureConnectionTargetBinding(session.connectionId);
        if (binding == null) return;
        final target = await RemoteTargetScope.resolveBinding(
          binding,
          connectionRepository: _connectionRepository,
          credentialRepository: _credentialRepository,
        );
        if (_shutdownRequested ||
            _closingSessionIds.contains(sessionId) ||
            !identical(_sessions[sessionId], session)) {
          return;
        }
        if (target == null) {
          session.state = SshConnectionState.error;
          session.errorMessage =
              'Saved connection target changed; reconnect stopped.';
          _notifySessionMetadataChanged();
          return;
        }
        _sessionTargetBindings[sessionId] = binding;
        final config = target.config;
        final credentials = SshCredentials(
          password: target.password,
          privateKey: target.privateKey,
        );
        final launchMode = _effectiveLaunchMode(config);
        await _connectLocalSession(
          session: session,
          config: config,
          credentials: credentials,
          launchMode: launchMode,
          traceId: _telemetryTraceIds[session.id],
        );
        return;
      } on _SshServiceClosing {
        // 显式 connect、disconnect 或 shutdown 已取得该 session 的新 generation；
        // 旧 reconnect 不得继续退避后再次覆盖新 runtime。
        return;
      } catch (e) {
        if (_shutdownRequested) return;
        AppLogService.instance.error(
          'Reconnect attempt failed',
          error: e,
          details: 'sessionId=$sessionId attempt=$i',
        );
        final delay =
            _reconnectDelayOverride?.call(i) ??
            Duration(seconds: min(30, pow(2, i).toInt()));
        await Future.any<void>(<Future<void>>[
          Future<void>.delayed(delay),
          _shutdownSignal.future,
        ]);
        if (_shutdownRequested) return;
      }
    }

    if (!_shutdownRequested && _sessions.containsKey(sessionId)) {
      session.state = SshConnectionState.error;
      session.errorMessage = 'Reconnect failed after 5 attempts';
      _notifySessionMetadataChanged();
    }
  }

  void _startLocalKeepAlive(_LocalSshRuntime runtime) {
    final timerFactory = _timerFactoryOverride ?? Timer.periodic;
    runtime.keepAliveTimer = timerFactory(const Duration(seconds: 15), (
      timer,
    ) async {
      if (_shutdownRequested ||
          !identical(_localRuntimes[runtime.sessionId], runtime)) {
        timer.cancel();
        return;
      }
      if (runtime.pingInFlight) {
        runtime.keepAliveFailures++;
        AppLogService.instance.warning(
          'Keep-alive timeout',
          details:
              'sessionId=${runtime.sessionId} failures=${runtime.keepAliveFailures}',
        );
        if (runtime.keepAliveFailures >= 3) {
          timer.cancel();
          _onLocalSessionDone(runtime);
        }
        return;
      }

      runtime.pingInFlight = true;
      try {
        await runtime.client.ping();
        runtime.pingInFlight = false;
        runtime.keepAliveFailures = 0;
      } catch (e) {
        runtime.pingInFlight = false;
        runtime.keepAliveFailures++;
        AppLogService.instance.error(
          'Keep-alive ping failed',
          error: e,
          details:
              'sessionId=${runtime.sessionId} failures=${runtime.keepAliveFailures}',
        );
        if (runtime.keepAliveFailures >= 3) {
          timer.cancel();
          _onLocalSessionDone(runtime);
        }
      }
    });
  }

  Future<void> _closeLocalSession(
    String sessionId, {
    required bool destroyTmux,
    bool cancelPending = true,
  }) async {
    if (cancelPending) _localConnectGate.cancel(sessionId);
    final runtime = _localRuntimes.remove(sessionId);
    if (runtime == null) return;

    if (destroyTmux && runtime.tmuxSessionName != null) {
      try {
        final session = _sessions[sessionId];
        final killCmd = session?.tmuxKillCommand;
        if (killCmd != null) {
          AppLogService.instance.info(
            'Killing tmux session on disconnect',
            details: 'sessionId=$sessionId tmux=${runtime.tmuxSessionName}',
          );
          final client = runtime.client;
          await client.run(killCmd).timeout(const Duration(seconds: 3));
        }
      } catch (e) {
        AppLogService.instance.error(
          'Failed to kill remote tmux session',
          error: e,
          details: 'sessionId=$sessionId',
        );
      }
    }

    await runtime.close();
  }
}
