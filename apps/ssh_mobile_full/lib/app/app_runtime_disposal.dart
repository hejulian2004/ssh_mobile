part of 'app_runtime.dart';

/// Owns ordered App Scope shutdown and failure isolation.
extension _AppRuntimeDisposal on AppRuntime {
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
    await attempt('monitoring-widget.dispose', () async {
      final adapter = monitoringWidgetAdapter;
      if (adapter == null) return;
      aiStorageAdapter.unregisterOnImportCallback(
        adapter.invalidateConfiguration,
      );
      await adapter.dispose();
    });
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
      await attempt('app-log.local-drain', appLogService.closeLocalSinks);
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
