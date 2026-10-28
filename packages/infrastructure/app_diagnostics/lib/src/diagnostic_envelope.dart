import 'dart:convert';

import 'package:app_core/app_core.dart';

import 'diagnostic_config.dart';

/// One local schema. Privacy policy is reused from Core before any file write.
final class DiagnosticEnvelope {
  DiagnosticEnvelope({
    required this.runId,
    required this.instanceId,
    required this.component,
  }) {
    for (final value in [runId, instanceId, component]) {
      if (!DiagnosticConfig.identifier.hasMatch(value)) {
        throw ArgumentError('Invalid diagnostic identifier');
      }
    }
  }

  final String runId;
  final String instanceId;
  final String component;
  static const redactor = TelemetryRedactor();
  static const attributeKeys = {
    'duration_ms',
    'count',
    'bytes',
    'attempt',
    'stage',
    'state',
    'status',
    'status_code',
    'method',
    'operation',
    'direction',
    'retryable',
  };

  String encode(LogRecord record) => jsonEncode({
    'schema_version': 1,
    'occurred_at': record.timestamp.toUtc().toIso8601String(),
    'run_id': runId,
    'instance_id': instanceId,
    'component': component,
    'level': record.level.name,
    'message': redactor.sanitizeText(record.message),
    if (record.source != null) 'source': redactor.sanitizeText(record.source!),
    if (redactor.sanitizeIdentifier(record.eventName) case final String event)
      'event': event,
    if (redactor.sanitizeIdentifier(record.traceId) case final String trace)
      'trace_id': trace,
    if (redactor.sanitizeIdentifier(record.errorCode) case final String code)
      'error_code': code,
    if (record.details != null)
      'details': redactor.sanitizeText(record.details!),
    if (record.error != null)
      'error': redactor.sanitizeExceptionText(record.error.toString()),
    if (record.stackTrace != null)
      'stack': redactor.sanitizeStackTrace(record.stackTrace.toString()),
    'attributes': {
      for (final entry in record.attributes.entries)
        if (attributeKeys.contains(entry.key) &&
            _safeValue(entry.value) != null)
          entry.key: _safeValue(entry.value),
    },
  });

  static Object? _safeValue(Object? value) {
    if (value is bool || value is int) return value;
    if (value is double && value.isFinite) return value;
    if (value is String && RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(value)) {
      return redactor.sanitizeText(value);
    }
    return null;
  }
}
