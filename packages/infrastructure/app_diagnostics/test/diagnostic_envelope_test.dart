import 'dart:convert';
import 'package:app_core/app_core.dart';
import 'package:app_diagnostics/app_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('metadata is optional and unsafe values fail closed', () {
    expect(
      () => DiagnosticEnvelope(
        runId: '../bad',
        instanceId: 'one',
        component: 'app',
      ),
      throwsArgumentError,
    );
    final envelope = DiagnosticEnvelope(
      runId: 'run',
      instanceId: 'one',
      component: 'app',
    );
    final text = envelope.encode(
      LogRecord(
        timestamp: DateTime.utc(2026),
        level: LogLevel.error,
        message: 'failed',
        source: 'app',
        details: 'password=private-value',
        error: StateError('token=private-value'),
        stackTrace: StackTrace.fromString('password=private-value'),
        traceId: 'token-private-value',
        eventName: 'safe_event',
        errorCode: 'SAFE_CODE',
        attributes: {
          'duration_ms': double.nan,
          'retryable': true,
          'state': 'pending',
          'count': 1.5,
          'operation': 'unsafe value with spaces',
          'bytes': [1, 2],
        },
      ),
    );
    expect(text, isNot(contains('private-value')));
    final record = jsonDecode(text) as Map;
    expect(record.containsKey('trace_id'), false);
    expect(record['attributes'], {
      'retryable': true,
      'state': 'pending',
      'count': 1.5,
    });
  });
}
