import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_logs/launcher.dart';
import 'agent_logs/query.dart';
import 'agent_logs/run_store.dart';

Future<void> main(List<String> arguments) async {
  try {
    await agentLogs(arguments);
  } on Object catch (error) {
    // Errors may contain host paths/configuration; emit only a stable category.
    stderr.writeln(
      jsonEncode({
        'error': error is ArgumentError
            ? 'invalid_arguments'
            : 'operation_failed',
        'hint':
            'Use help; verify run, checkout, tools and local service configuration.',
      }),
    );
    exitCode = 1;
  }
}

Future<void> agentLogs(List<String> arguments) async {
  if (arguments.isEmpty || arguments.first == 'help') {
    stdout.writeln(
      'agent_logs start|runs|query|summary|stop|clean\n'
      '--run ID --components app,relay,admin,front --app full|ssh|network|terminal\n'
      '--device windows|ANDROID_SERIAL --output-dir DIRECTORY\n'
      'app: --target lib/main.dart|test/device/diagnostics_probe.dart\n'
      'query: --component NAME --level LEVEL --event NAME --trace ID --since UTC --limit 1..1000 --follow\n'
      'start returns launching; summary reports readiness/collection gaps. Credentials are inherited from the caller.',
    );
    return;
  }
  final options = <String, String>{};
  for (var i = 1; i < arguments.length; i++) {
    final key = arguments[i];
    if (!key.startsWith('--')) throw ArgumentError('Expected option');
    if (key == '--follow') {
      options['follow'] = 'true';
      continue;
    }
    if (++i >= arguments.length) throw ArgumentError('Missing value');
    options[key.substring(2)] = arguments[i];
  }
  const allowed = {
    'run',
    'components',
    'app',
    'device',
    'output-dir',
    'component',
    'level',
    'event',
    'trace',
    'since',
    'limit',
    'follow',
    'target',
    'flutter',
    'go',
    'npm',
    'adb',
  };
  if (options.keys.any((key) => !allowed.contains(key)))
    throw ArgumentError('Unknown option');
  final repository = Directory.current;
  final store = RunStore(
    Directory(
      options['output-dir'] ?? '${repository.path}/build/agent-observability',
    ),
    checkoutId: RunStore.checkoutKey(repository.path),
  );
  final command = arguments.first;
  if (command == 'runs') {
    stdout.writeln(jsonEncode(await store.list()));
    return;
  }
  if (command == 'clean') {
    stdout.writeln(jsonEncode({'removed': await store.clean()}));
    return;
  }
  if (command == 'start') {
    final components = (options['components'] ?? 'app')
        .split(',')
        .toSet()
        .toList();
    for (final component in components) {
      componentCommand(
        component,
        runId: 'validate',
        output: '.',
        app: options['app'] ?? 'full',
        target: options['target'],
      );
    }
    final revision = await Process.run('git', ['rev-parse', 'HEAD']);
    final run = await store.create(
      revision: revision.exitCode == 0
          ? (revision.stdout as String).trim()
          : 'unknown',
    );
    final id = run['run_id'] as String;
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '${repository.path}/tool/agent_logs.dart',
        'worker',
        '--run',
        id,
        '--output-dir',
        store.root.absolute.path,
        '--components',
        components.join(','),
        '--app',
        options['app'] ?? 'full',
        '--device',
        options['device'] ?? 'windows',
        if (options['target'] != null) ...['--target', options['target']!],
        for (final name in ['flutter', 'go', 'npm', 'adb'])
          if (options[name] != null) ...['--$name', options[name]!],
      ],
      workingDirectory: repository.path,
      mode: ProcessStartMode.detached,
    );
    stdout.writeln(
      jsonEncode({
        'run_id': id,
        'state': 'launching',
        'worker_pid': process.pid,
        'directory': store.directoryFor(id).path,
      }),
    );
    return;
  }
  final id = options['run'];
  if (id == null) throw ArgumentError('Explicit --run is required');
  final manifest = store.read(id);
  final directory = store.directoryFor(id);
  if (command == 'worker') {
    await runWorker(
      store,
      id,
      repository,
      (options['components'] ?? 'app').split(','),
      app: options['app'] ?? 'full',
      device: options['device'] ?? 'windows',
      target: options['target'],
      executables: {
        for (final name in ['flutter', 'go', 'npm', 'adb'])
          if (options[name] != null) name: options[name]!,
      },
    );
    return;
  }
  if (command == 'stop') {
    await File('${directory.path}/.stop').writeAsString('stop\n');
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!{'stopped', 'failed'}.contains(store.read(id)['state']) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final result = store.read(id);
    stdout.writeln(jsonEncode(result));
    if (!{'stopped', 'failed'}.contains(result['state'])) exitCode = 2;
    return;
  }
  if (command != 'query' && command != 'summary')
    throw ArgumentError('Unknown command');
  final seen = <String>{};
  do {
    final result = await queryLogs(
      directory,
      runId: id,
      component: options['component'],
      level: options['level'],
      event: options['event'],
      traceId: options['trace'],
      since: options['since'] == null
          ? null
          : DateTime.parse(options['since']!),
      limit: int.parse(options['limit'] ?? '100'),
    );
    if (options['follow'] == 'true') {
      for (final record in result.records) {
        final key = jsonEncode(record);
        if (seen.add(key)) stdout.writeln(key);
      }
      if (seen.length > 10000) seen.clear();
      if ({'stopped', 'failed'}.contains(store.read(id)['state'])) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    } else {
      stdout.writeln(
        jsonEncode({
          'run': manifest,
          if (command == 'summary')
            ...summarizeLogs(result, manifest: store.read(id))
          else
            ...result.toJson(),
          'complete': summarizeLogs(
            result,
            manifest: store.read(id),
          )['complete'],
          'gaps': summarizeLogs(result, manifest: store.read(id))['gaps'],
        }),
      );
    }
  } while (options['follow'] == 'true');
}
