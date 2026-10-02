import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:ssh_mobile/app/app_bootstrap.dart';
import 'package:ssh_mobile/app/app_runtime.dart';

import 'support/app_runtime_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pre-runtime zone failures do not print error details or stacks',
    () async {
      final previousDebugPrint = debugPrint;
      final messages = <String>[];

      try {
        final safeMessage = Completer<void>();
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) {
            messages.add(message);
            if (message == 'Uncaught zone error before AppRuntime logging' &&
                !safeMessage.isCompleted) {
              safeMessage.complete();
            }
          }
        };
        unawaited(
          AppBootstrap.run(
            runtimeFactory: () => Future<AppRuntime>.error(
              StateError('bootstrap-error-marker'),
              StackTrace.fromString('bootstrap-stack-marker'),
            ),
            startApp: (_) {},
          ),
        );
        await safeMessage.future.timeout(const Duration(seconds: 1));
      } finally {
        debugPrint = previousDebugPrint;
      }

      expect(messages, hasLength(1));
      expect(messages.single, 'Uncaught zone error before AppRuntime logging');
      expect(messages.single, isNot(contains('bootstrap-error-marker')));
      expect(messages.single, isNot(contains('bootstrap-stack-marker')));
    },
  );

  test(
    'successful bootstrap records the app boundary and starts the shell',
    () async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final harness = await newRuntimeHarness(disposeLogger: false);
        final runtime = await harness.createFuture;
        addTearDown(harness.close);

        Widget? startedApp;
        await AppBootstrap.run(
          runtimeFactory: () async => runtime,
          startApp: (app) => startedApp = app,
        );

        expect(startedApp, isA<Widget>());
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );

  test(
    'post-runtime zone failures are logged without escaping the boundary',
    () async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final harness = await newRuntimeHarness(disposeLogger: false);
        final runtime = await harness.createFuture;
        addTearDown(harness.close);

        await AppBootstrap.run(
          runtimeFactory: () async => runtime,
          startApp: (_) {
            Timer.run(() => throw StateError('post-runtime-marker'));
          },
        ).timeout(const Duration(seconds: 5));
        // The crash bridge writes asynchronously after the zone handler returns.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(runtime.isDisposed, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );
}
