import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:ssh_mobile/app/app_bootstrap.dart';
import 'package:ssh_mobile/app/app_runtime.dart';

class _StartupTestBinding extends AutomatedTestWidgetsFlutterBinding {
  Completer<void>? rasterBarrier;

  @override
  Future<void> get waitUntilFirstFrameRasterized =>
      rasterBarrier?.future ?? Future<void>.value();
}

void main() {
  final binding = _StartupTestBinding();

  testWidgets('waits for the visible raster frame before starting Runtime', (
    tester,
  ) async {
    final rasterBarrier = Completer<void>();
    binding.rasterBarrier = rasterBarrier;
    var factoryStarted = false;
    final previousDebugPrint = debugPrint;
    debugPrint = (String? _, {int? wrapWidth}) {};
    try {
      unawaited(
        AppBootstrap.run(
          runtimeFactory: () {
            factoryStarted = true;
            return Future<AppRuntime>.error(StateError('raster-test'));
          },
        ),
      );
      await tester.pump();
      expect(factoryStarted, isFalse);
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('app-bootstrap-loading')),
        findsOneWidget,
      );
      rasterBarrier.complete();
      await tester.pump();
      expect(factoryStarted, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      if (!rasterBarrier.isCompleted) rasterBarrier.complete();
      binding.rasterBarrier = null;
      debugPrint = previousDebugPrint;
    }
  });

  testWidgets('defers Runtime construction until after the first frame', (
    tester,
  ) async {
    final previousDebugPrint = debugPrint;
    debugPrint = (String? _, {int? wrapWidth}) {};
    var factoryStarted = false;
    var firstFramePainted = false;
    var factoryStartedAfterFirstFrame = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      firstFramePainted = true;
    });
    try {
      final bootstrap = AppBootstrap.run(
        runtimeFactory: () {
          factoryStarted = true;
          factoryStartedAfterFirstFrame = firstFramePainted;
          return Future<AppRuntime>.error(StateError('deferred-runtime'));
        },
      );

      await tester.pump();
      // The post-frame callback completes the barrier before the first frame
      // pump returns, so Runtime construction can start only after that frame.
      expect(factoryStarted, isTrue);
      expect(factoryStartedAfterFirstFrame, isTrue);

      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('app-bootstrap-failed')),
        findsOneWidget,
      );
      unawaited(bootstrap);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugPrint = previousDebugPrint;
    }
  });

  testWidgets('paints a bootstrap frame before Runtime is ready', (
    tester,
  ) async {
    final runtimeReady = Completer<AppRuntime>();
    Widget? startedApp;
    final bootstrap = AppBootstrap.run(
      runtimeFactory: () => runtimeReady.future,
      startApp: (app) => startedApp = app,
    );

    expect(startedApp, isNotNull);
    await tester.pumpWidget(startedApp!);
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      find.byKey(const ValueKey<String>('app-bootstrap-loading')),
      findsOneWidget,
    );
    expect(find.text('SSH Mobile'), findsOneWidget);
    unawaited(bootstrap);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shows a safe failure screen when Runtime creation fails', (
    tester,
  ) async {
    final previousDebugPrint = debugPrint;
    debugPrint = (String? _, {int? wrapWidth}) {};
    try {
      final runtimeFailure = Completer<AppRuntime>();
      unawaited(
        runtimeFailure.future.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      );
      Widget? startedApp;
      final bootstrap = AppBootstrap.run(
        runtimeFactory: () => runtimeFailure.future,
        startApp: (app) => startedApp = app,
      );

      await tester.pumpWidget(startedApp!);
      await tester.pump();
      runtimeFailure.completeError(StateError('bootstrap-frame-error'));
      for (var index = 0; index < 10; index++) {
        await tester.pump(const Duration(milliseconds: 1));
      }

      expect(
        find.byKey(const ValueKey<String>('app-bootstrap-failed')),
        findsOneWidget,
      );
      expect(find.text('bootstrap-frame-error'), findsNothing);
      unawaited(bootstrap);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugPrint = previousDebugPrint;
    }
  });

  testWidgets(
    'ignores a Runtime failure after the bootstrap shell is removed',
    (tester) async {
      final previousDebugPrint = debugPrint;
      debugPrint = (String? _, {int? wrapWidth}) {};
      try {
        final runtimeFailure = Completer<AppRuntime>();
        unawaited(
          runtimeFailure.future.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        );
        Widget? startedApp;
        final bootstrap = AppBootstrap.run(
          runtimeFactory: () => runtimeFailure.future,
          startApp: (app) => startedApp = app,
        );

        await tester.pumpWidget(startedApp!);
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());

        runtimeFailure.completeError(StateError('late-bootstrap-error'));
        for (var index = 0; index < 10; index++) {
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(tester.takeException(), isNull);
        unawaited(bootstrap);
      } finally {
        debugPrint = previousDebugPrint;
      }
    },
  );
}
