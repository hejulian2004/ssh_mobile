import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:app_diagnostics/app_diagnostics.dart';

import 'android_collector.dart';
import 'run_store.dart';

const appPackages = {
  'full': ('ssh_mobile_full', 'com.example.ssh_mobile'),
  'ssh': ('ssh_mobile_ssh', 'com.sshmobile.ssh_mobile_ssh'),
  'network': ('ssh_mobile_network', 'com.sshmobile.ssh_mobile_network'),
  'terminal': ('ssh_mobile_terminal', 'com.sshmobile.ssh_mobile_terminal'),
};

/// Fixed launch plans; arguments are passed directly, never as shell text.
List<String> componentCommand(
  String component, {
  required String runId,
  required String output,
  String app = 'full',
  String device = 'windows',
  String? target,
}) {
  if (!appPackages.containsKey(app)) throw ArgumentError('Unknown App');
  if (target != null &&
      (target.contains('..') ||
          !RegExp(r'^(lib|test)/[A-Za-z0-9_./-]+\.dart$').hasMatch(target))) {
    throw ArgumentError('Target must be an App-owned Dart entry point');
  }
  return switch (component) {
    'app' => [
      'flutter',
      'run',
      '--debug',
      '-d',
      device,
      if (target != null) ...['-t', target],
      '--dart-define=SSH_MOBILE_LOG_RUN_ID=$runId',
      '--dart-define=SSH_MOBILE_LOG_DIR=$output',
    ],
    'front' => ['npm', 'run', 'dev', '--', '--host', '127.0.0.1'],
    'relay' || 'admin' => ['go', 'run', './cmd/$component'],
    _ => throw ArgumentError('Components: app, relay, admin, front'),
  };
}

