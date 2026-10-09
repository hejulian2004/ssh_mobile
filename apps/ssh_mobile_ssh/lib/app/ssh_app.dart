// SSH-only App 的 Material Shell。
//
// 路由只注册连接编辑和 Terminal Feature 的公开页面。

import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:app_ui/app_ui.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:ssh_core/ssh_core.dart';

import 'ssh_app_runtime.dart';
import 'ssh_home_screen.dart';
import 'ssh_host_key_dialog.dart';

/// SSH-only App 根 Widget 和 Runtime 生命周期 Owner。
final class SshOnlyApp extends StatefulWidget {
  /// 创建 SSH-only App。
  const SshOnlyApp({super.key, required this.runtime});

  /// App Scope Runtime。
  final SshOnlyAppRuntime runtime;

  @override
  State<SshOnlyApp> createState() => SshOnlyAppState();
}

/// 可等待的 SSH-only App 退出 Owner。
final class SshOnlyAppState extends State<SshOnlyApp>
    with WidgetsBindingObserver {
  Future<void>? _shutdownFuture;
  bool _shuttingDown = false;

  SshOnlyAppRuntime get _runtime => widget.runtime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _runtime.hostKeyPrompts.prompt = _confirmHostKey;
  }

  /// 幂等释放 Runtime，并让退出调用方等待屏障。
  Future<void> shutdown() => _shutdownFuture ??= _shutdownRuntime();

  Future<void> _shutdownRuntime() async {
    if (mounted && !_shuttingDown) {
      setState(() => _shuttingDown = true);
      await WidgetsBinding.instance.endOfFrame;
    }
    await _runtime.dispose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await shutdown();
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _releaseAfterWidgetTeardown();
    }
  }

  @override
  void dispose() {
    _runtime.hostKeyPrompts.prompt = null;
    WidgetsBinding.instance.removeObserver(this);
    _releaseAfterWidgetTeardown();
    super.dispose();
  }

  void _releaseAfterWidgetTeardown() {
    final future = _shutdownFuture ??= _runtime.dispose();
    unawaited(
      future.onError((_, _) {
        // Widget teardown 不能等待；显式 shutdown 会保留错误。
      }),
    );
  }

  Future<bool> _confirmHostKey(SshHostKeyPromptRequest request) {
    final context = _runtime.navigatorKey.currentContext;
    if (context == null) return Future<bool>.value(false);
    return showSshHostKeyDialog(
      context: context,
      name: request.connectionName,
      host: request.host,
      port: request.port,
      username: request.username,
      algorithm: request.algorithm,
      fingerprint: request.fingerprint,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_shuttingDown) return const SizedBox.shrink();
    final runtime = _runtime;
    return ListenableBuilder(
      listenable: runtime.settings,
      builder: (context, _) {
        final dark = runtime.settings.isDarkMode;
        return ShadTheme(
          data: ShadThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          child: _materialApp(runtime, dark: dark),
        );
      },
    );
  }

  Widget _materialApp(SshOnlyAppRuntime runtime, {required bool dark}) {
    return MaterialApp(
      navigatorKey: runtime.navigatorKey,
      title: 'SSH',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightThemeFor(),
      darkTheme: AppTheme.darkThemeFor(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: const SshHomeScreen(),
      onGenerateRoute: _route,
      onUnknownRoute: (settings) => MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('页面不存在'))),
      ),
      builder: (context, child) {
        return ShadAppBuilder(
          child: TerminalFeatureScope(
            sshSessionManager: runtime.sshSessionManager,
            settings: runtime.settings,
            shortcuts: runtime.shortcuts,
            connections: runtime.connections,
            logger: runtime.terminalLogger,
            historyRepository: runtime.terminalModule.historyRepository,
            child: MultiProvider(
              providers: [
                Provider<SshOnlyAppRuntime>.value(value: runtime),
                ChangeNotifierProvider<ConnectionViewModel>.value(
                  value: runtime.connectionViewModel,
                ),
                Provider<ConnectionUiAdapter>.value(value: runtime.uiAdapter),
              ],
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
    );
  }
}

Route<dynamic>? _route(RouteSettings settings) {
  switch (settings.name) {
    case TerminalRouteNames.terminal:
      final config = settings.arguments;
      if (config is! Map) return null;
      final connectionId = config['id'];
      final sessionId = config['sessionId'];
      if (connectionId is! String || sessionId is! String) return null;
      return MaterialPageRoute<void>(
        builder: (_) =>
            TerminalScreen(connectionId: connectionId, sessionId: sessionId),
      );
    case TerminalRouteNames.history:
      return MaterialPageRoute<void>(
        builder: (_) => const TerminalHistoryScreen(),
      );
    case TerminalRouteNames.windows:
      return MaterialPageRoute<void>(
        builder: (_) => TerminalWindowsScreen(
          connectionId: _connectionIdArgument(settings.arguments),
        ),
      );
    case ConnectionRouteNames.add:
      return MaterialPageRoute<String>(builder: (_) => const AddEditScreen());
    case ConnectionRouteNames.edit:
      final id = settings.arguments;
      return MaterialPageRoute<String>(
        builder: (_) => AddEditScreen(editId: id is String ? id : null),
      );
    default:
      return null;
  }
}

String? _connectionIdArgument(Object? arguments) {
  if (arguments is String) return arguments;
  if (arguments is Map && arguments['connectionId'] is String) {
    return arguments['connectionId'] as String;
  }
  return null;
}
