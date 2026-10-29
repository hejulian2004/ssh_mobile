import 'package:android_server_widgets/android_server_widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 29, 12);
  MonitoringWidgetSnapshotV1 snapshot({
    DateTime? sampledAt,
    double cpu = 42,
    double memory = 63,
    double network = 1024,
    double disk = 2048,
    int interval = 10000,
  }) => MonitoringWidgetSnapshotV1(
    connectionId: 'server-a',
    displayName: 'Compute A',
    sampledAt: sampledAt ?? now,
    cpuPercent: cpu,
    memoryPercent: memory,
    networkBytesPerSecond: network,
    diskBytesPerSecond: disk,
    effectiveIntervalMs: interval,
    status: MonitoringWidgetStatus.active,
    now: now,
  );

  test('versioned payload contains only the safe snapshot fields', () {
    expect(snapshot().toMap(), {
      'schemaVersion': 1,
      'connectionId': 'server-a',
      'displayName': 'Compute A',
      'sampledAt': now.millisecondsSinceEpoch,
      'cpuPercent': 42.0,
      'memoryPercent': 63.0,
      'networkBytesPerSecond': 1024.0,
      'diskBytesPerSecond': 2048.0,
      'effectiveIntervalMs': 10000,
      'status': 'active',
    });
  });

  test('invalid metrics become unknown without inventing readings', () {
    final invalid = snapshot(
      cpu: double.nan,
      memory: 101,
      network: -1,
      disk: double.infinity,
    );
    expect(invalid.cpuPercent, isNull);
    expect(invalid.memoryPercent, isNull);
    expect(invalid.networkBytesPerSecond, isNull);
    expect(invalid.diskBytesPerSecond, isNull);
    expect(
      snapshot(cpu: -1, memory: double.negativeInfinity).cpuPercent,
      isNull,
    );
    expect(snapshot(cpu: 0, memory: 100, network: 0, disk: 0).cpuPercent, 0);
  });

  test('invalid timestamps invalidate all metrics and active status', () {
    for (final time in [
      DateTime.utc(1970),
      now.add(const Duration(minutes: 1)),
    ]) {
      final invalid = snapshot(sampledAt: time);
      expect(invalid.sampledAt, isNull);
      expect(invalid.cpuPercent, isNull);
      expect(invalid.status, MonitoringWidgetStatus.waiting);
    }
    expect(snapshot(interval: -1).effectiveIntervalMs, 10000);
    expect(snapshot(interval: 9999999).effectiveIntervalMs, 300000);
  });

  test('absolute expiry honors slow five-minute monitoring', () {
    final waiting = MonitoringWidgetSnapshotV1(
      connectionId: 'server-a',
      displayName: 'Compute A',
      sampledAt: null,
      cpuPercent: null,
      memoryPercent: null,
      networkBytesPerSecond: null,
      diskBytesPerSecond: null,
      effectiveIntervalMs: 10000,
      status: MonitoringWidgetStatus.waiting,
      now: now,
    );
    expect(
      waiting.statusAt(now.add(const Duration(days: 1))),
      MonitoringWidgetStatus.waiting,
    );
    final slow = snapshot(interval: 300000);
    expect(
      slow.statusAt(now.add(const Duration(minutes: 14))),
      MonitoringWidgetStatus.active,
    );
    expect(
      slow.statusAt(now.add(const Duration(minutes: 15))),
      MonitoringWidgetStatus.stale,
    );
    expect(
      snapshot().statusAt(now.add(const Duration(seconds: 60))),
      MonitoringWidgetStatus.stale,
    );
  });

  test(
    'directory labels redact endpoints and credentials and stay bounded',
    () {
      for (final name in [
        'ssh://operator@192.0.2.1:22',
        'password=public-fixture',
        'token:public-fixture',
        '2001:db8::1',
        'example.invalid:22',
      ]) {
        final server = MonitoringWidgetServer(
          connectionId: 'server-a',
          displayName: name,
        );
        expect(server.displayName, 'Server');
        expect(server.toMap().keys, ['connectionId', 'displayName']);
      }
      final long = MonitoringWidgetServer(
        connectionId: 'server-a',
        displayName: '计算节点' * 100,
      );
      expect(long.displayName.runes.length, 48);
      expect(
        MonitoringWidgetServer(
          connectionId: 'server-a',
          displayName: '\u202eA\n B',
        ).displayName,
        'A B',
      );
      for (final id in ['', ' bad ', 'x' * 129, 'operator@example.invalid']) {
        expect(
          () => MonitoringWidgetServer(connectionId: id, displayName: 'A'),
          throwsArgumentError,
        );
      }
    },
  );
}
