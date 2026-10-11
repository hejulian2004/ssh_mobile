import 'dart:async';

import 'package:flutter/material.dart';

import '../utils/startup_instrumentation.dart';
import '../services/telemetry/app_crash_telemetry_bridge.dart';
import 'app_runtime.dart';
import 'app_runtime_factory.dart';
import 'ssh_mobile_app.dart';
import 'startup_branding.dart';

/// 应用启动边界，负责 Flutter 绑定、异常 Zone 和 Runtime 装配。
///
/// 业务 Service 不应回到这里自行创建；所有 App Scope 实例统一由
/// [AppRuntimeFactory] 创建，便于在退出时由 [AppRuntime] 反向释放。
final class AppBootstrap {
  AppBootstrap._();

  /// 启动应用并把未处理的异步异常桥接到应用日志。
  ///
  /// [runtimeFactory] and [startApp] are injectable so startup failure handling
  /// can be exercised without constructing the complete App Scope graph.
  static Future<void> run({
    Future<AppRuntime> Function()? runtimeFactory,
    void Function(Widget app)? startApp,
  }) async {
    AppRuntime? runtime;
    await runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();
        StartupInstrumentation.instance.recordMainStart();

        // A Future alone only moves construction out of this synchronous
        // callback; it can still run before Flutter paints the first frame.
        // Register the production barrier synchronously, before runApp, so a
        // host cannot consume the first frame before the callback is attached.
        // Injected startApp callbacks are used by non-widget tests and retain
        // their synchronous test contract.
        final deferRuntimeUntilFirstFrame = startApp == null;
        final firstFrameBarrier = deferRuntimeUntilFirstFrame
            ? _waitForFirstFrame()
            : null;
        final createRuntime = runtimeFactory ?? AppRuntimeFactory.create;
        final runtimeFuture = deferRuntimeUntilFirstFrame
            ? () async {
                await firstFrameBarrier;
                // A post-frame callback only confirms layout/paint submission.
                // Wait for rasterization too, so Android can dismiss its splash
                // and Windows can show the window before heavy composition.
                await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
                return createRuntime();
              }()
            : Future<AppRuntime>(createRuntime);
        final shellRuntimeFuture = runtimeFuture
            .then<_AppBootstrapRuntimeResult>(
              _AppBootstrapRuntimeResult.success,
              onError: (Object error, StackTrace _) =>
                  _AppBootstrapRuntimeResult.failure(error),
            );
        StartupInstrumentation.instance.recordRunAppStart();
        (startApp ?? runApp)(
          _AppBootstrapShell(runtimeFuture: shellRuntimeFuture),
        );
        runtime = await runtimeFuture;
      },
      (error, stackTrace) {
        final currentRuntime = runtime;
        if (currentRuntime != null && !currentRuntime.isDisposed) {
          // Keep the existing local App Scope log projection while the
          // structured bridge writes the durable telemetry record below.
          currentRuntime.appLogService.error(
            'Uncaught zone error',
            error: error,
            stackTrace: stackTrace,
          );
          // The bridge awaits durable local insertion before attempting its
          // asynchronous upload. runZonedGuarded itself remains non-blocking.
          unawaited(
            reportUncaughtErrorToRuntime(
              currentRuntime,
              error: error,
              stackTrace: stackTrace,
            ),
          );
        } else {
          // Runtime 尚未创建或已经释放时无法注入 Logger，只保留不含错误、
          // 主机、路径或堆栈内容的启动边界兜底，避免泄漏敏感信息。
          debugPrint('Uncaught zone error before AppRuntime logging');
        }
      },
    );
  }

  static Future<void> _waitForFirstFrame() {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }
}

final class _AppBootstrapRuntimeResult {
  const _AppBootstrapRuntimeResult.success(this.runtime) : error = null;

  const _AppBootstrapRuntimeResult.failure(this.error) : runtime = null;

  final AppRuntime? runtime;
  final Object? error;
}

/// Paints a stable Flutter frame while the App Scope is being assembled.
///
/// The Runtime remains the only owner of the production App Shell resources;
/// this widget only holds the pending Future and transfers the completed
/// Runtime to [SshMobileApp]. If the host tears down the shell before Runtime
/// creation finishes, the late Runtime is disposed here so construction cannot
/// leak resources after the widget tree is gone.
final class _AppBootstrapShell extends StatefulWidget {
  const _AppBootstrapShell({required this.runtimeFuture});

  final Future<_AppBootstrapRuntimeResult> runtimeFuture;

  @override
  State<_AppBootstrapShell> createState() => _AppBootstrapShellState();
}

final class _AppBootstrapShellState extends State<_AppBootstrapShell> {
  AppRuntime? _runtime;
  Object? _error;
  bool _startupReady = false;

  void _onStartupReady() {
    if (mounted && !_startupReady) setState(() => _startupReady = true);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_resolveRuntime());
  }

  Future<void> _resolveRuntime() async {
    final result = await widget.runtimeFuture;
    if (!mounted) {
      final runtime = result.runtime;
      if (runtime != null) unawaited(runtime.dispose());
      return;
    }
    final error = result.error;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() => _runtime = result.runtime);
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime;
    if (_error != null) return const _AppBootstrapFailureScreen();
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        if (runtime != null)
          Offstage(
            offstage: !_startupReady,
            child: TickerMode(
              enabled: _startupReady,
              child: SshMobileApp(
                runtime: runtime,
                onStartupReady: _onStartupReady,
              ),
            ),
          ),
        if (!_startupReady)
          const _AppBootstrapLoadingScreen(
            key: ValueKey<String>('app-bootstrap-loading-surface'),
          ),
      ],
    );
  }
}

/// A deliberately small first-frame surface; it must not depend on App Scope.
final class _AppBootstrapLoadingScreen extends StatelessWidget {
  const _AppBootstrapLoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        key: ValueKey<String>('app-bootstrap-loading'),
        backgroundColor: Colors.white,
        body: StartupBranding(),
      ),
    );
  }
}

/// Keeps a failed bootstrap visible without exposing exception details.
final class _AppBootstrapFailureScreen extends StatelessWidget {
  const _AppBootstrapFailureScreen();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        key: ValueKey<String>('app-bootstrap-failed'),
        backgroundColor: Colors.white,
        body: Center(
          child: Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFB42318),
            size: 32,
          ),
        ),
      ),
    );
  }
}
