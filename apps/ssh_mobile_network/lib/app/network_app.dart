// 网络传输页的 Material Shell。

import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:app_ui/app_ui.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'network_app_runtime.dart';

/// 网络传输 App 根 Widget 和 Runtime 生命周期 Owner。
final class NetworkTransportApp extends StatefulWidget {
  /// 创建网络传输 App。
  const NetworkTransportApp({super.key, required this.runtime});

  /// App Scope Runtime。
  final NetworkTransportAppRuntime runtime;

  @override
  State<NetworkTransportApp> createState() => NetworkTransportAppState();
}

/// 可等待的网络传输 App 退出 Owner。
final class NetworkTransportAppState extends State<NetworkTransportApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  Future<void>? _shutdownFuture;
  bool _shuttingDown = false;

  NetworkTransportAppRuntime get _runtime => widget.runtime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

  @override
  Widget build(BuildContext context) {
    if (_shuttingDown) return const SizedBox.shrink();
    final runtime = _runtime;
    return MultiProvider(
      providers: [
        ListenableProvider<LanShareSettingsPort>.value(value: runtime.settings),
        Provider<LanShareLoggerPort>.value(value: runtime.loggerPort),
        Provider<LanShareModule>.value(value: runtime.module),
        Provider<LanShareScreenSharePort>.value(value: runtime.screenShare),
        ChangeNotifierProvider<LanReceiverCoordinator>.value(
          value: runtime.module.coordinator,
        ),
      ],
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        title: runtime.settings.strings.lanShare,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightThemeFor(),
        darkTheme: AppTheme.darkThemeFor(),
        builder: (context, child) {
          return NetworkIncomingTransferHost(
            child: LanPairingNavigationHost(
              navigatorKey: _navigatorKey,
              child: child ?? const SizedBox.shrink(),
            ),
          );
        },
        home: const LanShareFeatureScope(child: LanShareScreen()),
      ),
    );
  }
}
