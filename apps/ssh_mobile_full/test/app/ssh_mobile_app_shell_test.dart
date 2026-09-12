// SshMobileApp shell widget coverage.
//
// Pumping the real app shell initializes the Material/Shad theme catalogs and
// the route aggregation in lib/app/ssh_mobile_app*.dart. Theme switching and
// app lifecycle transitions exercise the shell state that ordinary feature
// widget tests never reach.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/app_runtime.dart';
import 'package:ssh_mobile/app/ssh_mobile_app.dart';

import 'support/app_runtime_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RuntimeHarness harness;
  late AppRuntime runtime;

  setUp(() async {
    harness = await newRuntimeHarness(
      disposeLogger: false,
      // These tests exercise the shell and lifecycle observer, not native
      // transport startup. Keep the widget process isolated from the native
      // runtime so one test's asynchronous disposal cannot race the next
      // shell instance.
      networkRuntime: FakeNetworkRuntime(),
      startPendingInitialization: false,
    );
    runtime = await harness.createFuture;
  });

  tearDown(() async {
    await harness.close();
  });

  Future<void> withWindowsPlatform(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(SshMobileApp(runtime: runtime));
    await tester.pump();
  }

  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await runtime.dispose();
    // The AppLogService singleton installs a debugPrint bridge; with
    // disposeLogger: false the runtime never restores it. The test binding
    // asserts foundation debug variables are unchanged, so restore the
    // synchronous callback the automated binding installs for widget tests.
    debugPrint = debugPrintSynchronously;
  }

  void expectNoShellErrors(WidgetTester tester) {
    final error = tester.takeException();
    expect(error, isNull);
  }

  testWidgets('pumps the app shell and mounts the MaterialApp navigator', (
    tester,
  ) async {
    await withWindowsPlatform(tester, () async {
      await pumpApp(tester);

      expectNoShellErrors(tester);
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(Navigator), findsOneWidget);

      await tester.pump();
      expectNoShellErrors(tester);

      await disposeTree(tester);
    });
  });

  testWidgets('theme catalogs cover light, dark, and OLED dark palettes', (
    tester,
  ) async {
    await withWindowsPlatform(tester, () async {
      await pumpApp(tester);
      expectNoShellErrors(tester);

      // Theme switching runs through the shell's visual-settings select and
      // rebuilds all Material/Shad theme catalogs (also in dark and OLED mode).
      runtime.appSettings.setThemeMode(ThemeMode.dark);
      await tester.pump();
      expectNoShellErrors(tester);

      unawaited(runtime.appSettings.setOledDark(true));
      await tester.pump();
      expectNoShellErrors(tester);

      unawaited(runtime.appSettings.setOledDark(false));
      runtime.appSettings.setThemeMode(ThemeMode.light);
      await tester.pump();
      expectNoShellErrors(tester);

      await disposeTree(tester);
    });
  });

  testWidgets('the shell tracks app lifecycle transitions', (tester) async {
    await withWindowsPlatform(tester, () async {
      await pumpApp(tester);
      expectNoShellErrors(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expectNoShellErrors(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expectNoShellErrors(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expectNoShellErrors(tester);

      // `detached` represents engine shutdown. Injecting that terminal state
      // into a live Flutter tester tears down platform-owned services while
      // coverage is still attached and can crash the tester subprocess. The
      // real platform lifecycle covers this terminal transition; this widget
      // test keeps the repeatable in-process transitions above.
      await disposeTree(tester);
    });
  });
}
