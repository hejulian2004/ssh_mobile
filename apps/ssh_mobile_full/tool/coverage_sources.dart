import 'dart:io';

/// Reads a newline-delimited source manifest. Empty lines and comments are
/// ignored so CI can retain a small, auditable manifest-generation step.
List<String> readSourceManifest(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('Source manifest not found: $path');
  }
  return file
      .readAsLinesSync()
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('#'))
      .toList(growable: false);
}

/// Finds added or changed production sources in [sourceRoots]. When [baseRef] is
/// null, the explicit roots are treated as the expected source set; this is
/// useful for local dry-runs where no CI base ref is available.
List<String> discoverProductionSources({
  required Iterable<String> sourceRoots,
  String? baseRef,
  Iterable<String> includePrefixes = const <String>[],
  String? workingDirectory,
}) {
  final roots = sourceRoots
      .map(_normalizeSourcePath)
      .map((root) => root.replaceFirst(RegExp(r'/+$'), ''))
      .where((root) => root.isNotEmpty)
      .toList(growable: false);
  if (roots.isEmpty) {
    throw ArgumentError.value(sourceRoots, 'sourceRoots', 'must not be empty');
  }

  final discovered = baseRef == null
      ? _scanSourceRoots(roots, workingDirectory: workingDirectory)
      : _gitAddedSourcePaths(
          roots,
          baseRef,
          workingDirectory: workingDirectory,
        );
  return filterHandWrittenProductionSources(
    discovered,
    sourceRoots: roots,
    includePrefixes: includePrefixes,
  );
}

