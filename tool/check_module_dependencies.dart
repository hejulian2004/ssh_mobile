import 'dart:io';

import 'architecture_check.dart';
import 'module_dependency_models.dart';

export 'module_dependency_models.dart';

/// Workspace modules each business package may depend on directly.
///
/// A feature may fan out to several modules on this adjacent layer. A
/// workspace dependency outside the set is a skip, even when the layer DAG
/// would still allow Feature → Infrastructure.
const businessDomainForwardDependencies = <String, Set<String>>{
  'feature_ai': <String>{
    'app_core',
    'app_ui',
    'connection_core',
    'feature_playbook',
    'ssh_core',
  },
  'feature_connection': <String>{'app_core', 'app_ui', 'connection_core'},
  'feature_developer': <String>{'app_core', 'app_ui'},
  'feature_lan_share': <String>{'app_core', 'app_ui', 'network_sdk'},
  'feature_mcp': <String>{'app_core', 'app_ui'},
  'feature_monitoring': <String>{'app_core', 'connection_core', 'ssh_core'},
  'feature_playbook': <String>{
    'app_core',
    'app_ui',
    'connection_core',
    'ssh_core',
  },
  'feature_rag': <String>{'app_core', 'app_ui'},
  'feature_screen_share': <String>{'app_ui', 'network_sdk'},
  'feature_sftp': <String>{'app_core', 'app_ui', 'ssh_core'},
  'feature_system_admin': <String>{
    'app_core',
    'app_ui',
    'connection_core',
    'ssh_core',
  },
  'feature_terminal': <String>{'app_core', 'app_ui', 'ssh_core'},
  'feature_webview': <String>{'app_core', 'app_ui'},
};

/// External packages that skip the adjacent SSH or native contract.
const forbiddenFeatureDependencies = <String>{
  'dartssh2',
  'ssh_mobile_network_native',
};

/// 审计 workspace 的直接生产依赖，不解析第三方依赖的传递闭包。
///
/// 生产依赖是 Package 边界真正声明的契约；Dart 源码中的 `/src/` 导入由
/// Step 28 的架构守卫负责检查。本审计只负责层级边界、Feature 例外和循环。
final class ModuleDependencyAuditor {
  ModuleDependencyAuditor({
    required this.repositoryRoot,
    this.allowlist = architectureAllowlist,
  });

  final Directory repositoryRoot;
  final ArchitectureAllowlist allowlist;

  /// 读取根 workspace 并返回稳定排序的审计结果。
  ModuleDependencyReport audit() {
    final packagePaths = _readWorkspacePaths();
    final packages = <WorkspacePackage>[];
    final violations = <ModuleDependencyViolation>[];

    for (final relativePath in packagePaths) {
      final directory = Directory(_join(repositoryRoot.path, relativePath));
      final pubspec = File(_join(directory.path, 'pubspec.yaml'));
      if (!pubspec.existsSync()) {
        violations.add(
          ModuleDependencyViolation(
            rule: 'workspace-package',
            source: relativePath,
            target: '',
            message: 'workspace 成员缺少 pubspec.yaml。',
          ),
        );
        continue;
      }

      final content = pubspec.readAsStringSync();
      final name = _readPackageName(content);
      if (name == null) {
        violations.add(
          ModuleDependencyViolation(
            rule: 'workspace-package',
            source: relativePath,
            target: '',
            message: 'pubspec.yaml 缺少有效的 name。',
          ),
        );
        continue;
      }
      packages.add(
        WorkspacePackage(
          name: name,
          relativePath: relativePath,
          layer: _layerFor(relativePath),
          productionDependencies: _readProductionDependencies(content),
        ),
      );
    }

    packages.sort((a, b) => a.name.compareTo(b.name));
    final byName = {for (final package in packages) package.name: package};
    final edges = <ModuleDependencyEdge>[];
    for (final source in packages) {
      final targets =
          source.productionDependencies
              .map((name) => byName[name])
              .whereType<WorkspacePackage>()
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      for (final target in targets) {
        edges.add(ModuleDependencyEdge(source: source, target: target));
        _checkLayerBoundary(source, target, violations);
      }
    }

    _checkBusinessForwardDependencies(packages, byName, violations);
    _checkCycles(packages, edges, violations);
    violations.sort((a, b) {
      final source = a.source.compareTo(b.source);
      if (source != 0) return source;
      final target = a.target.compareTo(b.target);
      if (target != 0) return target;
      return a.rule.compareTo(b.rule);
    });
    return ModuleDependencyReport(
      packages: packages,
      edges: edges,
      violations: violations,
    );
  }

  void _checkLayerBoundary(
    WorkspacePackage source,
    WorkspacePackage target,
    List<ModuleDependencyViolation> violations,
  ) {
    if (source.layer == ModuleLayer.feature &&
        target.layer == ModuleLayer.feature &&
        !allowlist.allowsFeatureDependency(source.name, target.name)) {
      violations.add(
        ModuleDependencyViolation(
          rule: 'feature-to-feature',
          source: source.name,
          target: target.name,
          message: 'Feature 之间必须通过公共 Contract/Capability，或登记显式例外。',
        ),
      );
    }
    if ((source.layer == ModuleLayer.core ||
            source.layer == ModuleLayer.infrastructure) &&
        target.layer == ModuleLayer.feature) {
      violations.add(
        ModuleDependencyViolation(
          rule: 'lower-layer-to-feature',
          source: source.name,
          target: target.name,
          message: 'Core/Infrastructure 不得反向依赖 Feature。',
        ),
      );
    }
  }

