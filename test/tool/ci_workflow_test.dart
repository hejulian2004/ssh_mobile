import 'dart:io';

part 'ci_workflow_checks.dart';

/// 验证模块级 CI 合同，避免 Workspace、Melos 脚本和 GitHub Actions 漂移。
///
/// 这个测试只读取文本，不执行 CI 命令；它把 CI 的关键入口固定为可审计的
/// 字符串，避免为了检查 YAML 再引入一个与 Flutter 工作区冲突的解析依赖。
void main() {
  final root = _findRepositoryRoot();
  final pubspec = File('${root.path}/pubspec.yaml').readAsStringSync();
  final workflow = File(
    '${root.path}/.github/workflows/flutter.yml',
  ).readAsStringSync();
  final onlineWorkflow = File(
    '${root.path}/.github/workflows/online-e2e.yml',
  ).readAsStringSync();
  final rustToolchain = File(
    '${root.path}/native/network_core/rust-toolchain.toml',
  ).readAsStringSync();

  _testChangeScopePolicy(workflow);
  _testActionsArePinned(workflow, workflowName: 'flutter.yml');
  _testActionsArePinned(onlineWorkflow, workflowName: 'online-e2e.yml');
  _verifyScriptTrees(root);
  _verifyFullTestScripts(root);
  _testProtocolV2WorkflowChecker();

  _expect(pubspec.contains('\nmelos:\n'), '根 pubspec 必须声明 Melos 配置');
  _expect(pubspec.contains('    format:'), 'Melos 必须提供 format 脚本');
  _expect(pubspec.contains('    analyze:'), 'Melos 必须提供 analyze 脚本');
  _expect(pubspec.contains('    test:'), 'Melos 必须提供 test 脚本');
  _expect(
    !File('${root.path}/melos.yaml').existsSync(),
    'Melos 8 配置迁移到根 pubspec 后不得保留第二份配置源',
  );

  for (final marker in _requiredWorkflowMarkers) {
    _expect(workflow.contains(marker), 'CI 缺少必要入口：$marker');
  }

  _expect(workflow.contains("      - '**'"), 'CI 必须对所有分支 push 触发');
  _expect(
    !workflow.contains('pull_request:'),
    'CI 不应为同一提交重复注册 pull_request 流程',
  );
  _expect(
    !workflow.contains('package-quality:'),
    'CI 不应保留只服务于 pull_request 的 package-quality job',
  );
  _expect(
    !workflow.contains('needs: architecture-check'),
    '质量与构建 job 应与 architecture-check 并行执行',
  );
  _expect(
    !workflow.contains('workspace-quality:'),
    'CI 不应保留已拆分的 workspace-quality job',
  );
  _expect(
    !workflow.contains('analyze-and-test:'),
    'CI 不应保留已拆分的 analyze-and-test job',
  );
  _expect(
    rustToolchain.contains('channel = "1.97.1"'),
    'Rust toolchain pin 必须与 CI 的 RUST_TOOLCHAIN 对齐',
  );

  _verifyProtocolV2Workflow(workflow);

  final adminApiContract = _jobSection(workflow, 'admin-api-contract');
  _expect(
    adminApiContract.contains(
          'actions/setup-go@40f1582b2485089dde7abd97c1529aa768e1baff',
        ) &&
        adminApiContract.contains(
          'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020',
        ),
    'admin-api-contract 必须同时安装 Go 与 Node.js',
  );
  _expect(
    adminApiContract.contains('working-directory: front') &&
        adminApiContract.contains('run: npm ci'),
    'admin-api-contract 必须安装 Front dependencies',
  );
  _expect(
    adminApiContract.contains(
      'bash scripts/bash/contracts/admin_api_contract.sh',
    ),
    'admin-api-contract 必须运行真实 Go handler → Front schema 门禁',
  );

  final telemetryContract = _jobSection(workflow, 'telemetry-contract');
  _expect(
    telemetryContract.contains(
          'actions/setup-go@40f1582b2485089dde7abd97c1529aa768e1baff',
        ) &&
        telemetryContract.contains(
          'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020',
        ) &&
        telemetryContract.contains(
          'subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2',
        ),
    'telemetry-contract 必须同时安装 Go、Node.js 与 Flutter',
  );

  final frontQuality = _jobSection(workflow, 'front-quality');
  _expect(
    frontQuality.contains('npm audit --audit-level=high'),
    'front-quality 必须运行高危级别 Node 依赖漏洞门禁',
  );

  final nativeNetworkQuality = _jobSection(workflow, 'native-network-quality');
  _expect(
    nativeNetworkQuality.contains('cargo audit') &&
        !nativeNetworkQuality.contains('cargo audit --locked') &&
        nativeNetworkQuality.contains('cargo-audit --locked --version 0.22.2'),
    'native-network-quality 必须运行固定版本扫描器的 Rust 依赖漏洞门禁',
  );
  _expect(
    telemetryContract.contains(
      'bash scripts/bash/contracts/telemetry_contract.sh',
    ),
    'telemetry-contract 必须运行跨语言 Telemetry 数据契约门禁',
  );

  for (final jobName in const ['android-build', 'macos-build', 'ios-build']) {
    final job = _jobSection(workflow, jobName);
    _expect(
      job.contains('rustup show active-toolchain') &&
          job.contains('rustup target list --installed'),
      '$jobName 必须输出 Rust toolchain 与已安装 target 诊断',
    );
  }

  final workspaceCoreQuality = _jobSection(workflow, 'workspace-core-quality');
  for (final packageName in _corePackageNames) {
    _expect(
      workspaceCoreQuality.contains('--scope=$packageName'),
      'workspace-core-quality 缺少 Core 包：$packageName',
    );
  }
  _expect(
    !workspaceCoreQuality.contains('flutter build apk'),
    'workspace-core-quality 不应构建 Full App Android',
  );

  final workspaceFeaturesQuality = _jobSection(
    workflow,
    'workspace-features-quality',
  );
  for (final packageName in _featurePackageNames) {
    _expect(
      workspaceFeaturesQuality.contains('--scope=$packageName'),
      'workspace-features-quality 缺少 Feature 包：$packageName',
    );
  }
  _expect(
    !workspaceFeaturesQuality.contains('flutter build apk'),
    'workspace-features-quality 不应构建 Full App Android',
  );

  final sdkDartQuality = _jobSection(workflow, 'sdk-dart-quality');
  for (final packageName in _sdkPackageNames) {
    _expect(
      sdkDartQuality.contains('--scope=$packageName'),
      'sdk-dart-quality 缺少独立 SDK 包：$packageName',
    );
  }

  final lanNetworkV2Targeted = _jobSection(workflow, 'lan-network-v2-targeted');
  _expect(
    lanNetworkV2Targeted.contains(
      'bash scripts/bash/ci/full_test.sh --no-bootstrap --only lan-network-v2-targeted',
    ),
    'lan-network-v2-targeted 必须调用 full_test.sh --only lan-network-v2-targeted',
  );

  final architectureCheck = _jobSection(workflow, 'architecture-check');
  _expect(
    architectureCheck.contains('dart run tool/check_agent_docs.dart'),
    'architecture-check 必须运行 Agent 文档检查器',
  );
  _expect(
    architectureCheck.contains('dart run test/tool/agent_docs_check_test.dart'),
    'architecture-check 必须运行 Agent 文档检查器回归测试',
  );
  _expect(
    architectureCheck.contains('dart run test/tool/ci_workflow_test.dart'),
    'architecture-check 必须运行 CI workflow 合同回归测试',
  );
  _expect(
    architectureCheck.contains(
      'dart run tool/check_telemetry_contract_generated.dart',
    ),
    'architecture-check 必须运行 Telemetry 契约生成检查器',
  );
  _expect(
    architectureCheck.contains(
      'dart run test/tool/telemetry_contract_codegen_test.dart',
    ),
    'architecture-check 必须运行 Telemetry 契约代码生成回归测试',
  );
  _expect(
    architectureCheck.contains('dart run tool/check_module_dependencies.dart'),
    'architecture-check 必须运行模块依赖检查器',
  );
  _expect(
    architectureCheck.contains('dart run tool/check_resource_owners.dart'),
    'architecture-check 必须运行资源 Owner 检查器',
  );
  _expect(
    architectureCheck.contains('dart run tool/check_file_sizes.dart'),
    'architecture-check 必须运行文件尺寸、测试根与编号拆分检查器',
  );

  final appUnitTests = _jobSection(workflow, 'app-unit-tests');
  _expect(
    appUnitTests.contains('--coverage') &&
        appUnitTests.contains('--reporter compact') &&
        appUnitTests.contains('--concurrency 1'),
    'app-unit-tests 必须保留 coverage、compact reporter 与串行测试参数',
  );
  _expect(
    !appUnitTests.contains('Test native Dart package'),
    'Full App job 不应重复执行 Native Dart SDK 测试',
  );

  for (final jobName in const [
    'lan-network-v2-targeted',
    'terminal-smoke-build',
    'app-unit-tests',
    'android-build',
    'windows-build',
    'macos-build',
    'ios-build',
  ]) {
    final job = _jobSection(workflow, jobName);
    _expect(
      job.contains(
            'swatinem/rust-cache@49a0bdc70d2e1b713ca9e2869b211fcce03d3c1c',
          ) &&
          job.contains('workspaces: "native/network_core -> target"') &&
          job.contains(
            r'shared-key: "network-sdk-${{ runner.os }}-${{ runner.arch }}"',
          ),
      '$jobName 必须复用按平台架构隔离的 Rust target 缓存',
    );
  }

  final appCoverage = _jobSection(workflow, 'app-coverage');
  _expect(
    appCoverage.contains('dart run tool/check_coverage.dart'),
    'app-coverage 必须运行覆盖率门禁',
  );
  _expect(
    appCoverage.contains('--minimum=90') &&
        appCoverage.contains(
          r'--base-ref="${{ needs.change_scope.outputs.base_sha }}"',
        ) &&
        appCoverage.contains('--source-root=lib') &&
        !appCoverage.contains('--minimum=35') &&
        !appCoverage.contains('--all-sources'),
    'app-coverage 必须保留 90% 门禁并检查新增手写生产源文件',
  );
  _expect(
    appCoverage.contains('pattern: flutter-coverage-*') &&
        appCoverage.contains('Expected 4 shard coverage files') &&
        appCoverage.contains('Expected 2 isolated coverage files'),
    'app-coverage 必须合并四个测试分片和两个隔离覆盖率产物',
  );

  for (final jobName in _buildOnlyJobNames) {
    final job = _jobSection(workflow, jobName);
    _expect(
      !job.contains('flutter test'),
      '$jobName 只负责平台构建，不应运行完整 Flutter 测试',
    );
  }

  final expectedBuildCommands = <String>[
    'flutter build apk --debug --no-pub',
    r'pwsh .\scripts\powershell\ci\full_test.ps1',
    '-NoBootstrap -NoCoverage -Only windows-build',
    'flutter build macos',
    'flutter build ios --release --no-codesign --no-pub',
    'flutter build windows --debug --no-pub',
  ];
  for (final command in expectedBuildCommands) {
    _expect(workflow.contains(command), 'CI 缺少平台构建命令：$command');
  }

  final workspaceMembers = RegExp(
    r'^\s+- ((?:apps|packages)/[^\s]+)$',
    multiLine: true,
  ).allMatches(pubspec).map((match) => match.group(1)!).toList();
  _expect(workspaceMembers.length == 22, 'Workspace Member 数量发生漂移');
  for (final member in workspaceMembers) {
    _expect(
      Directory('${root.path}/$member').existsSync(),
      'Workspace 路径不存在：$member',
    );
  }

  stdout.writeln('CI workflow contract tests passed.');
}

