import 'dart:io';

import 'package:yaml/yaml.dart';

/// Guards the CI/production boundaries that are easy to regress when the
/// aggregate scripts or Docker contexts are edited.
void main() {
  final root = _findRepositoryRoot();
  final compose = File('${root.path}/compose.yaml').readAsStringSync();
  final dockerfile = File('${root.path}/front/Dockerfile').readAsStringSync();
  final tsconfig = File(
    '${root.path}/front/tsconfig.app.json',
  ).readAsStringSync();
  final testTsconfig = File('${root.path}/front/tsconfig.tests.json');
  final packageJson = File(
    '${root.path}/front/package.json',
  ).readAsStringSync();
  final workflow = File(
    '${root.path}/.github/workflows/flutter.yml',
  ).readAsStringSync();
  final frontViteConfig = File(
    '${root.path}/front/vite.config.ts',
  ).readAsStringSync();
  final coverageScripts = <String, String>{
    'bash client coverage': File(
      '${root.path}/scripts/bash/coverage/client_coverage.sh',
    ).readAsStringSync(),
    'bash SDK coverage': File(
      '${root.path}/scripts/bash/coverage/sdk_coverage.sh',
    ).readAsStringSync(),
    'bash backend coverage': File(
      '${root.path}/scripts/bash/coverage/backend_coverage.sh',
    ).readAsStringSync(),
    'PowerShell client coverage': File(
      '${root.path}/scripts/powershell/coverage/client_coverage.ps1',
    ).readAsStringSync(),
    'PowerShell SDK coverage': File(
      '${root.path}/scripts/powershell/coverage/sdk_coverage.ps1',
    ).readAsStringSync(),
    'PowerShell backend coverage': File(
      '${root.path}/scripts/powershell/coverage/backend_coverage.ps1',
    ).readAsStringSync(),
  };
  final coverageAlias = File(
    '${root.path}/scripts/bash/coverage/coverage_test.sh',
  ).readAsStringSync();
  final coverageAliasPowerShell = File(
    '${root.path}/scripts/powershell/coverage/coverage_test.ps1',
  ).readAsStringSync();
  final backendCoverage = File(
    '${root.path}/scripts/bash/coverage/backend_coverage.sh',
  ).readAsStringSync();
  final backendCoveragePowerShell = File(
    '${root.path}/scripts/powershell/coverage/backend_coverage.ps1',
  ).readAsStringSync();
  final bashApp = File(
    '${root.path}/scripts/bash/ci/full_test_app.sh',
  ).readAsStringSync();
  final powerShellApp = File(
    '${root.path}/scripts/powershell/ci/full_test_app.ps1',
  ).readAsStringSync();
  final bashE2e = File(
    '${root.path}/scripts/bash/e2e/client_backend_e2e.sh',
  ).readAsStringSync();
  final bashTelemetryE2e = File(
    '${root.path}/scripts/bash/e2e/client_backend_telemetry.sh',
  ).readAsStringSync();
  final rustTelemetryE2e = File(
    '${root.path}/native/network_core/crates/network-relay/tests/telemetry_e2e.rs',
  ).readAsStringSync();
  final powerShellE2e = File(
    '${root.path}/scripts/powershell/e2e/client_backend_e2e.ps1',
  ).readAsStringSync();
  final powerShellTelemetryE2e = File(
    '${root.path}/scripts/powershell/e2e/client_backend_telemetry.ps1',
  ).readAsStringSync();
  final powerShellRunner = File(
    '${root.path}/scripts/powershell/ci/full_test_runner.ps1',
  ).readAsStringSync();

  for (final variable in const [
    'TELEMETRY_MYSQL_DSN',
    'TELEMETRY_REDIS_URL',
    'TELEMETRY_AUTH_SECRET',
    'ANALYTICS_MYSQL_PASSWORD',
    'ANALYTICS_MYSQL_ROOT_PASSWORD',
    'ANALYTICS_REDIS_PASSWORD',
  ]) {
    _expect(
      compose.contains('\${$variable:?'),
      'Compose must require $variable instead of supplying a default.',
    );
  }
  for (final forbidden in const [
    'telemetry_secret_pass',
    'telemetry_root_pass',
    'analytics_redis_secret_pass',
  ]) {
    _expect(
      !compose.contains(forbidden),
      'Compose contains a predictable analytics secret: $forbidden',
    );
  }
  for (final service in const ['analytics-mysql', 'analytics-redis']) {
    _expect(
      compose.contains('$service:') && compose.contains('service_healthy'),
      'Analytics service $service must expose a healthy readiness condition.',
    );
    _expect(
      compose.contains('$service:') && compose.contains('healthcheck:'),
      'Analytics service $service must define a readiness healthcheck.',
    );
  }
  _expect(
    compose.contains(
      'analytics-mysql:\n        condition: service_healthy\n        required: true',
    ),
    'Admin Compose startup must require healthy Analytics MySQL.',
  );
  final adminDependsOn = compose.substring(
    compose.indexOf('  admin-api:'),
    compose.indexOf('    expose:', compose.indexOf('  admin-api:')),
  );
  _expect(
    !adminDependsOn.contains('analytics-redis:'),
    'Analytics Redis must not block admin-api startup when unavailable.',
  );
  _expect(
    compose.contains('analytics_state:') &&
        compose.contains('analytics_mysql_data:') &&
        compose.contains('analytics_redis_data:') &&
        compose.contains('--maxmemory 64mb') &&
        compose.contains('--maxmemory-policy noeviction') &&
        compose.contains('--requirepass'),
    'Analytics Redis must retain its health, resource, persistence, and auth boundaries.',
  );

  _expect(
    compose.contains('RELAY_STORAGE_MODE: \${RELAY_STORAGE_MODE:-mysql}'),
    'Compose must default Relay to durable MySQL storage.',
  );
  for (final variable in const [
    'RELAY_DATABASE_URL',
    'RELAY_REDIS_URL',
    'RELAY_REDIS_PASSWORD',
    'MYSQL_ROOT_PASSWORD',
    'MYSQL_PASSWORD',
  ]) {
    _expect(
      compose.contains('\${$variable:?'),
      'Compose must require Relay storage variable $variable.',
    );
  }
  final relayDependsOn = compose.substring(
    compose.indexOf('  relay:'),
    compose.indexOf('    networks:', compose.indexOf('  relay:')),
  );
  _expect(
    relayDependsOn.contains(
          'mysql:\n        condition: service_healthy\n        required: true',
        ) &&
        relayDependsOn.contains(
          'redis:\n        condition: service_healthy\n        required: true',
        ),
    'Relay must wait for healthy MySQL and Redis services.',
  );
  final relayMysql = compose.substring(
    compose.indexOf('  mysql:\n    image:'),
    compose.indexOf(
      '  redis:\n    image:',
      compose.indexOf('  mysql:\n    image:'),
    ),
  );
  final relayRedis = compose.substring(
    compose.indexOf('  redis:\n    image:'),
    compose.indexOf('  front:', compose.indexOf('  redis:\n    image:')),
  );
  _expect(
    !relayMysql.contains('profiles:') &&
        !relayRedis.contains('profiles:') &&
        relayMysql.contains('healthcheck:') &&
        relayRedis.contains('healthcheck:') &&
        relayRedis.contains('--requirepass'),
    'Relay MySQL and Redis must be always-on, healthy, and password protected.',
  );

  for (final example in [
    File('${root.path}/.env.example'),
    File('${root.path}/relay/.env.example'),
  ]) {
    final text = example.readAsStringSync();
    for (final variable in const [
      'TELEMETRY_MYSQL_DSN',
      'TELEMETRY_REDIS_URL',
      'TELEMETRY_AUTH_SECRET',
      'ANALYTICS_MYSQL_PASSWORD',
      'ANALYTICS_MYSQL_ROOT_PASSWORD',
      'ANALYTICS_REDIS_PASSWORD',
    ]) {
      _expect(
        text.contains('$variable='),
        '${example.path} must document $variable.',
      );
    }
    _expect(
      text.contains('RELAY_STORAGE_MODE=mysql'),
      '${example.path} must default Relay to mysql storage.',
    );
    for (final variable in const [
      'RELAY_DATABASE_URL',
      'RELAY_REDIS_URL',
      'RELAY_REDIS_PASSWORD',
      'MYSQL_ROOT_PASSWORD',
      'MYSQL_PASSWORD',
    ]) {
      _expect(
        text.contains('$variable='),
        '${example.path} must document Relay storage variable $variable.',
      );
    }
    _expect(
      !text.contains('telemetry_secret_pass') &&
          !text.contains('analytics_redis_secret_pass'),
      '${example.path} must not contain a real or predictable secret.',
    );
  }

  _expect(
    dockerfile.contains('src/generated/telemetry_contract.ts'),
    'Front Docker must verify the committed generated telemetry catalog.',
  );
  _expect(
    !dockerfile.contains('COPY ../') && !dockerfile.contains('COPY contracts/'),
    'Front Docker must not reach outside its self-contained build context.',
  );
  _expect(
    !dockerfile.contains('policy.schema.json') &&
        !dockerfile.contains('contracts/telemetry'),
    'Front Docker must not consume the repository telemetry JSON contract.',
  );
  _expect(
    !tsconfig.contains('"tests"'),
    'The production Front TypeScript project must not compile root-contract tests.',
  );
  _expect(
    testTsconfig.existsSync(),
    'Front tests need a dedicated TypeScript project.',
  );
  _expect(
    testTsconfig.readAsStringSync().contains('"tests"'),
    'The Front test TypeScript project must include front/tests.',
  );
  _expect(
    packageJson.contains('"typecheck:tests"'),
    'Front package scripts must expose the test TypeScript gate.',
  );
  _expect(
    workflow.contains('npm run typecheck:tests'),
    'front-quality must run the Front test TypeScript gate.',
  );

  _expect(
    frontViteConfig.contains('lines: 90') &&
        frontViteConfig.contains('functions: 90') &&
        frontViteConfig.contains('branches: 90') &&
        frontViteConfig.contains('statements: 90'),
    'Front coverage must enforce 90% for every Vitest metric.',
  );
  _expect(
    coverageScripts['bash client coverage']!.contains(
      'MINIMUM="\${CLIENT_COVERAGE_MINIMUM:-90}"',
    ),
    'Bash client coverage must default to 90%.',
  );
  _expect(
    coverageScripts['bash SDK coverage']!.contains(
      'MINIMUM="\${SDK_COVERAGE_MINIMUM:-90}"',
    ),
    'Bash SDK coverage must default to 90%.',
  );
  _expect(
    coverageScripts['bash backend coverage']!.contains(
      'MINIMUM="\${BACKEND_COVERAGE_MINIMUM:-90}"',
    ),
    'Bash backend coverage must default to 90%.',
  );
  _expect(
    coverageScripts['PowerShell client coverage']!.contains(
      "if (-not \$Minimum) { \$Minimum = '90' }",
    ),
    'PowerShell client coverage must default to 90%.',
  );
  _expect(
    coverageScripts['PowerShell SDK coverage']!.contains(
      "if(-not \$Minimum){\$Minimum='90'}",
    ),
    'PowerShell SDK coverage must default to 90%.',
  );
  _expect(
    coverageScripts['PowerShell backend coverage']!.contains(
      "if (-not \$Minimum) { \$Minimum = '90' }",
    ),
    'PowerShell backend coverage must default to 90%.',
  );
  _expect(
    coverageScripts['bash SDK coverage']!.contains(
          'SDK coverage gate passed at Dart %s%% and Rust %s%% (minimum %s%%).',
        ) &&
        coverageScripts['PowerShell SDK coverage']!.contains(
          'SDK coverage passed: Dart {0:N2}%, Rust {1:N2}% (minimum {2}%).',
        ),
    'Bash and PowerShell SDK coverage must report the active 90% threshold.',
  );
  _expect(
    coverageScripts['bash backend coverage']!.contains(
          'Backend coverage threshold: %s%%',
        ) &&
        coverageScripts['PowerShell backend coverage']!.contains(
          'Backend coverage threshold: \$Minimum%',
        ) &&
        coverageScripts['PowerShell backend coverage']!.contains(
          'Telemetry coverage threshold: \$telemetryMinimum%',
        ),
    'Bash and PowerShell backend coverage must report both active thresholds.',
  );
  _expect(
    coverageScripts['bash client coverage']!.contains(
          '--source-root=lib/services/network/',
        ) &&
        coverageScripts['PowerShell client coverage']!.contains(
          "'--source-root=lib/services/network/'",
        ) &&
        coverageScripts['bash client coverage']!.contains(
          'CLIENT_COVERAGE_BASE_REF',
        ) &&
        coverageScripts['PowerShell client coverage']!.contains(
          'CLIENT_COVERAGE_BASE_REF',
        ),
    'Bash and PowerShell client coverage must discover new sources in the owned Network scope.',
  );
  _expect(
    coverageAlias.contains('client_coverage.sh'),
    'Bash coverage_test.sh must remain the client-gate compatibility alias.',
  );
  _expect(
    coverageAliasPowerShell.contains('client_coverage.ps1'),
    'PowerShell coverage_test.ps1 must remain the client-gate compatibility alias.',
  );
  final workflowJobs = (loadYaml(workflow) as YamlMap)['jobs'] as YamlMap;
  final fullAppCoverage = workflowJobs['app-coverage'].toString();
  _expect(
    fullAppCoverage.contains('--minimum=90') &&
        fullAppCoverage.contains(
          r'--base-ref="${{ needs.change_scope.outputs.base_sha }}"',
        ) &&
        fullAppCoverage.contains('--source-root=lib') &&
        !fullAppCoverage.contains('--minimum=35') &&
        !fullAppCoverage.contains('--all-sources'),
    'CI Full App coverage must retain the 90% gate for new hand-written source files.',
  );
  final bashAppCoverage = File(
    '${root.path}/scripts/bash/ci/full_test_app.sh',
  ).readAsStringSync();
  final powerShellAppCoverage = File(
    '${root.path}/scripts/powershell/ci/full_test_app.ps1',
  ).readAsStringSync();
  _expect(
    bashAppCoverage.contains('tool/check_coverage.dart') &&
        bashAppCoverage.contains('--minimum=90') &&
        powerShellAppCoverage.contains(
          "'tool/check_coverage.dart','--minimum=90'",
        ) &&
        powerShellAppCoverage.contains(
          'Enforce Full App coverage (90% minimum)',
        ) &&
        !bashAppCoverage.contains('--minimum=35') &&
        !powerShellAppCoverage.contains('--minimum=35'),
    'Bash and PowerShell Full App coverage helpers must enforce 90%.',
  );
  _expect(
    bashAppCoverage.contains('--source-root=lib') &&
        powerShellAppCoverage.contains("'--source-root=lib'") &&
        bashAppCoverage.contains('FULL_TEST_COVERAGE_BASE_REF') &&
        powerShellAppCoverage.contains('FULL_TEST_COVERAGE_BASE_REF'),
    'Bash and PowerShell Full App coverage must enforce the new-source inventory.',
  );
  for (final marker in const [
    'analytics-mysql:',
    'analytics-redis:',
    'TELEMETRY_TEST_MYSQL_DSN:',
    'TELEMETRY_TEST_REDIS_URL:',
    'TELEMETRY_MYSQL_DSN:',
    'TELEMETRY_REDIS_URL:',
  ]) {
    _expect(
      workflow.contains(marker),
      'relay-quality must provision Analytics dependencies and test URLs: $marker',
    );
  }

  for (final coverage in [backendCoverage, backendCoveragePowerShell]) {
    _expect(
      coverage.contains('coverpkg') &&
          coverage.contains('go list') &&
          coverage.contains('./internal/...') &&
          coverage.contains('./cmd/...') &&
          coverage.contains('TELEMETRY_TEST_MYSQL_DSN') &&
          coverage.contains('TELEMETRY_TEST_REDIS_URL'),
      'Backend coverage must instrument production packages and run telemetry integration tests.',
    );
    _expect(
      coverage.contains('internal/telemetry') &&
          coverage.contains('TELEMETRY_COVERAGE_MINIMUM'),
      'Backend coverage must enforce a real telemetry-specific threshold.',
    );
  }
  _expect(
    bashApp.contains('partition_app_tests') &&
        bashApp.contains('Security regression grep') &&
        bashApp.contains('retrying once'),
    'Bash App CI must keep balanced sharding, security grep, and retries.',
  );
  _expect(
    powerShellApp.contains('Partition-AppFiles') &&
        powerShellApp.contains('SshIdentityCache') &&
        powerShellApp.contains('Retrying App shard') &&
        powerShellApp.contains('Assert-AppSecurityIdentifiers'),
    'PowerShell App CI must match Bash sharding, security grep, and retries.',
  );
  _expect(
    bashTelemetryE2e.contains('TELEMETRY_INGESTION_PASS') &&
        bashTelemetryE2e.contains('telemetry_ingest') &&
        bashTelemetryE2e.contains('--test telemetry_e2e') &&
        !bashTelemetryE2e.contains('/api/admin/v1/telemetry/devices') &&
        !bashTelemetryE2e.contains('/api/admin/v1/auth/login') &&
        !bashTelemetryE2e.contains('ADMIN_USER') &&
        !bashTelemetryE2e.contains('TELEMETRY_DEVICE_SECRET') &&
        bashE2e.contains('assert_storage_after_restart'),
    'Bash E2E must use the proof-bound telemetry flow without copying secrets.',
  );
  _expect(
    powerShellTelemetryE2e.contains('TELEMETRY_INGESTION_PASS') &&
        powerShellE2e.contains('TelemetryIngestion') &&
        powerShellTelemetryE2e.contains("'--test', 'telemetry_e2e'") &&
        !powerShellTelemetryE2e.contains('/api/admin/v1/telemetry/devices') &&
        !powerShellTelemetryE2e.contains('/api/admin/v1/auth/login') &&
        !powerShellTelemetryE2e.contains('adminPassword') &&
        !powerShellTelemetryE2e.contains('TELEMETRY_DEVICE_SECRET') &&
        powerShellE2e.contains('AssertStorageAfterRestart'),
    'PowerShell E2E must match Bash proof-bound telemetry assertions.',
  );
  _expect(
    rustTelemetryE2e.contains('/v2/devices/enroll') &&
        rustTelemetryE2e.contains('/api/v1/telemetry/enroll') &&
        rustTelemetryE2e.contains('/api/v1/telemetry/auth') &&
        rustTelemetryE2e.contains('/api/v1/telemetry/ingest') &&
        rustTelemetryE2e.contains('ingest_with_automatic_refresh') &&
        rustTelemetryE2e.contains('status != 401'),
    'Telemetry live E2E must cover Relay enrollment, proof auth, ingest, and 401 refresh.',
  );
  _expect(
    bashE2e.contains('COMPOSE_PROFILE_ARGS=(--profile storage)') &&
        powerShellE2e.contains("'--profile','storage'"),
    'Both E2E launchers must activate the required Analytics storage profile.',
  );
  _expect(
    powerShellRunner.contains('RecordSkip') &&
        powerShellRunner.contains('Flutter coverage was not enabled') &&
        powerShellRunner.contains('Full App coverage depends'),
    'PowerShell CI must preserve Bash app-coverage skip semantics.',
  );

  final bashCi = Directory('${root.path}/scripts/bash/ci');
  final powershellCi = Directory('${root.path}/scripts/powershell/ci');
  final bashNames = bashCi
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.sh'))
      .map((file) => _basename(file.path, '.sh'))
      .toSet();
  final powerShellNames = powershellCi
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.ps1'))
      .map((file) => _basename(file.path, '.ps1'))
      .toSet();
  _expect(
    bashNames.difference(powerShellNames).isEmpty &&
        powerShellNames.difference(bashNames).isEmpty,
    'CI helper modules must have same-relative Bash and PowerShell pairs.',
  );
  for (final file in [
    ...bashCi.listSync().whereType<File>(),
    ...powershellCi.listSync().whereType<File>(),
  ]) {
    _expect(
      file.readAsLinesSync().length <= 500,
      'CI script exceeds the 500-line review limit: ${file.path}',
    );
  }

  // The relay Go floor, the images that build it, and the CI toolchain must not
  // drift apart: a go.mod bump that outruns the image breaks every deploy.
  final relayGo = RegExp(
    r'^go (\d+)\.(\d+)',
    multiLine: true,
  ).firstMatch(File('${root.path}/relay/go.mod').readAsStringSync());
  final workflowGo = RegExp(r"GO_VERSION: '(\d+)\.(\d+)").firstMatch(workflow);
  _expect(
    relayGo != null && workflowGo != null,
    'relay/go.mod and the workflow GO_VERSION must pin Go versions.',
  );
  if (relayGo != null && workflowGo != null) {
    final requiredMajor = int.parse(relayGo.group(1)!);
    final requiredMinor = int.parse(relayGo.group(2)!);
    _expect(
      int.parse(workflowGo.group(1)!) == requiredMajor &&
          int.parse(workflowGo.group(2)!) >= requiredMinor,
      'CI GO_VERSION must stay on the relay go.mod major and satisfy its floor.',
    );
    for (final name in const ['Dockerfile.relay', 'Dockerfile.admin']) {
      final image = File('${root.path}/relay/$name').readAsStringSync();
      final from = RegExp(
        r'^FROM golang:(\d+)\.(\d+)-alpine@sha256:([0-9a-f]{64}) AS build',
        multiLine: true,
      ).firstMatch(image);
      _expect(
        from != null,
        'relay/$name must build on a digest-pinned golang Alpine image.',
      );
      if (from == null) {
        continue;
      }
      _expect(
        int.parse(from.group(1)!) == requiredMajor &&
            int.parse(from.group(2)!) >= requiredMinor,
        'relay/$name Go image must satisfy the relay go.mod floor.',
      );
      _expect(
        int.parse(from.group(1)!) == int.parse(workflowGo.group(1)!) &&
            int.parse(from.group(2)!) == int.parse(workflowGo.group(2)!),
        'relay/$name Go image must be the Go minor CI actually tests with.',
      );
    }
  }

  // cargo-audit exceptions stay reviewed, and the config must stay inside the
  // step's working directory, or an ignore list would silently widen the gate.
  final auditConfig = File(
    '${root.path}/native/network_core/.cargo/audit.toml',
  ).readAsStringSync();
  final rustJob = workflow.substring(
    workflow.indexOf('native-network-quality:'),
  );
  _expect(
    rustJob.contains('working-directory: native/network_core') &&
        rustJob.contains('cargo audit'),
    'cargo audit must run inside native/network_core so .cargo/audit.toml is used.',
  );
  _expect(
    auditConfig.contains('[advisories]'),
    'native/network_core/.cargo/audit.toml must declare the advisories section.',
  );
  final ignored = RegExp(
    r'ignore\s*=\s*\[(.*?)\]',
    dotAll: true,
  ).firstMatch(auditConfig);
  _expect(
    ignored != null,
    'native/network_core/.cargo/audit.toml must declare an explicit ignore list.',
  );
  _expect(
    ignored != null &&
        RegExp(r'"RUSTSEC-[0-9]{4}-[0-9]{4}"')
            .allMatches(ignored.group(1)!)
            .map((match) => match.group(0)!)
            .toSet()
            .difference(const {'"RUSTSEC-2026-0387"'})
            .isEmpty,
    'Every cargo-audit exception needs a reviewed entry in this test.',
  );
  _expect(
    auditConfig.contains('rtc-dtls') && auditConfig.contains('p256'),
    'cargo-audit exceptions must document the chain that blocks the fix.',
  );

  stdout.writeln('CI production configuration tests passed.');
}

String _basename(String path, String suffix) {
  final name = path.split(RegExp(r'[\\/]')).last;
  return name.substring(0, name.length - suffix.length);
}

Directory _findRepositoryRoot() {
  var current = Directory.current;
  while (true) {
    if (File('${current.path}/pubspec.yaml').existsSync() &&
        File('${current.path}/compose.yaml').existsSync()) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Unable to find SSH Mobile repository root.');
    }
    current = parent;
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
