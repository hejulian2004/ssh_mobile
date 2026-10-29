import 'package:android_server_widgets/android_server_widgets.dart';
import 'package:feature_monitoring/feature_monitoring.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';

final class WidgetMonitoringFake extends ChangeNotifier
    implements MonitoringService {
  bool get hasWidgetListeners => hasListeners;
  @override
  bool isRunning = false;
  @override
  DateTime? startedAt;
  @override
  Duration effectiveInterval = const Duration(seconds: 10);
  @override
  Set<String> monitoringConnectionIds = {};
  final List<PerformanceSample> samples = [];
  final Map<String, String> errors = {};
  @override
  Map<String, String> get errorsByConnection => errors;
  @override
  List<PerformanceSample> samplesFor(String id) =>
      samples.where((sample) => sample.connectionId == id).toList();
  void changed() => notifyListeners();
  void start(DateTime time) {
    isRunning = true;
    startedAt = time;
    monitoringConnectionIds = {'server-a'};
    changed();
  }

  void stop() {
    isRunning = false;
    startedAt = null;
    monitoringConnectionIds = {};
    changed();
  }

  void sample(DateTime time) {
    samples.add(
      PerformanceSample(
        connectionId: 'server-a',
        time: time,
        cpuPercent: 42,
        memoryPercent: 63,
        networkBytesPerSecond: 1024,
        diskBytesPerSecond: 2048,
      ),
    );
    changed();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The real host service is absent from Flutter VM tests. No test starts it.
final class WidgetStoppedBackgroundPlatform
    extends FlutterBackgroundServicePlatform {
  @override
  Future<bool> isServiceRunning() async => false;

  @override
  Future<bool> configure({
    required IosConfiguration iosConfiguration,
    required AndroidConfiguration androidConfiguration,
  }) => throw StateError('Widget bridge must not configure a host service');

  @override
  Future<bool> start() =>
      throw StateError('Widget bridge must not start a host service');

  @override
  void invoke(String method, [Map<String, dynamic>? args]) =>
      throw StateError('No running host service accepts commands');

  @override
  Stream<Map<String, dynamic>?> on(String method) =>
      throw StateError('No running host service publishes events');
}

typedef WidgetWrite = ({
  int sequence,
  List<MonitoringWidgetServer> servers,
  List<MonitoringWidgetSnapshotV1> snapshots,
  Map<String, int> invalidatedBefore,
  bool reset,
});

final class WidgetPlatformFake implements MonitoringWidgetPlatform {
  int begins = 0;
  int concurrent = 0;
  int maxConcurrent = 0;
  bool failNext = false;
  Future<String>? beginGate;
  Future<void>? writeGate;
  final List<WidgetWrite> writes = [];
  MonitoringWidgetSnapshotV1 get latest =>
      writes.lastWhere((write) => write.snapshots.isNotEmpty).snapshots.last;
  List<MonitoringWidgetServer> get servers => writes.last.servers;
  @override
  Future<String> beginSession() async {
    begins++;
    if (failNext) {
      failNext = false;
      throw StateError('fixture storage failure');
    }
    return await beginGate ?? 'writer-a';
  }

  @override
  Future<void> synchronize({
    required String session,
    required int sequence,
    required List<MonitoringWidgetServer> servers,
    required List<MonitoringWidgetSnapshotV1> snapshots,
    required Map<String, int> invalidatedBefore,
    bool reset = false,
  }) async {
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    await writeGate;
    writes.add((
      sequence: sequence,
      servers: List.of(servers),
      snapshots: List.of(snapshots),
      invalidatedBefore: Map.of(invalidatedBefore),
      reset: reset,
    ));
    concurrent--;
  }
}
