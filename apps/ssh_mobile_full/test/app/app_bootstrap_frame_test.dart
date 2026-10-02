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
}
