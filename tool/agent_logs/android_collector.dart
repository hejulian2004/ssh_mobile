import 'dart:convert';
import 'dart:io';

import 'package:app_diagnostics/app_diagnostics.dart';
import 'package:app_core/app_core.dart';

/// Reads only this run's app-private diagnostic files through explicit ADB.
/// Repeated snapshots are de-duplicated by occurrence number per file content;
/// rotations may move files without losing the identity of collected lines.
final class AndroidCollector {
  AndroidCollector(
    this.output, {
    required this.runId,
    required this.device,
    required this.package,
    this.adb = 'adb',
  }) {
    if (!DiagnosticConfig.identifier.hasMatch(runId) ||
        device.isEmpty ||
        device == 'android' ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(package))
      throw ArgumentError('An explicit device and package are required');
  }
  final Directory output;
  final String runId, device, package, adb;
  Map<String, dynamic> status = {'state': 'pending'};
  final _seen = <String, int>{};
  final _writers = <String, RotatingLogWriter>{};

  Future<void> collect() async {
    if (_seen.length >= 100000) {
      status = {'state': 'gap', 'reason': 'dedup_capacity_reached'};
      return;
    }
    try {
      final base = 'cache/agent-observability/$runId';
      final listing = await Process.run(adb, [
        '-s',
        device,
        'exec-out',
        'run-as',
        package,
        'find',
        base,
        '-maxdepth',
        '1',
        '-type',
        'f',
      ]).timeout(const Duration(seconds: 5));
      if (listing.exitCode != 0) {
        status = {
          'state': 'gap',
          'reason': 'device_unavailable_or_run_as_denied',
        };
        return;
      }
      var files = 0;
      var invalidLines = 0;
      String? gapReason;
      final occurrences = <String, int>{};
      for (final path
          in (listing.stdout as String).split('\n').map((s) => s.trim())) {
        if (!path.startsWith('$base/') ||
            !RegExp(
              r'^[A-Za-z0-9_.-]+$',
            ).hasMatch(path.substring(base.length + 1)))
          continue;
        final name = path.substring(base.length + 1);
        if (!RegExp(r'\.jsonl(?:\.[1-3])?$').hasMatch(name) &&
            !name.endsWith('.health.json'))
          continue;
        final snapshot = await Process.run(adb, [
          '-s',
          device,
          'exec-out',
          'run-as',
          package,
          'cat',
          path,
        ]).timeout(const Duration(seconds: 5));
        if (snapshot.exitCode != 0) {
          gapReason = 'snapshot_unavailable';
          continue;
        }
        final text = snapshot.stdout as String;
        if (text.length > 6 * 1024 * 1024) {
          gapReason = 'snapshot_exceeds_limit';
          continue;
        }
        if (name.endsWith('.health.json')) {
          final health = jsonDecode(text) as Map;
          await File('${output.path}/android-$name').writeAsString(
            jsonEncode({
              for (final key in ['written', 'dropped', 'failed'])
                if (health[key] is int && health[key] >= 0) key: health[key],
              if (health['closed'] is bool) 'closed': health['closed'],
            }),
          );
          continue;
        }
        final lines = const LineSplitter().convert(text);
        for (final line in lines) {
          // A partial tail is retried on the next snapshot, never marked seen.
          if (line.length > 65536) {
            invalidLines++;
            continue;
          }
          try {
            final record = jsonDecode(line) as Map<String, dynamic>;
            if (record['run_id'] != runId || record['schema_version'] != 1)
              continue;
            final occurrence = (occurrences[line] ?? 0) + 1;
            occurrences[line] = occurrence;
            if (occurrence <= (_seen[line] ?? 0)) continue;
            final component = record['component'] as String;
            final instance = record['instance_id'] as String;
            if (!DiagnosticConfig.identifier.hasMatch(component) ||
                !DiagnosticConfig.identifier.hasMatch(instance))
              continue;
            if (_seen.length >= 100000) {
              status = {'state': 'gap', 'reason': 'dedup_capacity_reached'};
              return;
            }
            final safe =
                jsonDecode(
                      DiagnosticEnvelope(
                        runId: runId,
                        instanceId: instance,
                        component: component,
                      ).encode(
                        LogRecord(
                          timestamp: DateTime.parse(
                            record['occurred_at'] as String,
                          ),
                          level: LogLevel.values.byName(
                            record['level'] as String,
                          ),
                          message: record['message'] as String,
                          source: record['source'] as String?,
                          eventName: record['event'] as String?,
                          traceId: record['trace_id'] as String?,
                          errorCode: record['error_code'] as String?,
                          details: record['details'] as String?,
                          error: record['error'],
                          attributes: Map<String, dynamic>.from(
                            record['attributes'] as Map? ?? {},
                          ),
                        ),
                      ),
                    )
                    as Map<String, dynamic>;
            safe['collected_at'] = DateTime.now().toUtc().toIso8601String();
            final writer = _writers.putIfAbsent(
              '$component-$instance',
              () => RotatingLogWriter(
                File('${output.path}/android-$component-$instance.jsonl'),
              ),
            );
            // Device files have already crossed the owning sink's redactor.
            writer.write(jsonEncode(safe));
            _seen[line] = occurrence;
          } on Object {
            /* Retry malformed/incomplete records next collection. */
            invalidLines++;
          }
        }
        files++;
      }
      for (final writer in _writers.values) {
        await writer.pendingWrites;
      }
      // Fixed retention bounds the de-dup window; do not retain lifetime history.
      if (_seen.length > 100000) {
        status = {'state': 'gap', 'reason': 'dedup_capacity_reached'};
        return;
      }
      status = {
        'state': gapReason != null
            ? 'gap'
            : files == 0
            ? 'pending'
            : 'collecting',
        if (gapReason != null) 'reason': gapReason,
        'invalid_lines': invalidLines,
        'files': files,
        'collected_at': DateTime.now().toUtc().toIso8601String(),
      };
    } on Object {
      status = {'state': 'gap', 'reason': 'device_collection_failed'};
    }
  }

  Future<void> close() async {
    for (final writer in _writers.values) {
      await writer.close();
    }
  }
}