  void _checkBusinessForwardDependencies(
    List<WorkspacePackage> packages,
    Map<String, WorkspacePackage> byName,
    List<ModuleDependencyViolation> violations,
  ) {
    for (final source in packages) {
      if (source.layer != ModuleLayer.feature) continue;
      final allowed = businessDomainForwardDependencies[source.name];
      if (allowed == null) {
        violations.add(
          ModuleDependencyViolation(
            rule: 'business-forward-dependency',
            source: source.name,
            target: '',
            message: '业务领域缺少前向依赖登记。',
          ),
        );
      }
      for (final dependency in source.productionDependencies) {
        final skipsWorkspaceLayer =
            byName.containsKey(dependency) &&
            (allowed == null || !allowed.contains(dependency));
        final skipsExternalContract = forbiddenFeatureDependencies.contains(
          dependency,
        );
        if (!skipsWorkspaceLayer && !skipsExternalContract) continue;
        violations.add(
          ModuleDependencyViolation(
            rule: 'business-forward-dependency',
            source: source.name,
            target: dependency,
            message: '业务领域只能前向依赖已登记的相邻模块。',
          ),
        );
      }
    }
  }

  void _checkCycles(
    List<WorkspacePackage> packages,
    List<ModuleDependencyEdge> edges,
    List<ModuleDependencyViolation> violations,
  ) {
    final adjacency = <String, List<String>>{
      for (final package in packages) package.name: <String>[],
    };
    for (final edge in edges) {
      adjacency[edge.source.name]!.add(edge.target.name);
    }
    for (final targets in adjacency.values) {
      targets.sort();
    }

    final state = <String, int>{};
    final stack = <String>[];
    final reported = <String>{};

    void visit(String name) {
      state[name] = 1;
      stack.add(name);
      for (final target in adjacency[name]!) {
        if (state[target] == 1) {
          final cycle = stack.sublist(stack.indexOf(target));
          final key = [...cycle]..sort();
          if (reported.add(key.join('|'))) {
            violations.add(
              ModuleDependencyViolation(
                rule: 'dependency-cycle',
                source: cycle.first,
                target: target,
                message: '检测到循环依赖：${[...cycle, target].join(' -> ')}。',
              ),
            );
          }
        } else if (state[target] != 2) {
          visit(target);
        }
      }
      stack.removeLast();
      state[name] = 2;
    }

    for (final package in packages) {
      if (state[package.name] == null) visit(package.name);
    }
  }

  List<String> _readWorkspacePaths() {
    final pubspec = File(_join(repositoryRoot.path, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      throw StateError('根 workspace 缺少 pubspec.yaml：${repositoryRoot.path}');
    }
    final paths = <String>[];
    var inWorkspace = false;
    for (final line in pubspec.readAsLinesSync()) {
      if (line.trim() == 'workspace:') {
        inWorkspace = true;
        continue;
      }
      if (inWorkspace && line.isNotEmpty && !line.startsWith(' ')) break;
      if (!inWorkspace) continue;
      final match = RegExp(r'^\s+-\s+([^\s#]+)').firstMatch(line);
      if (match != null) paths.add(match.group(1)!);
    }
    if (paths.isEmpty) throw StateError('根 pubspec.yaml 没有 workspace 成员。');
    return paths;
  }
}

String? _readPackageName(String content) => RegExp(
  r'^name:\s*([A-Za-z0-9_-]+)\s*(?:#.*)?$',
  multiLine: true,
).firstMatch(content)?.group(1);

Set<String> _readProductionDependencies(String content) {
  final dependencies = <String>{};
  var inDependencies = false;
  for (final line in content.split('\n')) {
    if (line.trim() == 'dependencies:') {
      inDependencies = true;
      continue;
    }
    if (inDependencies && line.isNotEmpty && !line.startsWith(' ')) break;
    if (!inDependencies) continue;
    final match = RegExp(r'^  ([A-Za-z0-9_-]+):').firstMatch(line);
    if (match != null) dependencies.add(match.group(1)!);
  }
  return dependencies;
}

ModuleLayer _layerFor(String relativePath) {
  if (relativePath.startsWith('apps/')) return ModuleLayer.app;
  if (relativePath.startsWith('packages/core/')) return ModuleLayer.core;
  if (relativePath.startsWith('packages/features/')) return ModuleLayer.feature;
  if (relativePath.startsWith('packages/infrastructure/')) {
    return ModuleLayer.infrastructure;
  }
  return ModuleLayer.unknown;
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';

void main() {
  final report = ModuleDependencyAuditor(
    repositoryRoot: Directory.current,
  ).audit();
  stdout.writeln(
    'Module dependency audit: ${report.packages.length} packages, '
    '${report.internalDependencyCount} internal production dependencies.',
  );
  final workspaceNames = report.packages.map((package) => package.name).toSet();
  for (final package in report.packages) {
    final dependencies =
        package.productionDependencies.where(workspaceNames.contains).toList()
          ..sort();
    stdout.writeln(
      '  ${package.name} [${package.layer.label}]'
      '${dependencies.isEmpty ? '' : ' -> ${dependencies.join(', ')}'}',
    );
  }
  if (report.isValid) {
    stdout.writeln('Module dependency audit passed.');
    return;
  }
  stderr.writeln(
    'Module dependency audit failed with '
    '${report.violations.length} violation(s):',
  );
  for (final violation in report.violations) {
    stderr.writeln('  $violation');
  }
  exitCode = 1;
}
