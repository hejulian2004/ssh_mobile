import 'dart:convert';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:app_diagnostics/app_diagnostics.dart';

final class LogQueryResult {
  final records = <Map<String, dynamic>>[];
  int invalidLines = 0;
  int filesRead = 0;
  final health = <String, dynamic>{};
  Map<String, dynamic> toJson() => {
    'records': records,
    'invalid_lines': invalidLines,
    'files_read': filesRead,
    'health': health,
    'complete':
        filesRead > 0 &&
        invalidLines == 0 &&
        health.isNotEmpty &&
        health.values.every(
          (dynamic h) => h['failed'] == 0 && h['dropped'] == 0,
        ),
  };
}

/// Reads bounded lines and retains only the newest requested matching records.
Future<LogQueryResult> queryLogs(
  Directory directory, {
  required String runId,
  String? component,
  String? level,
  String? event,
  String? traceId,
  DateTime? since,
  int limit = 100,
}) async {
  if (limit < 1 || limit > 1000)
    throw ArgumentError('Limit must be between 1 and 1000');
  final result = LogQueryResult();
  final files = await directory
      .list(followLinks: false)
      .where((e) => e is File)
      .cast<File>()
      .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    if (file.path.endsWith('.health.json')) {
      try {
        final value = jsonDecode(await file.readAsString());
        if (value is Map && value['failed'] is int && value['dropped'] is int) {
          result.health[file.uri.pathSegments.last] = {
            for (final key in ['written', 'failed', 'dropped'])
              if (value[key] is int && value[key] >= 0) key: value[key],
            if (value['closed'] is bool) 'closed': value['closed'],
          };
        }
      } on Object {
        result.invalidLines++;
      }
      continue;
    }
    if (!RegExp(r'\.jsonl(?:\.[1-3])?$').hasMatch(file.path)) continue;
    if (await file.length() > 6 * 1024 * 1024) {
      result.invalidLines++;
      continue;
    }
    result.filesRead++;
    var lineNumber = 0;
    try {
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        lineNumber++;
        if (line.length > 65536) {
          result.invalidLines++;
          continue;
        }
        try {
          final raw = jsonDecode(line) as Map<String, dynamic>;
          final timestamp = DateTime.parse(raw['occurred_at'] as String);
          if (raw['schema_version'] != 1 || raw['run_id'] != runId) {
            result.invalidLines++;
            continue;
          }
          if (component != null && raw['component'] != component ||
              level != null && raw['level'] != level ||
              event != null && raw['event'] != event ||
              traceId != null && raw['trace_id'] != traceId ||
              since != null && timestamp.isBefore(since))
            continue;
          final safe =
              jsonDecode(
                    DiagnosticEnvelope(
                      runId: runId,
                      instanceId: raw['instance_id'] as String,
                      component: raw['component'] as String,
                    ).encode(
                      LogRecord(
                        timestamp: timestamp,
                        level: LogLevel.values.byName(raw['level'] as String),
                        message: raw['message'] as String,
                        source: raw['source'] as String?,
                        eventName: raw['event'] as String?,
                        traceId: raw['trace_id'] as String?,
                        errorCode: raw['error_code'] as String?,
                        details: raw['details'] as String?,
                        error: raw['error'],
                        stackTrace: raw['stack'] == null
                            ? null
                            : StackTrace.fromString(raw['stack'] as String),
                        attributes: Map<String, dynamic>.from(
                          raw['attributes'] as Map? ?? {},
                        ),
                      ),
                    ),
                  )
                  as Map<String, dynamic>;
          safe['file'] = file.path;
          safe['line'] = lineNumber;
          if (raw['collected_at'] is String)
            safe['collected_at'] = DateTime.parse(
              raw['collected_at'] as String,
            ).toUtc().toIso8601String();
          result.records.add(safe);
          result.records.sort(
            (a, b) => (a['occurred_at'] as String).compareTo(
              b['occurred_at'] as String,
            ),
          );
          if (result.records.length > limit) result.records.removeAt(0);
        } on Object {
          result.invalidLines++;
        }
      }
    } on Object {
      result.invalidLines++;
    }
  }
  return result;
}

Map<String, dynamic> summarizeLogs(
  LogQueryResult result, {
  Map<String, dynamic>? manifest,
}) {
  final gaps = <String>[];
  if (result.invalidLines > 0) gaps.add('invalid_or_incomplete_records');
  if (result.filesRead == 0) gaps.add('missing_log_files');
  if (result.health.isEmpty) gaps.add('missing_output_health');
  if (result.health.values.any(
    (dynamic h) => h['failed'] != 0 || h['dropped'] != 0,
  ))
    gaps.add('output_failed_or_dropped');
  if (manifest != null) {
    if (manifest['forced_stop'] == true) gaps.add('forced_stop');
    if (manifest['upstream_dropped'] == true) gaps.add('upstream_dropped');
    if (manifest['output_drain_incomplete'] == true)
      gaps.add('output_drain_incomplete');
    if (manifest['state'] == 'failed') gaps.add('worker_failed');
    final components = manifest['components'] as Map? ?? {};
    for (final entry in components.entries) {
      final component = entry.key == 'app' ? 'flutter' : entry.key;
      if (entry.key == 'front' && entry.value['browser_seen'] != true) {
        gaps.add('missing_browser_confirmation');
      }
      if (!result.health.keys.any(
        (name) =>
            name.startsWith('$component-') ||
            name.startsWith('android-$component-'),
      )) {
        gaps.add('missing_${entry.key}_logs');
      }
      if (entry.value['state'] == 'failed' ||
          (entry.value['exit_code'] ?? 0) != 0)
        gaps.add('${entry.key}_failed');
      if (entry.value['readiness'] == 'unconfirmed')
        gaps.add('${entry.key}_readiness_unconfirmed');
    }
    if (manifest['android_collection'] case final Map android) {
      if (android['state'] != 'collecting')
        gaps.add('android_collection_incomplete');
      if ((android['invalid_lines'] as int? ?? 0) > 0)
        gaps.add('android_invalid_or_incomplete_records');
    }
    if (!{'stopped', 'failed'}.contains(manifest['state'])) {
      final heartbeat = DateTime.tryParse(
        manifest['heartbeat_at'] as String? ?? '',
      );
      if (heartbeat == null ||
          DateTime.now().toUtc().difference(heartbeat) >
              const Duration(seconds: 30))
        gaps.add('stale_worker_heartbeat');
    }
  }
  return {
    'errors': result.records.where((r) => r['level'] == 'error').toList(),
    'last_activity': result.records.isEmpty ? null : result.records.last,
    'durations': result.records
        .where((r) => (r['attributes'] as Map).containsKey('duration_ms'))
        .toList(),
    'health': result.health,
    'invalid_lines': result.invalidLines,
    'files_read': result.filesRead,
    'complete': gaps.isEmpty,
    'gaps': gaps,
    'note':
        'Summary covers the bounded query result; missing collection is not evidence of success.',
  };
}
