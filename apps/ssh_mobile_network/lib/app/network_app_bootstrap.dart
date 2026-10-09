// 网络传输 App 的启动边界。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter/widgets.dart';

import 'network_app.dart';
import 'network_app_runtime.dart';

/// 网络传输 App 启动协调器。
final class NetworkAppBootstrap {
  NetworkAppBootstrap._();

  /// 初始化 Flutter 并启动网络传输 App Shell。
  static Future<void> run() async {
    WidgetsFlutterBinding.ensureInitialized();
    NetworkTransportAppRuntime? runtime;
    await runZonedGuarded(
      () async {
        runtime = await NetworkTransportAppRuntime.create();
        runApp(NetworkTransportApp(runtime: runtime!));
      },
      (error, stackTrace) {
        runtime?.logger.log(
          LogRecord(
            timestamp: DateTime.now(),
            level: LogLevel.error,
            source: 'network_app',
            message: 'Unhandled network transport app error',
            error: error,
            stackTrace: stackTrace,
          ),
        );
      },
    );
  }
}