void _testChangeScopePolicy(String workflow) {
  _expect(
    workflow.contains('EVENT_NAME: \${{ github.event_name }}'),
    'change_scope 必须读取 GitHub event name',
  );
  _expect(
    workflow.contains('EVENT_BEFORE_SHA: \${{ github.event.before }}'),
    'change_scope 必须使用 push event.before 作为比较基线',
  );
  _expect(
    workflow.contains('if [[ "\$EVENT_NAME" == "push" ]]') &&
        workflow.contains('base_sha="\$EVENT_BEFORE_SHA"'),
    'change_scope 必须在 push 事件选择 event.before',
  );
  _expect(
    workflow.contains('git rev-parse "\$CURRENT_SHA^"'),
    'change_scope 缺少无效/全零基线的 HEAD^ fallback',
  );

  // Exercise the event policy itself, rather than only checking YAML tokens.
  _expect(
    _comparisonBaseForScope(
          eventName: 'push',
          eventBefore: 'previous-push',
          pullRequestBase: 'pull-request-base',
        ) ==
        'previous-push',
    'push scope must use event.before',
  );
  _expect(
    _comparisonBaseForScope(
          eventName: 'pull_request',
          eventBefore: 'previous-push',
          pullRequestBase: 'pull-request-base',
        ) ==
        'pull-request-base',
    'pull request scope must use the PR base',
  );
  _expect(
    _comparisonBaseForScope(
          eventName: 'push',
          eventBefore: '0000000000000000000000000000000000000000',
          pullRequestBase: 'pull-request-base',
          headParent: 'head-parent',
        ) ==
        'head-parent',
    'zero push base must fall back to HEAD^',
  );
  _expect(
    _comparisonBaseForScope(
          eventName: 'push',
          eventBefore: '0000000000000000000000000000000000000000',
          pullRequestBase: '',
        ) ==
        null,
    'root push without a parent must use the root diff',
  );
}

