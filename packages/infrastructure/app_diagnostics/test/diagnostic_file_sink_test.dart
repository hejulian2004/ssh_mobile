import 'dart:io';
import 'dart:convert';
import 'package:app_core/app_core.dart';
import 'package:app_diagnostics/app_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Unprintable {
  @override
  String toString() => throw StateError('unprintable');
}

void main() {
  test('configured sink announces output and flushes on close', () async {
    final dir = Directory.systemTemp.createTempSync('configured_sink_');
    try {
      final config = DiagnosticConfig.fromEnvironment(
        environment: {
          'SSH_MOBILE_LOG_RUN_ID': 'fixture-run',
          'SSH_MOBILE_LOG_DIR': dir.path,
        },
        android: false,
      );
      final sink = DiagnosticFileSink.fromConfig(config, 'flutter')!;
      await sink.close();
      final recordFile = dir.listSync().whereType<File>().singleWhere(
        (file) => file.path.endsWith('.jsonl'),
      );
      expect(
        jsonDecode((await recordFile.readAsLines()).single)['event'],
        'diagnostic_output_ready',
      );
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
  test(
    'encoder and filesystem failures remain observable and isolated',
    () async {
      final dir = Directory.systemTemp.createTempSync('sink_');
      try {
        final blocker = File('${dir.path}/blocker')
          ..writeAsStringSync('fixture');
        final sink = DiagnosticFileSink(
          directory: Directory(blocker.path),
          runId: 'run',
          component: 'app',
        );
        sink.write(
          LogRecord(
            timestamp: DateTime.now(),
            level: LogLevel.error,
            message: 'failed',
            error: _Unprintable(),
          ),
        );
        sink.write(
          LogRecord(
            timestamp: DateTime.now(),
            level: LogLevel.info,
            message: 'safe',
          ),
        );
        await sink.pendingWrites;
        await sink.close();
        expect(sink.health.failed, greaterThanOrEqualTo(2));
        expect(sink.health.closed, true);
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
}
