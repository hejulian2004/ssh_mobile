import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/app_bootstrap.dart';
import 'package:ssh_mobile/app/app_runtime.dart';

import 'support/app_runtime_test_support.dart';

class _LoadingTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  Future<void> get waitUntilFirstFrameRasterized => Future<void>.value();
}

void main() {
  _LoadingTestBinding();

  testWidgets('keeps one loading animation through Runtime and power checks', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    final previousDebugPrint = debugPrint;
    final powerReady = Completer<bool>();
    final runtimeReady = Completer<AppRuntime>();
    RuntimeHarness? harness;
    var powerQueries = 0;
    const powerChannel = MethodChannel('ssh_mobile/power');
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      late AppRuntime runtime;
      await tester.runAsync(() async {
        harness = await newRuntimeHarness(disposeLogger: false);
        runtime = await harness!.createFuture;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        powerChannel,
        (call) async {
          if (call.method == 'isIgnoringBatteryOptimizations') {
            powerQueries++;
            return powerReady.future;
          }
          return null;
        },
      );
      Widget? shell;
      unawaited(
        AppBootstrap.run(
          runtimeFactory: () => runtimeReady.future,
          startApp: (app) => shell = app,
        ),
      );
      await tester.pumpWidget(shell!);
      await tester.pump();
      final loadingAnimation = tester.element(
        find.byType(CircularProgressIndicator),
      );
      runtimeReady.complete(runtime);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(powerQueries, 1);
      expect(
        find.byKey(const ValueKey<String>('app-bootstrap-loading')),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.element(find.byType(CircularProgressIndicator)),
        same(loadingAnimation),
      );
      powerReady.complete(false);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(
        find.byKey(const ValueKey<String>('app-bootstrap-loading')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('power-guide-title')), findsOneWidget);
    } finally {
      if (!powerReady.isCompleted) powerReady.complete(false);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async => harness?.close());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        powerChannel,
        null,
      );
      debugDefaultTargetPlatformOverride = previousPlatform;
      debugPrint = previousDebugPrint;
    }
  });
}
