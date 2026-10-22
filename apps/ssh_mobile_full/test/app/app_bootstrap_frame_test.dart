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

  testWidgets('starts Runtime while the first raster frame is still pending', (
    tester,
  ) async {
    final rasterBarrier = Completer<void>();
    binding.rasterBarrier = rasterBarrier;
    late Completer<AppRuntime> runtimeReady;
    var factoryStarted = false;
    final previousDebugPrint = debugPrint;
    debugPrint = (String? _, {int? wrapWidth}) {};
    try {
      unawaited(
        AppBootstrap.run(
          runtimeFactory: () {
            factoryStarted = true;
            runtimeReady = Completer<AppRuntime>();
            return runtimeReady.future;
          },
        ),
      );
      await tester.pump();
      expect(factoryStarted, isTrue);
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('app-bootstrap-loading')),
        findsOneWidget,
      );
      rasterBarrier.complete();
      await tester.pump();
      expect(factoryStarted, isTrue);
      runtimeReady.completeError(StateError('raster-test'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      if (!rasterBarrier.isCompleted) rasterBarrier.complete();
      binding.rasterBarrier = null;
      debugPrint = previousDebugPrint;
    }
  });

  testWidgets('starts initialization before the first frame is painted', (
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
      expect(factoryStarted, isTrue);
      expect(factoryStartedAfterFirstFrame, isFalse);

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
    var factoryStarted = false;
    final bootstrap = AppBootstrap.run(
      runtimeFactory: () {
        factoryStarted = true;
        return runtimeReady.future;
      },
      startApp: (app) => startedApp = app,
    );

    expect(startedApp, isNotNull);
    expect(
      factoryStarted,
      isFalse,
      reason: 'Mount the shell before beginning composition',
    );
    await tester.pumpWidget(startedApp!);
    await tester.pump(const Duration(milliseconds: 1));
    expect(factoryStarted, isTrue);
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
      late Completer<AppRuntime> runtimeFailure;
      Widget? startedApp;
      final bootstrap = AppBootstrap.run(
        runtimeFactory: () {
          // Match production: the pending initializer Future belongs to the
          // bootstrap error zone, and its failure must reach the shell.
          runtimeFailure = Completer<AppRuntime>();
          return runtimeFailure.future;
        },
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
        late Completer<AppRuntime> runtimeFailure;
        Widget? startedApp;
        final bootstrap = AppBootstrap.run(
          runtimeFactory: () {
            runtimeFailure = Completer<AppRuntime>();
            return runtimeFailure.future;
          },
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
