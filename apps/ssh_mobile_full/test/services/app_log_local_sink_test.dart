import 'package:app_core/app_core.dart' as core;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_log_service.dart';

final class _Sink implements core.LogSink {
  final records = <core.LogRecord>[];
  int closed = 0;
  @override
  void write(core.LogRecord record) => records.add(record);
  @override
  Future<void> close() async {
    closed++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'local diagnostics includes legacy logs once without uploading them',
    () async {
      final logs = AppLogService.instance;
      final local = _Sink();
      final telemetry = _Sink();
      logs.addLocalSink(local);
      logs.addSink(telemetry);
      logs.add('debug', 'legacy operation');
      logs.log(
        core.LogRecord(
          timestamp: DateTime.utc(2026),
          level: core.LogLevel.error,
          message: 'structured operation',
          traceId: 'test-trace',
          eventName: 'operation_failed',
          errorCode: 'FAILED',
          attributes: const {'duration_ms': 20},
        ),
      );
      expect(local.records, hasLength(2));
      expect(telemetry.records, hasLength(1));
      expect(local.records.last.traceId, 'test-trace');
      expect(local.records.last.attributes['duration_ms'], 20);
      expect(local.records.last.timestamp, DateTime.utc(2026));
      logs.removeSink(telemetry);
      await logs.closeLocalSinks();
      await logs.closeLocalSinks();
      expect(local.closed, 1);
    },
  );
}
