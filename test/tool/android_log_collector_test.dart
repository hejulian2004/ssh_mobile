import 'dart:io';
import 'package:test/test.dart';
import '../../tool/agent_logs/android_collector.dart';

void main() {
  late Directory tools;
  late String binary;
  setUpAll(() async {
    tools = Directory.systemTemp.createTempSync('diagnostic_transport_');
    binary = '${tools.path}/transport${Platform.isWindows ? '.exe' : ''}';
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
    'collects only complete run records, redacts again and deduplicates snapshots',
    () async {
      final output = Directory.systemTemp.createTempSync('android_collection_');
      final collector = AndroidCollector(
        output,
        runId: 'test-run',
        device: 'fixture',
        package: 'com.example.fixture',
        adb: binary,
      );
      try {
        await collector.collect();
        await collector.collect();
        await collector.close();
        final file = output.listSync().whereType<File>().singleWhere(
          (f) => f.path.endsWith('.jsonl'),
        );
        final text = await file.readAsString();
        expect(text, isNot(contains('fixture-value')));
        expect(text.split('\n').where((line) => line.isNotEmpty), hasLength(1));
        expect(text, contains('collected_at'));
        expect(collector.status['state'], 'collecting');
        expect(collector.status['invalid_lines'], 1);
        expect(
          await File(
            '${output.path}/android-flutter-instance.health.json',
          ).readAsString(),
          isNot(contains('private-value')),
        );
        expect(
          File(
            '${output.path}/android-flutter-instance.health.json',
          ).existsSync(),
          true,
        );
      } finally {
        output.deleteSync(recursive: true);
      }
    },
  );
  test(
    'an unavailable device is an explicit gap; invalid targets are rejected',
    () async {
      expect(
        () => AndroidCollector(
          tools,
          runId: '../bad',
          device: 'fixture',
          package: 'com.fixture',
        ),
        throwsArgumentError,
      );
      expect(
        () => AndroidCollector(
          tools,
          runId: 'run',
          device: 'android',
          package: 'com.fixture',
        ),
        throwsArgumentError,
      );
      final collector = AndroidCollector(
        tools,
        runId: 'test-run',
        device: 'offline',
        package: 'com.fixture',
        adb: binary,
      );
      await collector.collect();
      expect(collector.status['state'], 'gap');
      await collector.close();
      final missing = AndroidCollector(
        tools,
        runId: 'test-run',
        device: 'fixture',
        package: 'com.fixture',
        adb: '${tools.path}/missing',
      );
      await missing.collect();
      expect(missing.status['state'], 'gap');
    },
  );
}
