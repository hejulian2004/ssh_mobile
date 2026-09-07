import 'dart:io';

import '../../tool/check_resource_owners.dart';

/// 资源 Owner 表的无外部依赖回归测试，防止最终审计文档出现空白 Owner。
void main() {
  _testCurrentResourceTablePasses();
  _testIncompleteResourceTableIsRejected();
  stdout.writeln('Resource owner checker tests passed.');
}

void _testCurrentResourceTablePasses() {
  final report = ResourceOwnerAuditor(
    repositoryRoot: Directory.current,
  ).audit();
  _expect(report.isValid, '当前资源 Owner 表不应有违规：${report.violations}');
  _expect(
    report.records.length >= requiredResourceNames.length,
    '资源表至少应覆盖所有关键资源。',
  );
  for (final resource in <String>[
    'RealtimeMediaSession',
    'RealtimeMediaEndpoint',
    'Native media ingress queue',
    'Native media egress queue',
    'RemoteVideoSurface',
  ]) {
    _expect(
      report.records.any((record) => record.resource == resource),
      '屏幕媒体资源必须有明确 Owner：$resource',
    );
  }
}

void _testIncompleteResourceTableIsRejected() {
  final root = Directory.systemTemp.createTempSync('ssh_mobile_owners_');
  try {
    final file = File(
      '${root.path}${Platform.pathSeparator}docs${Platform.pathSeparator}architecture${Platform.pathSeparator}RESOURCE_OWNERSHIP.md',
    )..createSync(recursive: true);
    file.writeAsStringSync(
      '最新更新时间：2026-08-10\n\n'
      '| Resource | Owner | Scope | Release |\n'
      '| --- | --- | --- | --- |\n'
      '| AppLogger |  | App | dispose |\n',
    );

    final report = ResourceOwnerAuditor(repositoryRoot: root).audit();
    final rules = report.violations.map((item) => item.rule).toSet();
    _expect(rules.contains('incomplete-resource'), '应拒绝空 Owner。');
    _expect(rules.contains('missing-resource'), '应拒绝遗漏关键资源。');
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
