import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';

import 'support/app_runtime_test_support.dart';
import 'support/monitoring_widget_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Runtime owns Android bridge and releases it before monitoring and database',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      FlutterBackgroundServicePlatform.instance =
          WidgetStoppedBackgroundPlatform();
      const channel = MethodChannel('ssh_mobile/android_server_widgets');
      final calls = <MethodCall>[];
      final events = <String>[];
      final catalogPublished = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'beginSession') return 'writer-runtime';
            final arguments = call.arguments as Map;
            if ((arguments['servers'] as List).isNotEmpty &&
                !catalogPublished.isCompleted) {
              catalogPublished.complete();
            }
            return null;
          });
      final harness = await newRuntimeHarness(
        networkRuntime: FakeNetworkRuntime(),
        disposeLogger: false,
        lifecycleObserver: events.add,
      );
      try {
        final runtime = await harness.createFuture;
        expect(runtime.monitoringWidgetAdapter, isNotNull);
        await runtime.connectionRepository.addConnection(
          ConnectionConfig(
            id: 'server-a',
            name: 'Compute A',
            host: 'example.invalid',
            username: 'fixture-user',
          ),
        );
        await catalogPublished.future.timeout(const Duration(seconds: 10));
        await runtime.monitoringWidgetAdapter!.flush();
        expect(runtime.monitoringService.isRunning, isFalse);
        await runtime.dispose();
        expect(
          events.indexOf('monitoring-widget.dispose.end'),
          lessThan(events.indexOf('monitoring-module.dispose.start')),
        );
        expect(
          events.indexOf('monitoring-widget.dispose.end'),
          lessThan(events.indexOf('connection-database.dispose.start')),
        );
        final count = calls.length;
        await runtime.monitoringWidgetAdapter!.flush();
        expect(calls.length, count);
      } finally {
        await harness.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