void _testActionsArePinned(String workflow, {required String workflowName}) {
  final usesPattern = RegExp(
    r'^\s*(?:-\s+)?uses:\s+([^@\s]+)@([^\s#]+)',
    multiLine: true,
  );
  for (final match in usesPattern.allMatches(workflow)) {
    final action = match.group(1)!;
    final reference = match.group(2)!;
    _expect(
      RegExp(r'^[0-9a-f]{40}$', caseSensitive: false).hasMatch(reference),
      '$workflowName 的第三方 action 必须固定到完整 commit SHA：$action@$reference',
    );
  }
}

String? _comparisonBaseForScope({
  required String eventName,
  required String eventBefore,
  required String pullRequestBase,
  String? headParent,
}) {
  final candidate = eventName == 'push' ? eventBefore : pullRequestBase;
  if (candidate.isNotEmpty && !RegExp(r'^0+$').hasMatch(candidate)) {
    return candidate;
  }
  return headParent;
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}

const _requiredWorkflowMarkers = <String>[
  'change_scope:',
  'architecture-check:',
  'admin-api-contract:',
  'telemetry-contract:',
  'sdk-dart-quality:',
  'lan-network-v2-targeted:',
  'native-network-quality:',
  'relay-quality:',
  'protocol-v2-contract:',
  'front-quality:',
  'workspace-core-quality:',
  'workspace-features-quality:',
  'app-static-quality:',
  'app-unit-tests:',
  'app-isolated-tests:',
  'app-coverage:',
  'terminal-smoke-build:',
  'android-build:',
  'windows-build:',
  'macos-build:',
  'ios-build:',
  'flutter analyze --no-fatal-infos',
  'flutter test --no-pub',
  '--reporter compact',
  'dart run tool/architecture_check.dart',
  'dart run tool/check_agent_docs.dart',
  'dart run test/tool/agent_docs_check_test.dart',
  'dart run test/tool/ci_production_config_test.dart',
  'dart run tool/check_telemetry_contract_generated.dart',
  'dart run test/tool/telemetry_contract_codegen_test.dart',
  'dart run tool/check_module_dependencies.dart',
  'dart run tool/check_resource_owners.dart',
  'dart run tool/compatibility_check.dart',
  'dart run tool/duplicate_implementation_check.dart',
  'bash scripts/bash/contracts/telemetry_contract.sh',
  'dart run melos run analyze',
  'dart run melos run test',
  'flutter build apk --debug --no-pub',
  'flutter build windows --debug --no-pub',
  r'pwsh .\scripts\powershell\ci\full_test.ps1',
  '-NoBootstrap -NoCoverage -Only windows-build',
  'flutter build macos',
  'flutter build ios --release --no-codesign --no-pub',
  'apps/ssh_mobile_full',
  'apps/ssh_mobile_terminal',
];

const _corePackageNames = <String>[
  'app_core',
  'app_ui',
  'connection_core',
  'ssh_core',
];

const _featurePackageNames = <String>[
  'feature_ai',
  'feature_connection',
  'feature_developer',
  'feature_lan_share',
  'feature_mcp',
  'feature_monitoring',
  'feature_playbook',
  'feature_rag',
  'feature_sftp',
  'feature_system_admin',
  'feature_terminal',
  'feature_webview',
];

const _sdkPackageNames = <String>[
  'network_sdk',
  'network_transport',
  'realtime_media',
  'ssh_mobile_network_native',
];

const _buildOnlyJobNames = <String>[
  'android-build',
  'windows-build',
  'macos-build',
  'ios-build',
  'terminal-smoke-build',
];
