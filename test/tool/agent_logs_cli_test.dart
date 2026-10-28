import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:test/test.dart';
import '../../tool/agent_logs.dart' as cli;
import '../../tool/agent_logs/run_store.dart';

final class _Output implements Stdout {
  final buffer = StringBuffer();
  @override
  void writeln([Object? object = '']) => buffer.writeln(object);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<String> invoke(List<String> arguments) async {
  final output = _Output();
  await IOOverrides.runZoned(
    () => cli.agentLogs(arguments),
    stdout: () => output,
  );
  return output.buffer.toString();
}

void main() {
  test(
    'main reports stable categories without leaking configuration',
    () async {
      final output = _Output();
      final previous = exitCode;
      try {
        await IOOverrides.runZoned(
          () async {
            await cli.main(['query', '--unknown', 'private-value']);
            expect(exitCode, 1);
            expect(output.buffer.toString(), contains('invalid_arguments'));
            expect(output.buffer.toString(), isNot(contains('private-value')));
            await cli.main([
              'query',
              '--run',
              'missing-run',
              '--output-dir',
              Directory.systemTemp.path,
            ]);
            expect(output.buffer.toString(), contains('operation_failed'));
            await cli.main(['help']);
          },
          stdout: () => output,
          stderr: () => output,
        );
      } finally {
        exitCode = previous;
      }
    },
  );
  test(
    'start, worker and stop use the same owned run and selected toolchain',
    () async {
      final root = Directory.systemTemp.createTempSync('cli_lifecycle_');
      final binary = '${root.path}/process${Platform.isWindows ? '.exe' : ''}';
      final build = await Process.run('dart', [
        'compile',
        'exe',
        'test/fixtures/diagnostic_process.dart',
        '-o',
        binary,
      ], runInShell: Platform.isWindows);
      expect(build.exitCode, 0, reason: '${build.stderr}');
      final store = RunStore(
        root,
        checkoutId: RunStore.checkoutKey(Directory.current.path),
      );
      String? id;
      try {
        final started =
            jsonDecode(
                  await invoke([
                    'start',
                    '--output-dir',
                    root.path,
                    '--components',
                    'app',
                    '--target',
                    'test/device/diagnostics_probe.dart',
                    '--flutter',
                    binary,
                    '--adb',
                    binary,
                  ]),
                )
                as Map;
        id = started['run_id'] as String;
        expect(started['state'], 'launching');
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (store.read(id)['state'] != 'running' &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(store.read(id)['state'], 'running');
        expect(
          jsonDecode(
            await invoke(['stop', '--run', id, '--output-dir', root.path]),
          )['state'],
          'stopped',
        );
        final direct = await store.create(revision: 'fixture');
        await invoke([
          'worker',
          '--run',
          direct['run_id'] as String,
          '--output-dir',
          root.path,
          '--components',
          'relay',
          '--go',
          binary,
        ]);
        expect(
          store.read(
            direct['run_id'] as String,
          )['components']['relay']['exit_code'],
          0,
        );
      } finally {
        if (id != null &&
            !{'stopped', 'failed'}.contains(store.read(id)['state'])) {
          await invoke(['stop', '--run', id, '--output-dir', root.path]);
        }
        root.deleteSync(recursive: true);
      }
    },
  );
  test(
    'help and invalid arguments are bounded and do not start processes',
    () async {
      expect(await invoke([]), contains('start|runs|query|summary|stop|clean'));
      expect(await invoke(['help']), contains('--run'));
      await expectLater(invoke(['query']), throwsArgumentError);
      await expectLater(invoke(['runs', 'invalid']), throwsArgumentError);
      await expectLater(invoke(['query', '--run']), throwsArgumentError);
      await expectLater(
        invoke(['start', '--unknown', 'value']),
        throwsArgumentError,
      );
      await expectLater(
        invoke(['start', '--components', 'unknown']),
        throwsArgumentError,
      );
    },
  );
  test(
    'runs, filtered query, summary, stop and cleanup preserve the same explicit run',
    () async {
      final root = Directory.systemTemp.createTempSync('cli_logs_');
      try {
        final store = RunStore(
          root,
          checkoutId: RunStore.checkoutKey(Directory.current.path),
        );
        final run = await store.create(revision: 'fixture');
        final id = run['run_id'] as String;
        run['state'] = 'stopped';
        await store.save(run);
        final common = ['--run', id, '--output-dir', root.path];
        await File(
          '${store.directoryFor(id).path}/flutter-instance.jsonl',
        ).writeAsString(
          '${jsonEncode({'schema_version': 1, 'occurred_at': '2026-01-01T00:00:00Z', 'run_id': id, 'instance_id': 'instance', 'component': 'flutter', 'level': 'error', 'message': 'fixture failure', 'event': 'fixture_failure', 'trace_id': 'trace', 'attributes': {}})}\n',
        );
        expect(
          jsonDecode(await invoke(['runs', '--output-dir', root.path])),
          hasLength(1),
        );
        final query =
            jsonDecode(
                  await invoke([
                    'query',
                    ...common,
                    '--component',
                    'flutter',
                    '--level',
                    'error',
                    '--event',
                    'fixture_failure',
                    '--trace',
                    'trace',
                    '--since',
                    '2025-01-01T00:00:00Z',
                    '--limit',
                    '1',
                  ]),
                )
                as Map;
        expect(query['records'], hasLength(1));
        expect(
          await invoke(['query', ...common, '--follow']),
          contains('fixture_failure'),
        );
        expect(
          jsonDecode(await invoke(['summary', ...common]))['complete'],
          false,
        );
        expect(
          jsonDecode(await invoke(['stop', ...common]))['state'],
          'stopped',
        );
        expect(
          jsonDecode(
            await invoke(['clean', '--output-dir', root.path]),
          )['removed'],
          0,
        );
        await expectLater(invoke(['unknown', ...common]), throwsArgumentError);
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
}