/// Returns the best local/CI comparison ref without making a missing remote a
/// reason to skip source enforcement. CI passes its event base explicitly;
/// local runs prefer origin/main and then the immediate parent.
String? resolveCoverageBaseRef({
  String? explicitBaseRef,
  String? workingDirectory,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  for (final candidate in <String?>[
    explicitBaseRef,
    env['COVERAGE_BASE_REF'],
    env['CI_BASE_REF'],
    env['CI_BASE_SHA'],
    env['GITHUB_BASE_SHA'],
    env['GITHUB_EVENT_BEFORE'],
    env['GITHUB_BASE_REF'],
  ]) {
    final resolved = _resolveGitCommit(
      candidate,
      workingDirectory: workingDirectory,
    );
    if (resolved != null) return resolved;
  }
  for (final candidate in const ['origin/main', 'HEAD^']) {
    final resolved = _resolveGitCommit(
      candidate,
      workingDirectory: workingDirectory,
    );
    if (resolved != null) return resolved;
  }
  return null;
}

String? _resolveGitCommit(String? candidate, {String? workingDirectory}) {
  if (candidate == null ||
      candidate.isEmpty ||
      _isZeroSha(candidate) ||
      candidate.startsWith('-')) {
    return null;
  }
  final result = Process.runSync('git', [
    'rev-parse',
    '--verify',
    '$candidate^{commit}',
  ], workingDirectory: workingDirectory);
  if (result.exitCode != 0) return null;
  final resolved = result.stdout.toString().trim();
  if (resolved.isEmpty) return null;
  return resolved;
}

/// Single-file exclusions whose reasons are recorded in
/// docs/COVERAGE_POLICY.md. Only paths listed there may be dropped from the
/// required new-source set; each entry must document why the owner validation
/// report treats the file as lacking coverable business logic.
///
/// The set contains only paths whose reasons are recorded in
/// docs/COVERAGE_POLICY.md: declarative Drift schema input, conditional
/// exports/constants, and the two-line App entrypoint that delegates to the
/// independently tested bootstrap contract.
const _documentedCoverageExclusions = <String>{
  'lib/services/telemetry/telemetry_database/tables/telemetry_policy_states.dart',
  'lib/services/telemetry/telemetry_database/tables/telemetry_records.dart',
  'lib/services/telemetry/telemetry_database/telemetry_database_connection.dart',
  'lib/services/telemetry/telemetry_database/telemetry_database_constants.dart',
  'lib/services/app_log_database/tables/app_log_tables.dart',
  'lib/services/sftp/sftp_service_stub.dart',
  'lib/widgets/server_selector.dart',
  'lib/main.dart',
};

/// Filters a source inventory to hand-written production files. The explicit
/// source-root/include filters keep ownership with the caller while this
/// shared filter removes generated, test, tool, third-party, and platform
/// boilerplate paths documented by the coverage policy.
List<String> filterHandWrittenProductionSources(
  Iterable<String> paths, {
  Iterable<String> sourceRoots = const <String>[],
  Iterable<String> includePrefixes = const <String>[],
}) {
  final roots = sourceRoots
      .map(_normalizeSourcePath)
      .map((root) => root.replaceFirst(RegExp(r'/+$'), ''))
      .where((root) => root.isNotEmpty)
      .toList(growable: false);
  final prefixes = includePrefixes
      .map(_normalizeSourcePath)
      .where((prefix) => prefix.isNotEmpty)
      .toList(growable: false);
  final result = <String>{};
  for (final path in paths) {
    final source = _normalizeSourcePath(path.trim());
    if (source.isEmpty || !_isHandWrittenProductionSource(source)) continue;
    // Both manifest and git-discovered inventories pass through this filter;
    // paths whose exclusion is recorded in the coverage policy must not
    // become missing required sources.
    if (_documentedCoverageExclusions.any(
      (excluded) => _coveragePathMatches(source, excluded),
    )) {
      continue;
    }
    if (roots.isNotEmpty &&
        !roots.any((root) => _pathMatchesRoot(source, root))) {
      continue;
    }
    if (prefixes.isNotEmpty &&
        !prefixes.any((prefix) => _coveragePathMatches(source, prefix))) {
      continue;
    }
    result.add(source);
  }
  return result.toList()..sort();
}

List<String> _scanSourceRoots(
  Iterable<String> roots, {
  String? workingDirectory,
}) {
  final directory = Directory(workingDirectory ?? Directory.current.path);
  final basePath = _normalizeSourcePath(directory.absolute.path);
  final paths = <String>[];
  for (final root in roots) {
    final rootDirectory = Directory('${directory.path}/$root');
    if (!rootDirectory.existsSync()) {
      throw StateError('Source root not found: ${rootDirectory.path}');
    }
    for (final entity in rootDirectory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (!FileSystemEntity.isFileSync(entity.path)) continue;
      final absolute = _normalizeSourcePath(entity.absolute.path);
      final relative = absolute.startsWith('$basePath/')
          ? absolute.substring(basePath.length + 1)
          : absolute;
      paths.add(relative);
    }
  }
  return paths;
}

List<String> _gitAddedSourcePaths(
  Iterable<String> roots,
  String baseRef, {
  String? workingDirectory,
}) {
  if (baseRef.startsWith('-')) {
    throw ArgumentError.value(baseRef, 'baseRef', 'must be a Git ref');
  }
  final result = Process.runSync('git', [
    'diff',
    '--name-only',
    '--relative',
    '-z',
    '--diff-filter=ACMR',
    '--no-renames',
    baseRef,
    '--',
    ...roots,
  ], workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    throw StateError(
      'git diff against $baseRef failed: ${result.stderr.toString().trim()}',
    );
  }
  final untrackedResult = Process.runSync('git', [
    'ls-files',
    '--others',
    '--exclude-standard',
    '-z',
    '--',
    ...roots,
  ], workingDirectory: workingDirectory);
  if (untrackedResult.exitCode != 0) {
    throw StateError(
      'git ls-files for required coverage sources failed: '
      '${untrackedResult.stderr.toString().trim()}',
    );
  }
  return [
    ..._splitGitPaths(result.stdout),
    ..._splitGitPaths(untrackedResult.stdout),
  ];
}

List<String> _splitGitPaths(Object output) {
  return output
      .toString()
      .split('\u0000')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
}

bool _isZeroSha(String value) => RegExp(r'^0{7,40}$').hasMatch(value);

bool _isHandWrittenProductionSource(String source) {
  final normalized = _normalizeSourcePath(source);
  final fileName = normalized.split('/').last;
  if (!fileName.endsWith('.dart')) return false;
  final segments = normalized.split('/');
  if (segments.any(
    (segment) =>
        segment == 'test' ||
        segment == 'tests' ||
        segment == 'tool' ||
        segment == 'third_party' ||
        segment == 'generated',
  )) {
    return false;
  }
  final libIndex = segments.lastIndexOf('lib');
  final platformRoots = const {
    'android',
    'ios',
    'linux',
    'macos',
    'web',
    'windows',
  };
  if (segments.asMap().entries.any(
    (entry) =>
        platformRoots.contains(entry.value) &&
        (libIndex < 0 || entry.key == libIndex + 1),
  )) {
    return false;
  }
  return !fileName.endsWith('.g.dart') &&
      !fileName.endsWith('.freezed.dart') &&
      !fileName.endsWith('.mocks.dart') &&
      !fileName.endsWith('.gen.dart') &&
      !fileName.endsWith('.generated.dart');
}

bool _pathMatchesRoot(String source, String root) {
  return source == root ||
      source.startsWith('$root/') ||
      source.endsWith('/$root') ||
      source.contains('/$root/');
}

String _normalizeSourcePath(String path) {
  return path.replaceAll('\\', '/').replaceFirst(RegExp(r'^\./'), '');
}

bool _coveragePathMatches(String source, String prefix) {
  final normalizedSource = _normalizeSourcePath(source);
  final normalizedPrefix = prefix.replaceFirst(RegExp(r'/+$'), '');
  return normalizedSource == normalizedPrefix ||
      normalizedSource.startsWith('$normalizedPrefix/') ||
      normalizedSource.contains('/$normalizedPrefix/');
}
