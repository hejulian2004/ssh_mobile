import 'dart:convert';
import 'dart:io';

import 'package:app_core/app_core.dart';

import 'diagnostic_config.dart';
import 'diagnostic_envelope.dart';
import 'rotating_log_writer.dart';

/// App-owned, opt-in sink. No database, network or global logger is created.
final class DiagnosticFileSink implements LogSink {
  DiagnosticFileSink({
    required Directory directory,
    required String runId,
    required String component,
    String? instanceId,
  }) {
    final instance =
        instanceId ?? '${pid}_${DateTime.now().microsecondsSinceEpoch}';
    _envelope = DiagnosticEnvelope(
      runId: runId,
      instanceId: instance,
      component: component,
    );
    final base = '${directory.path}/$component-$instance';
    _writer = RotatingLogWriter(
      File('$base.jsonl'),
      onIdle: (health) async {
        await File(
          '$base.health.json',
        ).writeAsString(jsonEncode(health.toJson()), flush: true);
      },
    );
  }

  /// Reads explicit launcher configuration; release output remains disabled.
  static DiagnosticFileSink? fromEnvironment(String component) {
    return fromConfig(DiagnosticConfig.fromEnvironment(), component);
  }

  /// Allows one composition-root configuration to be shared with native output.
  static DiagnosticFileSink? fromConfig(
    DiagnosticConfig config,
    String component,
  ) {
    if (!config.enabled) return null;
    final sink = DiagnosticFileSink(
      directory: config.directory,
      runId: config.runId,
      component: component,
    );
    sink.write(
      LogRecord(
        timestamp: DateTime.now(),
        level: LogLevel.info,
        message: 'diagnostic_output_ready',
        eventName: 'diagnostic_output_ready',
      ),
    );
    return sink;
  }

  late final DiagnosticEnvelope _envelope;
  late final RotatingLogWriter _writer;
  LogWriterHealth get health => _writer.health;
  Future<void> get pendingWrites => _writer.pendingWrites;

  @override
  void write(LogRecord record) {
    try {
      _writer.write(_envelope.encode(record));
    } on Object {
      _writer.health.failed++;
    }
  }

  @override
  Future<void> close() => _writer.close();
}
