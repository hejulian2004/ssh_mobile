// SSH-only App 的启动边界。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter/widgets.dart';

import 'ssh_app.dart';
import 'ssh_app_runtime.dart';

/// SSH-only App 启动协调器。
final class SshAppBootstrap {
  SshAppBootstrap._();

  /// 初始化 Flutter 并启动 SSH App Shell。
  static Future<void> run() async {
    WidgetsFlutterBinding.ensureInitialized();
    SshOnlyAppRuntime? runtime;
    await runZonedGuarded(
      () async {
        runtime = await SshOnlyAppRuntime.create();
        runApp(SshOnlyApp(runtime: runtime!));
      },
      (error, stackTrace) {
        runtime?.logger.log(
          LogRecord(
            timestamp: DateTime.now(),
            level: LogLevel.error,
            source: 'ssh_app',
            message: 'Unhandled SSH app error',
            error: error,
            stackTrace: stackTrace,
          ),
        );
      },
    );
  }
}
