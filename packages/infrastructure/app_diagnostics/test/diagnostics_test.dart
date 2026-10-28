import 'dart:convert';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:app_diagnostics/app_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('diagnostics_'));
  tearDown(() => directory.deleteSync(recursive: true));

  test('preserves correlation and redacts before serialization', () {
    final envelope =
        DiagnosticEnvelope(
          runId: 'test-run',
          instanceId: 'test-instance',
          component: 'flutter',
        ).encode(
          LogRecord(
            timestamp: DateTime.utc(2026, 10, 23),
            level: LogLevel.error,
            message: 'operation failed password=private-value',
            source: 'connection',
            eventName: 'operation_failed',
            traceId: 'test-trace',
            errorCode: 'CONNECT_FAILED',
            attributes: {
              'duration_ms': 12,
              'password': 'private-value',
              'payload': 'private-value',
            },
          ),
        );
    final record = jsonDecode(envelope) as Map<String, dynamic>;
    expect(envelope, isNot(contains('private-value')));
    expect(record['trace_id'], 'test-trace');
    expect(record['occurred_at'], '2026-10-23T00:00:00.000Z');
    expect(record['attributes'], {'duration_ms': 12});
  });

  test('configuration is explicit, bounded and Android remains private', () {
    expect(DiagnosticConfig.fromEnvironment(environment: {}).enabled, false);
    final config = DiagnosticConfig.fromEnvironment(
      environment: {
        'SSH_MOBILE_LOG_RUN_ID': 'test-run',
        'SSH_MOBILE_LOG_DIR': directory.path,
      },
    );
    expect(config.enabled, true);
    expect(config.directory.path, directory.path);
    expect(
      () => DiagnosticConfig.fromEnvironment(
        environment: {'SSH_MOBILE_LOG_RUN_ID': '../escape'},
      ),
      throwsArgumentError,
    );
    final android = DiagnosticConfig.fromEnvironment(
      environment: {
        'SSH_MOBILE_LOG_RUN_ID': 'test-run',
        'SSH_MOBILE_LOG_DIR': directory.path,
      },
      android: true,
      temporaryDirectory: directory,
    );
    expect(android.directory.path, contains('agent-observability'));
    expect(android.directory.path, endsWith('test-run'));
  });

  test(
    'rotating writer is shared by text and JSON output and drains once',
    () async {
      final writer = RotatingLogWriter(
        File('${directory.path}/app.log'),
        maxBytes: 8,
        rotations: 2,
      );
      writer.write('first');
      writer.write('second');
      writer.write('third');
      await writer.close();
      await writer.close();
      expect(
        await File('${directory.path}/app.log.2').readAsString(),
        'first\n',
      );
      expect(
        await File('${directory.path}/app.log.1').readAsString(),
        'second\n',
      );
      expect(await File('${directory.path}/app.log').readAsString(), 'third\n');
      writer.write('ignored');
      expect(writer.health.written, 3);
      expect(writer.health.closed, true);
    },
  );

  test(
    'queue overflow and disk failure are visible without throwing',
    () async {
      final writer = RotatingLogWriter(
        File('${directory.path}/bounded.log'),
        maxQueuedEntries: 1,
        maxQueuedBytes: 10,
      );
      writer.write('one');
      writer.write('two');
      writer.write('a record exceeding byte budget');
      await writer.close();
      expect(writer.health.dropped, greaterThanOrEqualTo(1));
      final blocker = File('${directory.path}/blocker')
        ..writeAsStringSync('fixture');
      final failed = RotatingLogWriter(File('${blocker.path}/app.log'));
      failed.write('safe diagnostic');
      await failed.close();
      expect(failed.health.failed, 1);
    },
  );

  test('sink produces parseable records and a final health sidecar', () async {
    final sink = DiagnosticFileSink(
      directory: directory,
      runId: 'test-run',
      component: 'flutter',
      instanceId: 'instance',
    );
    sink.write(
      LogRecord(
        timestamp: DateTime.utc(2026),
        level: LogLevel.info,
        message: 'ready',
      ),
    );
    await sink.close();
    final lines = await File(
      '${directory.path}/flutter-instance.jsonl',
    ).readAsLines();
    expect(jsonDecode(lines.single)['message'], 'ready');
    final health = jsonDecode(
      await File(
        '${directory.path}/flutter-instance.health.json',
      ).readAsString(),
    );
    expect(health['closed'], true);
    expect(health['written'], 1);
    expect(health['failed'], 0);
  });
}
