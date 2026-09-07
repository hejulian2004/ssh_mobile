import 'dart:io';

import '../../tool/check_module_dependencies.dart';

/// 模块依赖审计的无外部依赖回归测试，直接验证 workspace 清单和违规规则。
void main() {
  _testCurrentRepositoryPasses();
  _testForbiddenDependenciesAndCyclesAreReported();
  stdout.writeln('Module dependency checker tests passed.');
}

void _testCurrentRepositoryPasses() {
  final report = ModuleDependencyAuditor(
    repositoryRoot: Directory.current,
  ).audit();
  _expect(report.isValid, '当前 workspace 不应有依赖违规：${report.violations}');
  _expect(report.packages.length == 22, '应审计根 workspace 的 22 个成员。');
  _expect(
    report.edges.any(
      (edge) =>
          edge.source.name == 'feature_ai' &&
          edge.target.name == 'feature_playbook',
    ),
    '应保留 AI 到 Playbook 公共能力边界的显式依赖。',
  );
}

void _testForbiddenDependenciesAndCyclesAreReported() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_dependencies_');
  try {
    _writeRootPubspec(root, <String>[
      'packages/features/feature_a',
      'packages/features/feature_b',
      'packages/infrastructure/transport',
    ]);
    _writePackage(root, 'packages/features/feature_a', 'feature_a', <String>[
      'feature_b',
    ]);
    _writePackage(root, 'packages/features/feature_b', 'feature_b', <String>[
      'feature_a',
    ]);
    _writePackage(
      root,
      'packages/infrastructure/transport',
      'transport',
      <String>['feature_a'],
    );

    final report = ModuleDependencyAuditor(repositoryRoot: root).audit();
    final rules = report.violations.map((item) => item.rule).toSet();
    _expect(rules.contains('feature-to-feature'), '应检查 Feature 之间的依赖。');
    _expect(
      rules.contains('lower-layer-to-feature'),
      '应检查 Infrastructure 反向依赖 Feature。',
    );
    _expect(rules.contains('dependency-cycle'), '应检查依赖循环。');
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _writeRootPubspec(Directory root, List<String> paths) {
  _write(
    root,
    'pubspec.yaml',
    'name: _\nworkspace:\n${paths.map((path) => '  - $path').join('\n')}\n',
  );
}

void _writePackage(
  Directory root,
  String relativePath,
  String name,
  List<String> dependencies,
) {
  final dependencyText = dependencies.isEmpty
      ? ''
      : 'dependencies:\n${dependencies.map((item) => '  $item: any').join('\n')}\n';
  _write(root, '$relativePath/pubspec.yaml', 'name: $name\n$dependencyText');
}

void _write(Directory root, String relativePath, String content) {
  final file = File(
    '${root.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