/// Dedicated worker owns live Process objects. stop never kills an unrelated PID.
Future<void> runWorker(
  RunStore store,
  String id,
  Directory repository,
  List<String> components, {
  String app = 'full',
  String device = 'windows',
  String? target,
  Map<String, String> executables = const {},
}) async {
  final manifest = store.read(id);
  final directory = store.directoryFor(id);
  final statuses = manifest['components'] as Map<String, dynamic>;
  final processes = <String, Process>{};
  final processExits = <String, int>{};
  final sinks = <DiagnosticFileSink>[];
  final subscriptions = <StreamSubscription<dynamic>>[];
  final outputDrains = <Future<void>>[];
  final logger = DiagnosticFileSink(
    directory: directory,
    runId: id,
    component: 'tool',
  );
  sinks.add(logger);
  final stopFile = File('${directory.path}/.stop');
  AndroidCollector? collector;
  var stopping = false;
  void log(
    String event, {
    LogLevel level = LogLevel.info,
    Map<String, dynamic> attributes = const {},
  }) {
    logger.write(
      LogRecord(
        timestamp: DateTime.now(),
        level: level,
        message: event,
        eventName: event,
        attributes: attributes,
      ),
    );
  }

  Future<void> save() => store.save(manifest);
  Future<void> capture(Process process, String component) async {
    final sink = DiagnosticFileSink(
      directory: directory,
      runId: id,
      component: component,
    );
    sinks.add(sink);
    for (final stream in [process.stdout, process.stderr]) {
      final drained = Completer<void>();
      outputDrains.add(drained.future);
      subscriptions.add(
        stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (line) {
                // Compiler output and arbitrary console values are not safe log records.
                // Only the owned, versioned component envelopes enter the shared writer.
                try {
                  if (line.length > 65536) return;
                  final record = jsonDecode(line) as Map<String, dynamic>;
                  if (record['schema_version'] != 1 ||
                      record['run_id'] != id ||
                      record['component'] != component)
                    return;
                  if (component == 'front' &&
                      record['event'] == 'browser_ready') {
                    statuses[component]['browser_seen'] = true;
                  }
                  if (record['event'] == 'diagnostic_dropped') {
                    manifest['upstream_dropped'] = true;
                  }
                  sink.write(
                    LogRecord(
                      timestamp: DateTime.parse(
                        record['occurred_at'] as String,
                      ),
                      level: LogLevel.values.byName(record['level'] as String),
                      message: record['message'] as String,
                      source: record['source'] as String?,
                      eventName: record['event'] as String?,
                      traceId: record['trace_id'] as String?,
                      errorCode: record['error_code'] as String?,
                      details: record['details'] as String?,
                      error: record['error'],
                      stackTrace: record['stack'] == null
                          ? null
                          : StackTrace.fromString(record['stack'] as String),
                      attributes: Map<String, dynamic>.from(
                        record['attributes'] as Map? ?? {},
                      ),
                    ),
                  );
                } on Object {
                  /* Suppress unstructured process output before persistence. */
                }
              },
              onError: (Object _) {
                log('process_output_failed', level: LogLevel.error);
                if (!drained.isCompleted) drained.complete();
              },
              onDone: () {
                if (!drained.isCompleted) drained.complete();
              },
            ),
      );
    }
  }

  try {
    manifest['worker_pid'] = pid;
    manifest['state'] = 'launching';
    await save();
    final ports = <String, int>{};
    for (final component in components.where((c) => c != 'app')) {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      ports[component] = socket.port;
      await socket.close();
    }
    for (final component in components) {
      final command = componentCommand(
        component,
        runId: id,
        output: directory.path,
        app: app,
        device: device,
        target: target,
      );
      final workingDirectory = component == 'app'
          ? '${repository.path}/apps/${appPackages[app]!.$1}'
          : component == 'front'
          ? '${repository.path}/front'
          : '${repository.path}/relay';
      final environment = <String, String>{
        'SSH_MOBILE_LOG_RUN_ID': id,
        'SSH_MOBILE_LOG_DIR': directory.path,
        if (component == 'relay') ...{
          'RELAY_ADDR': '127.0.0.1:${ports[component]}',
          'RELAY_STORAGE_MODE': 'memory',
          'RELAY_PUBLIC_URL': 'http://127.0.0.1:${ports[component]}',
        },
        if (component == 'admin') ...{
          'ADMIN_ADDR': '127.0.0.1:${ports[component]}',
          if (ports['relay'] != null)
            'ADMIN_RELAY_URL': 'http://127.0.0.1:${ports['relay']}',
          'TELEMETRY_MYSQL_DSN': '',
          'TELEMETRY_REDIS_URL': '',
        },
        if (component == 'front') ...{
          'FRONT_DEV_PORT': '${ports[component]}',
          'VITE_SSH_MOBILE_LOG_RUN_ID': id,
          if (ports['relay'] != null)
            'RELAY_DEV_API_ORIGIN': 'http://127.0.0.1:${ports['relay']}',
          if (ports['admin'] != null)
            'ADMIN_DEV_API_ORIGIN': 'http://127.0.0.1:${ports['admin']}',
        },
      };
      try {
        // Credentials are inherited in memory from the caller, never copied to
        // run.json or arguments. No .env file or external DB is opened by tooling.
        final process = await Process.start(
          executables[command.first] ?? command.first,
          command.skip(1).toList(),
          workingDirectory: workingDirectory,
          environment: environment,
          runInShell:
              Platform.isWindows &&
              command.first != 'go' &&
              !(executables[command.first] ?? command.first)
                  .toLowerCase()
                  .endsWith('.exe'),
        );
        processes[component] = process;
        statuses[component] = {
          'state': 'started',
          'pid': process.pid,
          if (ports[component] != null)
            'url': 'http://127.0.0.1:${ports[component]}',
        };
        await capture(process, component);
        unawaited(
          process.exitCode.then((code) {
            processExits[component] = code;
            statuses[component] = {
              ...statuses[component] as Map,
              'state': stopping ? 'stopped' : 'exited',
              'exit_code': code,
            };
            if (!stopping)
              log(
                'component_exited',
                level: code == 0 ? LogLevel.info : LogLevel.error,
                attributes: {'status_code': code},
              );
          }),
        );
      } on Object {
        statuses[component] = {
          'state': 'failed',
          'reason': 'process_launch_failed',
        };
        log('process_launch_failed', level: LogLevel.error);
      }
      await save();
    }
    if (components.contains('app') &&
        device != 'windows' &&
        device != 'linux' &&
        device != 'macos') {
      collector = AndroidCollector(
        directory,
        runId: id,
        device: device,
        package: appPackages[app]!.$2,
        adb: executables['adb'] ?? 'adb',
      );
    }
    manifest['state'] = 'running';
    log('collection_started');
    await save();
    final began = DateTime.now();
    while (!await stopFile.exists()) {
      if (collector != null) {
        await collector.collect();
        manifest['android_collection'] = collector.status;
      }
      // Probe HTTP readiness rather than declaring a successful spawn ready.
      for (final component in ports.keys) {
        if (processExits.containsKey(component) ||
            !processes.containsKey(component))
          continue;
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 1);
        try {
          final request = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:${ports[component]}${component == 'relay'
                  ? '/healthz'
                  : component == 'admin'
                  ? '/api/admin/v1/auth/session'
                  : '/'}',
            ),
          );
          final response = await request.close().timeout(
            const Duration(seconds: 2),
          );
          await response.drain<void>().timeout(const Duration(seconds: 2));
          if (response.statusCode < 500) statuses[component]['state'] = 'ready';
        } on Object {
          /* Remains started until ready or the startup deadline. */
        } finally {
          client.close(force: true);
        }
      }
      if (DateTime.now().difference(began) > const Duration(minutes: 3)) {
        for (final value in statuses.values) {
          if (value['state'] == 'started') value['readiness'] = 'unconfirmed';
        }
      }
      manifest['heartbeat_at'] = DateTime.now().toUtc().toIso8601String();
      await save();
      if (processes.isEmpty || processExits.length == processes.length) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  } on Object {
    manifest['state'] = 'failed';
    log('worker_failed', level: LogLevel.error);
  } finally {
    stopping = true;
    for (final entry in processes.entries.toList().reversed) {
      if (processExits.containsKey(entry.key)) continue;
      if (entry.key == 'front' && statuses[entry.key]['url'] is String) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 1);
        try {
          final request = await client.postUrl(
            Uri.parse('${statuses[entry.key]['url']}/__agent_stop'),
          );
          request.headers.set('x-ssh-mobile-run', id);
          await (await request.close()).drain<void>().timeout(
            const Duration(seconds: 2),
          );
        } on Object {
          /* Fall back to stopping only the still-owned process. */
        } finally {
          client.close(force: true);
        }
      }
      if (entry.key == 'app')
        try {
          entry.value.stdin.writeln('q');
        } on Object {
          /* It may have just exited. */
        }
      else if (!Platform.isWindows)
        entry.value.kill(ProcessSignal.sigterm);
      try {
        await entry.value.exitCode.timeout(const Duration(seconds: 8));
      } on TimeoutException {
        // The worker still owns this live Process; its PID has not been recycled.
        if (Platform.isWindows) {
          await Process.run('taskkill', [
            '/PID',
            '${entry.value.pid}',
            '/T',
            '/F',
          ]);
        } else {
          entry.value.kill(ProcessSignal.sigkill);
        }
        manifest['forced_stop'] = true;
      }
    }
    if (collector != null) {
      await collector.collect();
      manifest['android_collection'] = collector.status;
    }
    await collector?.close();
    try {
      await Future.wait(outputDrains).timeout(const Duration(seconds: 3));
    } on TimeoutException {
      manifest['output_drain_incomplete'] = true;
    }
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    log('collection_stopped');
    for (final sink in sinks) {
      await sink.close();
    }
    if (manifest['state'] != 'failed') manifest['state'] = 'stopped';
    manifest['ended_at'] = DateTime.now().toUtc().toIso8601String();
    await save();
  }
}
