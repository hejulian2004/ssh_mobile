import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:ssh_mobile/app/app_bootstrap.dart';
import 'package:ssh_mobile/app/app_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
          onError: (Object _, StackTrace __) {},
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
            onError: (Object _, StackTrace __) {},
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
