import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_coverage.dart';

void main() {
  test('summarizeLcov excludes generated and third-party sources', () {
    final summary = summarizeLcov(const [
      'SF:lib/services/example.dart',
      'DA:1,1',
      'DA:2,0',
      'LF:999',
      'LH:999',
      'end_of_record',
      r'SF:lib\services\app_log_database.g.dart',
      'DA:3,1',
      'end_of_record',
      'SF:third_party/example.dart',
      'DA:4,1',
      'end_of_record',
      'SF:lib/third_party/another.dart',
      'DA:5,1',
      'end_of_record',
      'SF:lib/generated/schema.dart',
      'DA:6,1',
      'end_of_record',
      'SF:lib/services/model.freezed.dart',
      'DA:7,1',
      'end_of_record',
      'SF:lib/services/model.generated.dart',
      'DA:8,1',
      'end_of_record',
    ]);

    expect(summary.linesFound, 2);
    expect(summary.linesHit, 1);
    expect(summary.percentage, 50);
  });

  test('deduplicates the same source lines across shards and unions hits', () {
    final summary = summarizeLcovFiles([
      const ['SF:lib/foo.dart', 'DA:10,1', 'DA:11,0', 'end_of_record'],
      const ['SF:lib/foo.dart', 'DA:10,0', 'DA:11,1', 'end_of_record'],
    ]);

    expect(summary.linesFound, 2);
    expect(summary.linesHit, 2);
    expect(summary.percentage, 100);
  });

  test('deduplicates partially overlapping source line sets', () {
    final summary = summarizeLcovFiles([
      const ['SF:lib/foo.dart', 'DA:10,1', 'DA:11,1', 'end_of_record'],
      const ['SF:lib/foo.dart', 'DA:11,0', 'DA:12,1', 'end_of_record'],
    ]);

    expect(summary.linesFound, 3);
    expect(summary.linesHit, 3);
  });

  test('counts a line hit in both shards only once', () {
    final summary = summarizeLcovFiles([
      const ['SF:lib/foo.dart', 'DA:10,1', 'end_of_record'],
      const ['SF:lib/foo.dart', 'DA:10,1', 'end_of_record'],
    ]);

    expect(summary.linesFound, 1);
    expect(summary.linesHit, 1);
  });

  test('keeps equal line numbers in different sources distinct', () {
    final summary = summarizeLcovFiles([
      const ['SF:lib/foo.dart', 'DA:10,1', 'end_of_record'],
      const ['SF:lib/bar.dart', 'DA:10,1', 'end_of_record'],
    ]);

    expect(summary.linesFound, 2);
    expect(summary.linesHit, 2);
  });

  test('can scope coverage to an owner path and reports missed lines', () {
    final summary = summarizeLcov(
      const [
        'SF:/workspace/apps/ssh_mobile_full/lib/services/network/foo.dart',
        'DA:10,1',
        'DA:11,0',
        'end_of_record',
        'SF:lib/features/other.dart',
        'DA:20,0',
        'end_of_record',
      ],
      includePrefixes: const ['lib/services/network/'],
    );

    expect(summary.linesFound, 2);
    expect(summary.linesHit, 1);
    expect(
      summary.uncoveredLinesBySource,
      containsPair(
        '/workspace/apps/ssh_mobile_full/lib/services/network/foo.dart',
        [11],
      ),
    );
    expect(
      summary.uncoveredLinesBySource,
      isNot(contains('lib/features/other.dart')),
    );
  });

  test('reports a required new source that is absent from LCOV', () {
    final summary = summarizeLcov(
      const ['SF:lib/services/covered.dart', 'DA:1,1', 'end_of_record'],
      requiredSources: const ['lib/services/new_service.dart'],
    );

    expect(
      summary.missingRequiredSources,
      contains('lib/services/new_service.dart'),
    );
    expect(
      summary
          .requiredSourceCoverage['lib/services/new_service.dart']!
          .linesFound,
      0,
    );
  });

  test('tracks file-level coverage for required new sources', () {
    final summary = summarizeLcov(
      const [
        'SF:/workspace/apps/ssh_mobile_full/lib/services/new_service.dart',
        'DA:1,1',
        'DA:2,1',
        'DA:3,0',
        'end_of_record',
      ],
      requiredSources: const ['lib/services/new_service.dart'],
    );

    final coverage =
        summary.requiredSourceCoverage['lib/services/new_service.dart']!;
    expect(coverage.linesFound, 3);
    expect(coverage.linesHit, 2);
    expect(coverage.percentage, closeTo(66.666, 0.001));
  });

  test('keeps required sources inside the selected owner scope', () {
    final summary = summarizeLcov(
      const [
        'SF:lib/services/network/new_service.dart',
        'DA:1,1',
        'end_of_record',
      ],
      includePrefixes: const ['lib/services/network/'],
      requiredSources: const [
        'lib/services/network/new_service.dart',
        'lib/features/other.dart',
      ],
    );

    expect(
      summary.requiredSourceCoverage.keys,
      contains('lib/services/network/new_service.dart'),
    );
    expect(
      summary.requiredSourceCoverage.keys,
      isNot(contains('lib/features/other.dart')),
    );
  });

  test(
    'discovers only hand-written production sources under explicit roots',
    () {
      final directory = Directory.systemTemp.createTempSync('check-coverage-');
      addTearDown(() => directory.deleteSync(recursive: true));
      for (final path in const [
        'lib/new_service.dart',
        'lib/generated/schema.g.dart',
        'lib/generated/schema.dart',
        'lib/services/model.freezed.dart',
        'lib/services/model.generated.dart',
        'lib/third_party/vendor.dart',
        'test/new_service_test.dart',
        'tool/checker.dart',
        'android/src/platform.dart',
      ]) {
        final file = File('${directory.path}/$path');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('// source');
      }

      expect(
        discoverProductionSources(
          sourceRoots: const ['lib', 'android'],
          workingDirectory: directory.path,
        ),
        ['lib/new_service.dart'],
      );
    },
  );

  test('drops documented coverage exclusions while keeping ordinary sources', () {
    expect(
      filterHandWrittenProductionSources(const [
        'lib/services/telemetry/telemetry_database/tables/telemetry_policy_states.dart',
        'lib/services/telemetry/telemetry_database/tables/telemetry_records.dart',
        'lib/services/telemetry/telemetry_database/telemetry_database_connection.dart',
        'lib/services/telemetry/telemetry_database/telemetry_database_constants.dart',
        'lib/main.dart',
        'lib/services/telemetry/telemetry_database/telemetry_database_connection_web.dart',
        'lib/services/telemetry/telemetry_policy_controller.dart',
      ]),
      [
        'lib/services/telemetry/telemetry_database/telemetry_database_connection_web.dart',
        'lib/services/telemetry/telemetry_policy_controller.dart',
      ],
    );
  });

  test('discovers added sources relative to a Git base ref', () {
    final directory = Directory.systemTemp.createTempSync(
      'check-coverage-git-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    _runGit(directory, ['init', '-q']);
    _runGit(directory, ['config', 'user.email', 'coverage@example.invalid']);
    _runGit(directory, ['config', 'user.name', 'Coverage Test']);
    final existing = File('${directory.path}/lib/existing.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('// existing');
    _runGit(directory, ['add', existing.path]);
    _runGit(directory, ['commit', '-qm', 'base']);
    final added = File('${directory.path}/lib/new_service.dart')
      ..writeAsStringSync('// new');
    final generated = File('${directory.path}/lib/new_database.g.dart')
      ..writeAsStringSync('// generated');
    File(
      '${directory.path}/lib/untracked_service.dart',
    ).writeAsStringSync('// untracked');
    _runGit(directory, ['add', added.path, generated.path]);

    expect(
      discoverProductionSources(
        sourceRoots: const ['lib'],
        baseRef: 'HEAD',
        workingDirectory: directory.path,
      ),
      ['lib/new_service.dart', 'lib/untracked_service.dart'],
    );
  });

  test('reads manifests and filters owner source inventories', () {
    final directory = Directory.systemTemp.createTempSync(
      'check-coverage-manifest-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final manifest = File('${directory.path}/sources.txt')
      ..writeAsStringSync(
        '# inventory\n\n'
        'lib/services/network/a.dart\n'
        'lib/services/private.dart\n'
        'vendor/lib/services/network/vendor.dart\n'
        'lib/generated/schema.g.dart\n',
      );

    expect(readSourceManifest(manifest.path), [
      'lib/services/network/a.dart',
      'lib/services/private.dart',
      'vendor/lib/services/network/vendor.dart',
      'lib/generated/schema.g.dart',
    ]);
    expect(
      filterHandWrittenProductionSources(
        readSourceManifest(manifest.path),
        sourceRoots: const ['lib'],
        includePrefixes: const ['lib/services/network/'],
      ),
      [
        'lib/services/network/a.dart',
        'vendor/lib/services/network/vendor.dart',
      ],
    );
    expect(
      () => readSourceManifest('${directory.path}/missing.txt'),
      throwsStateError,
    );
    expect(
      () => discoverProductionSources(sourceRoots: const <String>[]),
      throwsArgumentError,
    );
    expect(
      () => discoverProductionSources(
        sourceRoots: const ['lib'],
        workingDirectory: directory.path,
      ),
      throwsStateError,
    );
    expect(
      () => discoverProductionSources(
        sourceRoots: const ['lib'],
        baseRef: '-HEAD',
      ),
      throwsArgumentError,
    );
  });

  test('resolves coverage base refs without CI environment influence', () {
    final directory = Directory.systemTemp.createTempSync(
      'check-coverage-refs-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    _runGit(directory, ['init', '-q']);
    _runGit(directory, ['config', 'user.email', 'coverage@example.invalid']);
    _runGit(directory, ['config', 'user.name', 'Coverage Test']);
    final first = File('${directory.path}/lib/first.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('// first');
    _runGit(directory, ['add', first.path]);
    _runGit(directory, ['commit', '-qm', 'first']);
    final second = File('${directory.path}/lib/second.dart')
      ..writeAsStringSync('// second');
    _runGit(directory, ['add', second.path]);
    _runGit(directory, ['commit', '-qm', 'second']);

    expect(
      resolveCoverageBaseRef(
        explicitBaseRef: 'HEAD',
        workingDirectory: directory.path,
      ),
      isNotEmpty,
    );
    expect(
      resolveCoverageBaseRef(
        explicitBaseRef: 'missing-force-push-base',
        workingDirectory: directory.path,
        environment: const {'GITHUB_EVENT_BEFORE': 'also-missing'},
      ),
      isNot('missing-force-push-base'),
    );
    expect(
      resolveCoverageBaseRef(
        explicitBaseRef: 'missing-force-push-base',
        workingDirectory: directory.path,
        environment: const {'CI_BASE_SHA': 'HEAD'},
      ),
      isNot('missing-force-push-base'),
    );
    expect(
      resolveCoverageBaseRef(
        explicitBaseRef: '0000000000000000',
        workingDirectory: directory.path,
        environment: const {},
      ),
      isNotEmpty,
    );

    final single = Directory.systemTemp.createTempSync(
      'check-coverage-single-',
    );
    addTearDown(() => single.deleteSync(recursive: true));
    _runGit(single, ['init', '-q']);
    _runGit(single, ['config', 'user.email', 'coverage@example.invalid']);
    _runGit(single, ['config', 'user.name', 'Coverage Test']);
    final only = File('${single.path}/lib/only.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('// only');
    _runGit(single, ['add', only.path]);
    _runGit(single, ['commit', '-qm', 'only']);

    expect(
      resolveCoverageBaseRef(
        explicitBaseRef: '0000000000000000',
        workingDirectory: single.path,
        environment: const {},
      ),
      isNull,
    );
  });
}

void _runGit(Directory directory, List<String> arguments) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: directory.path,
  );
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
}
