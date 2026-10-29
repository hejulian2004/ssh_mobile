import 'dart:async';

import 'package:android_server_widgets/android_server_widgets.dart';
import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/monitoring_widget_adapter.dart';

import 'support/monitoring_widget_fakes.dart';

void main() {
  final now = DateTime.utc(2026, 10, 29, 12);
  late DateTime clock;
  late WidgetMonitoringFake monitor;
  late WidgetPlatformFake platform;
  late StreamController<List<ConnectionConfig>> catalog;
  MonitoringWidgetAdapter? adapter;
  ConnectionConfig server({
    String name = 'Compute A',
    String host = 'example.invalid',
    DateTime? updatedAt,
  }) => ConnectionConfig(
    id: 'server-a',
    name: name,
    host: host,
    username: 'fixture-user',
    createdAt: now.subtract(const Duration(days: 1)),
    updatedAt: updatedAt ?? now.subtract(const Duration(days: 1)),
  );
  Future<void> create() async {
    adapter = MonitoringWidgetAdapter.createForCurrentPlatform(
      monitoring: monitor,
      catalog: catalog.stream,
      platform: platform,
      now: () => clock,
    );
    catalog.add([server()]);
    await adapter!.flush();
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    clock = now;
    monitor = WidgetMonitoringFake();
    platform = WidgetPlatformFake();
    catalog = StreamController.broadcast(sync: true);
    adapter = null;
  });
  tearDown(() async {
    await adapter?.dispose();
    await catalog.close();
    monitor.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('Windows never initializes the Android channel or subscribes', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    adapter = MonitoringWidgetAdapter.createForCurrentPlatform(
      monitoring: monitor,
      catalog: catalog.stream,
      platform: platform,
    );
    expect(adapter, isNull);
    expect(platform.begins, 0);
    expect(monitor.hasWidgetListeners, isFalse);
    expect(catalog.hasListener, isFalse);
  });

  test(
    'initial state, current sample, duplicate notifications and throttle',
    () async {
      await create();
      expect(platform.latest.status, MonitoringWidgetStatus.notStarted);
      monitor.start(now);
      await adapter!.flush();
      expect(platform.latest.status, MonitoringWidgetStatus.waiting);
      monitor.sample(now);
      await adapter!.flush();
      expect(platform.latest.cpuPercent, 42);
      expect(platform.latest.memoryPercent, 63);
      expect(platform.latest.networkBytesPerSecond, 1024);
      expect(platform.latest.diskBytesPerSecond, 2048);
      final count = platform.writes.length;
      monitor.changed();
      await adapter!.flush();
      expect(platform.writes.length, count);
      clock = now.add(const Duration(seconds: 2));
      monitor.sample(clock);
      await adapter!.flush();
      expect(platform.writes.length, count);
      clock = now.add(const Duration(seconds: 16));
      monitor.sample(clock);
      await adapter!.flush();
      expect(platform.latest.sampledAt, clock);
      monitor.errors['server-a'] = 'fixture failure';
      monitor.changed();
      await adapter!.flush();
      expect(platform.latest.status, MonitoringWidgetStatus.failed);
      monitor.stop();
      await adapter!.flush();
      expect(platform.latest.status, MonitoringWidgetStatus.stopped);
    },
  );

  test(
    'restart ignores history from before startedAt and late old-run samples',
    () async {
      await create();
      monitor.start(now);
      monitor.sample(now);
      await adapter!.flush();
      monitor.stop();
      clock = now.add(const Duration(seconds: 1));
      monitor.start(clock);
      await adapter!.flush();
      expect(platform.latest.status, MonitoringWidgetStatus.waiting);
      expect(platform.latest.sampledAt, isNull);
      monitor.sample(now);
      await adapter!.flush();
      expect(platform.latest.status, MonitoringWidgetStatus.waiting);
      monitor.sample(clock);
      await adapter!.flush();
      expect(platform.latest.status, MonitoringWidgetStatus.active);
    },
  );

  test(
    'in-flight write is followed by stop, never by a queued old sample',
    () async {
      await create();
      final gate = Completer<void>();
      platform.writeGate = gate.future;
      monitor.start(now);
      monitor.sample(now);
      await Future<void>.delayed(Duration.zero);
      monitor.stop();
      monitor.sample(now.add(const Duration(seconds: 1)));
      gate.complete();
      await adapter!.flush();
      expect(platform.latest.status, MonitoringWidgetStatus.stopped);
      expect(platform.maxConcurrent, 1);
      expect(
        platform.writes.map((write) => write.sequence).toSet().length,
        platform.writes.length,
      );
    },
  );

  test('a coalesced restart publishes its first sample immediately', () async {
    await create();
    monitor.start(now);
    monitor.sample(now);
    await adapter!.flush();
    clock = now.add(const Duration(seconds: 1));
    monitor.stop();
    monitor.start(clock);
    monitor.sample(clock);
    await adapter!.flush();
    expect(platform.latest.sampledAt, clock);
  });

  test('reintroduced ID cannot reuse a deleted monitoring round', () async {
    await create();
    monitor.start(now);
    monitor.sample(now);
    await adapter!.flush();
    catalog.add([]);
    catalog.add([server()]);
    clock = now.add(const Duration(seconds: 20));
    monitor.sample(clock);
    await adapter!.flush();
    expect(platform.latest.status, MonitoringWidgetStatus.notStarted);
  });

  test(
    'deletion prunes snapshots, rename redacts labels, target change invalidates the run',
    () async {
      await create();
      monitor.start(now);
      monitor.sample(now);
      await adapter!.flush();
      catalog.add([server(name: 'fixture-user example.invalid')]);
      await adapter!.flush();
      expect(
        platform.servers.single.displayName,
        isNot(contains('fixture-user')),
      );
      expect(
        platform.servers.single.displayName,
        isNot(contains('example.invalid')),
      );
      clock = now.add(const Duration(seconds: 20));
      catalog.add([server(host: 'replacement.invalid', updatedAt: clock)]);
      monitor.sample(clock);
      await adapter!.flush();
      expect(platform.latest.status, MonitoringWidgetStatus.notStarted);
      expect(
        platform.writes.last.invalidatedBefore['server-a'],
        clock.millisecondsSinceEpoch,
      );
      catalog.add([]);
      await adapter!.flush();
      expect(platform.servers, isEmpty);
      expect(platform.writes.last.snapshots, isEmpty);
    },
  );

  test(
    'configuration restore invalidates cached samples and requires a new run',
    () async {
      await create();
      monitor.start(now);
      monitor.sample(now);
      await adapter!.flush();
      await adapter!.invalidateConfiguration();
      expect(platform.writes.last.reset, isTrue);
      expect(platform.latest.status, MonitoringWidgetStatus.notStarted);
    },
  );

  test(
    'dispose cancels only borrowed listeners and settles pending initialization',
    () async {
      final gate = Completer<String>();
      platform.beginGate = gate.future;
      adapter = MonitoringWidgetAdapter.createForCurrentPlatform(
        monitoring: monitor,
        catalog: catalog.stream,
        platform: platform,
        now: () => clock,
      );
      catalog.add([server()]);
      monitor.start(now);
      final disposal = adapter!.dispose();
      gate.complete('writer-a');
      await disposal;
      final count = platform.writes.length;
      monitor.sample(now);
      catalog.add([]);
      await adapter!.flush();
      expect(platform.writes.length, count);
      expect(monitor.isRunning, isTrue);
      expect(monitor.hasWidgetListeners, isFalse);
      expect(catalog.hasListener, isFalse);
      await adapter!.dispose();
    },
  );

  test(
    'storage failures are redacted, retryable, and cannot stop the monitor',
    () async {
      var errors = 0;
      platform.failNext = true;
      adapter = MonitoringWidgetAdapter.createForCurrentPlatform(
        monitoring: monitor,
        catalog: catalog.stream,
        platform: platform,
        now: () => clock,
        onError: () => errors++,
      );
      catalog.add([server()]);
      await adapter!.flush();
      expect(errors, 1);
      monitor.start(now);
      monitor.sample(now);
      await adapter!.flush();
      expect(platform.latest.status, MonitoringWidgetStatus.active);
      catalog.addError(StateError('fixture failure'));
      await adapter!.flush();
      expect(platform.servers, isEmpty);
      expect(monitor.isRunning, isTrue);
    },
  );
}
