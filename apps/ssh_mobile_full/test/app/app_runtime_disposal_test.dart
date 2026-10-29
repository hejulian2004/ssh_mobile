import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'shutdown is idempotent and releases later owners after an earlier failure',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final failure = StateError('fixture shutdown failure');
      final network = FakeNetworkRuntime()..disposeError = failure;
      final events = <String>[];
      final harness = await newRuntimeHarness(
        networkRuntime: network,
        lifecycleObserver: (event) {
          events.add(event);
          if (event == 'network.dispose.start') {
            throw StateError('fixture diagnostic observer failure');
          }
        },
      );
      try {
        final runtime = await harness.createFuture;
        final first = runtime.dispose();
        final duplicate = runtime.dispose();
        expect(duplicate, same(first));
        await expectLater(first, throwsA(same(failure)));
        expect(runtime.isDisposed, isTrue);
        expect(network.disposeCalls, 1);
        expect(
          events.where((event) => event == 'network.dispose.start'),
          hasLength(1),
        );
        expect(
          events,
          containsAll([
            'monitoring-module.dispose.end',
            'connection-database.dispose.end',
            'app-settings.dispose.end',
            'app-log.dispose.end',
          ]),
        );
        expect(
          events.indexOf('network.dispose.end'),
          lessThan(events.indexOf('connection-database.dispose.start')),
        );
        expect(
          events.indexOf('connection-database.dispose.end'),
          lessThan(events.indexOf('app-log.dispose.start')),
        );
        expect(runtime.appLogService.activeTimerCount, 0);
        await expectLater(
          harness.connectionDatabase.customSelect('SELECT 1').get(),
          throwsStateError,
        );
        expect(runtime.dispose(), same(first));
        expect(network.disposeCalls, 1);
      } finally {
        await harness.close();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
