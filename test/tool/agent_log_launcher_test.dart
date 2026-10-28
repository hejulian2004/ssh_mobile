import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import '../../tool/agent_logs/launcher.dart';
import '../../tool/agent_logs/run_store.dart';

void main() {
  late Directory tools;
  late String binary;
  setUpAll(() async {
    tools = Directory.systemTemp.createTempSync('launch_fixture_');
    binary = '${tools.path}/process${Platform.isWindows ? '.exe' : ''}';
    final build = await Process.run('dart', [
      'compile',
      'exe',
      'test/fixtures/diagnostic_process.dart',
      '-o',
      binary,
    ], runInShell: Platform.isWindows);
    expect(build.exitCode, 0, reason: '${build.stderr}');
  });
  tearDownAll(() => tools.deleteSync(recursive: true));
  test(
    'launches only known components and keeps run context as separate arguments',
    () {
      final app = componentCommand(
        'app',
        runId: 'run',
        output: 'fixture output',
        app: 'ssh',
        device: 'fixture-device',
      );
      expect(app, contains('--dart-define=SSH_MOBILE_LOG_DIR=fixture output'));
      expect(app, contains('fixture-device'));
      expect(componentCommand('front', runId: 'run', output: '.').first, 'npm');
      expect(
        componentCommand('relay', runId: 'run', output: '.'),
        contains('./cmd/relay'),
      );
      expect(
        () => componentCommand('unknown', runId: 'run', output: '.'),
        throwsArgumentError,
      );
      expect(
        () =>
            componentCommand('app', runId: 'run', output: '.', app: 'unknown'),
        throwsArgumentError,
      );
    },
  );
  test(
    'empty worker closes output and never adopts an unrelated process',
    () async {
      final root = Directory.systemTemp.createTempSync('empty_worker_');
      try {
        final store = RunStore(root, checkoutId: 'fixture');
        final manifest = await store.create(revision: 'fixture');
        final id = manifest['run_id'] as String;
        await runWorker(store, id, Directory.current, []);
        expect(store.read(id)['state'], 'stopped');
        expect(store.read(id)['components'], isEmpty);
        expect(store.read(id).containsKey('forced_stop'), false);
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
  test(
    'worker owns selected processes, collects safe records and drains on stop',
    () async {
      final root = Directory.systemTemp.createTempSync('worker_processes_');
      try {
        final store = RunStore(root, checkoutId: 'fixture');
        final manifest = await store.create(revision: 'fixture');
        final id = manifest['run_id'] as String;
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        final stop = Timer.periodic(const Duration(milliseconds: 50), (timer) {
          final state = store.read(id);
          if (state['components']['front']?['state'] == 'ready' ||
              DateTime.now().isAfter(deadline)) {
            File(
              '${store.directoryFor(id).path}/.stop',
            ).writeAsStringSync('stop');
            timer.cancel();
          }
        });
        try {
          await runWorker(
            store,
            id,
            Directory.current,
            ['relay', 'admin', 'front', 'app'],
            device: 'fixture-device',
            target: 'test/device/diagnostics_probe.dart',
            executables: {
              'go': binary,
              'npm': binary,
              'flutter': binary,
              'adb': binary,
            },
          );
        } finally {
          stop.cancel();
        }
        final ended = store.read(id);
        expect(ended['state'], 'stopped');
        expect(ended['forced_stop'], isNot(true));
        expect(ended['android_collection']['state'], 'collecting');
        expect(ended['components']['front']['browser_seen'], true);
        expect(ended['upstream_dropped'], true);
        final records = store
            .directoryFor(id)
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.jsonl'));
        final text = records.map((file) => file.readAsStringSync()).join();
        expect(text, contains('fixture_ready'));
        expect(text, isNot(contains('unstructured')));
        expect(text, contains('fixture-trace'));
        expect(text, isNot(contains('fixture-value')));
        for (final file in records) {
          for (final line in file.readAsLinesSync()) {
            expect(jsonDecode(line)['run_id'], id);
          }
        }
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
  test(
    'launch failure is a component gap and does not leak a worker',
    () async {
      final root = Directory.systemTemp.createTempSync('failed_worker_');
      try {
        final store = RunStore(root, checkoutId: 'fixture');
        final run = await store.create(revision: 'fixture');
        await runWorker(
          store,
          run['run_id'] as String,
          Directory.current,
          ['relay'],
          executables: {'go': '${root.path}/missing'},
        );
        expect(
          store.read(run['run_id'] as String)['components']['relay']['state'],
          'failed',
        );
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
}
