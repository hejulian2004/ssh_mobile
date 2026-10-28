import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:test/test.dart';
import '../../tool/agent_logs/run_store.dart';
import '../../tool/agent_logs/query.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('agent_logs_'));
  tearDown(() => directory.deleteSync(recursive: true));
  test(
    'manifest readers observe valid snapshots while the worker replaces them',
    () async {
      final store = RunStore(directory, checkoutId: 'fixture');
      final run = await store.create(revision: 'fixture');
      final id = run['run_id'] as String;
      var done = false;
      final writer = Isolate.run(() async {
        for (var i = 0; i < 100; i++) {
          await store.save({...run, 'heartbeat_index': i});
        }
      }).whenComplete(() => done = true);
      while (!done) {
        expect(store.read(id)['run_id'], id);
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await writer;
      expect(store.read(id)['heartbeat_index'], 99);
    },
  );
  test(
    'bounds corrupt, foreign and oversized input and keeps safe health fields',
    () async {
      final record = <String, dynamic>{
        'schema_version': 1,
        'run_id': 'run',
        'instance_id': 'instance',
        'component': 'native',
        'occurred_at': '2026-01-01T00:00:00Z',
        'level': 'error',
        'message': 'fixture',
        'details': 'password=private-value',
        'error': 'token=private-value',
        'stack': 'token=private-value',
        'collected_at': '2026-01-01T01:00:00Z',
        'attributes': {},
      };
      final lines = [
        jsonEncode(record),
        jsonEncode({...record, 'schema_version': 2}),
        jsonEncode({...record, 'run_id': 'foreign'}),
        'x' * 65537,
      ];
      await File(
        '${directory.path}/native-instance.jsonl',
      ).writeAsString('${lines.join('\n')}\n');
      await File('${directory.path}/bad.jsonl').writeAsBytes([255]);
      final huge = await File(
        '${directory.path}/huge.jsonl',
      ).open(mode: FileMode.write);
      await huge.truncate(6 * 1024 * 1024 + 1);
      await huge.close();
      await File('${directory.path}/bad.health.json').writeAsString('{invalid');
      await File('${directory.path}/native-instance.health.json').writeAsString(
        jsonEncode({
          'written': 1,
          'failed': 0,
          'dropped': 0,
          'private': 'private-value',
        }),
      );
      final result = await queryLogs(directory, runId: 'run', limit: 1);
      expect(result.invalidLines, 6);
      expect(result.records, hasLength(1));
      expect(result.records.single['collected_at'], '2026-01-01T01:00:00.000Z');
      expect(jsonEncode(result.toJson()), isNot(contains('private-value')));
      await expectLater(
        queryLogs(directory, runId: 'run', limit: 0),
        throwsArgumentError,
      );
      await expectLater(
        queryLogs(directory, runId: 'run', limit: 1001),
        throwsArgumentError,
      );
      expect(
        (await queryLogs(
          directory,
          runId: 'run',
          since: DateTime.utc(2027),
        )).records,
        isEmpty,
      );
    },
  );
  test(
    'summary reports lifecycle, delivery and readiness gaps independently',
    () {
      final result = LogQueryResult()..filesRead = 1;
      result.health['front-instance.health.json'] = {'failed': 0, 'dropped': 0};
      expect(
        summarizeLogs(
          result,
          manifest: {
            'state': 'stopped',
            'components': {
              'front': {'state': 'stopped', 'browser_seen': true},
            },
          },
        )['complete'],
        true,
      );
      result.invalidLines = 1;
      result.health['front-instance.health.json'] = {'failed': 1, 'dropped': 2};
      final gaps =
          summarizeLogs(
                result,
                manifest: {
                  'state': 'failed',
                  'forced_stop': true,
                  'upstream_dropped': true,
                  'output_drain_incomplete': true,
                  'android_collection': {'state': 'gap'},
                  'components': {
                    'app': {
                      'state': 'failed',
                      'exit_code': 1,
                      'readiness': 'unconfirmed',
                    },
                    'front': {'state': 'exited'},
                  },
                },
              )['gaps']
              as List;
      expect(
        gaps,
        containsAll([
          'invalid_or_incomplete_records',
          'output_failed_or_dropped',
          'forced_stop',
          'upstream_dropped',
          'output_drain_incomplete',
          'worker_failed',
          'missing_app_logs',
          'app_failed',
          'app_readiness_unconfirmed',
          'android_collection_incomplete',
          'missing_browser_confirmation',
        ]),
      );
      expect(
        summarizeLogs(LogQueryResult())['gaps'],
        containsAll(['missing_log_files', 'missing_output_health']),
      );
    },
  );
  test('isolates runs and rejects traversal or another checkout', () async {
    final store = RunStore(directory, checkoutId: 'checkout-one');
    final run = await store.create(revision: 'test-revision');
    expect((await store.list()).single['run_id'], run['run_id']);
    expect(() => store.directoryFor('../escape'), throwsArgumentError);
    final other = RunStore(directory, checkoutId: 'checkout-two');
    expect(() => other.read(run['run_id'] as String), throwsStateError);
  });
  test(
    'query handles rotation, filters, malformed tails and redacts again',
    () async {
      final store = RunStore(directory, checkoutId: 'checkout');
      final run = await store.create(revision: 'fixture');
      final dir = store.directoryFor(run['run_id'] as String);
      Map<String, Object> record(String level, int second) => {
        'schema_version': 1,
        'run_id': run['run_id']!,
        'instance_id': 'instance',
        'component': 'flutter',
        'occurred_at': DateTime.utc(2026, 1, 1, 0, 0, second).toIso8601String(),
        'level': level,
        'message': 'failed password=private-value',
        'trace_id': 'trace-one',
        'attributes': {'duration_ms': 25, 'payload': 'private-value'},
      };
      await File(
        '${dir.path}/flutter-instance.jsonl.1',
      ).writeAsString('${jsonEncode(record('info', 1))}\n');
      await File(
        '${dir.path}/flutter-instance.jsonl',
      ).writeAsString('${jsonEncode(record('error', 2))}\n{"broken":');
      final result = await queryLogs(
        dir,
        runId: run['run_id'] as String,
        level: 'error',
        limit: 1,
      );
      expect(result.records, hasLength(1));
      expect(result.invalidLines, 1);
      expect(jsonEncode(result.records), isNot(contains('private-value')));
      expect(result.records.single['attributes'], {'duration_ms': 25});
      expect(result.records.single['file'], contains('.jsonl'));
      expect(
        (await queryLogs(
          dir,
          runId: run['run_id'] as String,
          component: 'relay',
        )).records,
        isEmpty,
      );
    },
  );
  test('cleanup only removes ended runs older than retention', () async {
    final store = RunStore(directory, checkoutId: 'checkout');
    final old = await store.create(revision: 'fixture');
    old['state'] = 'stopped';
    old['created_at'] = '2020-01-01T00:00:00Z';
    await store.save(old);
    final active = await store.create(revision: 'fixture');
    active['created_at'] = '2020-01-01T00:00:00Z';
    await store.save(active);
    expect(await store.clean(), 1);
    expect((await store.list()).single['run_id'], active['run_id']);
  });

  test(
    'healthy tool output cannot hide missing component logs or a stale worker',
    () async {
      final result = LogQueryResult();
      result.filesRead = 1;
      result.health['tool-instance.health.json'] = {'failed': 0, 'dropped': 0};
      final manifest = <String, dynamic>{
        'state': 'running',
        'heartbeat_at': '2020-01-01T00:00:00Z',
        'components': {
          'front': {'state': 'ready'},
        },
      };
      final summary = summarizeLogs(result, manifest: manifest);
      expect(summary['complete'], false);
      expect(summary['gaps'], contains('missing_front_logs'));
      expect(summary['gaps'], contains('stale_worker_heartbeat'));
    },
  );
}
