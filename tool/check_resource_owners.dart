import 'dart:io';

/// Step 33 必须持续有明确 Owner 的资源名称。
const requiredResourceNames = <String>[
  'AppLogger',
  'AppLogDatabase',
  'AppSettings',
  'ConnectionDatabase',
  'NetworkRuntime',
  'Native handle',
  'RealtimeMediaSession',
  'RealtimeMediaEndpoint',
  'Native media ingress queue',
  'Native media egress queue',
  'RemoteVideoSurface',
  'SshSessionManager',
  'SSH Session',
  'SFTP compatibility service',
  'TerminalDatabase',
  'SftpDatabase',
  'AiDatabase',
  'PlaybookDatabase',
  'RagDatabase',
  'McpDatabase',
  'LanShareDatabase',
  'MonitoringService',
  'SystemAdminService',
  'WebViewService',
  'MCP HTTP Server',
  'LAN Receiver',
  'ViewModel',
  'Route Controller',
  'Timer',
  'StreamSubscription',
  'StreamController',
  'Isolate',
];

/// 资源 Owner 表中的一行。
final class ResourceOwnerRecord {
  const ResourceOwnerRecord({
    required this.resource,
    required this.owner,
    required this.scope,
    required this.release,
  });

  final String resource;
  final String owner;
  final String scope;
  final String release;
}

/// 资源 Owner 审计发现的问题。
final class ResourceOwnerViolation {
  const ResourceOwnerViolation({
    required this.rule,
    required this.resource,
    required this.message,
  });

  final String rule;
  final String resource;
  final String message;

  @override
  String toString() => '[$rule] $resource $message';
}

/// 资源 Owner 审计结果。
final class ResourceOwnerReport {
  const ResourceOwnerReport({required this.records, required this.violations});

  final List<ResourceOwnerRecord> records;
  final List<ResourceOwnerViolation> violations;

  bool get isValid => violations.isEmpty;
}

/// 检查架构文档中的资源 Owner 表是否完整，避免遗漏资源生命周期。
final class ResourceOwnerAuditor {
  ResourceOwnerAuditor({
    required this.repositoryRoot,
    this.documentPath = 'docs/architecture/RESOURCE_OWNERSHIP.md',
  });

  final Directory repositoryRoot;
  final String documentPath;

  /// 读取表格并检查关键资源的 Owner、Scope 和 Release 列。
  ResourceOwnerReport audit() {
    final file = File(_join(repositoryRoot.path, documentPath));
    final violations = <ResourceOwnerViolation>[];
    if (!file.existsSync()) {
      return ResourceOwnerReport(
        records: const <ResourceOwnerRecord>[],
        violations: <ResourceOwnerViolation>[
          ResourceOwnerViolation(
            rule: 'document',
            resource: documentPath,
            message: '资源 Owner 文档不存在。',
          ),
        ],
      );
    }

    final lines = file.readAsLinesSync();
    if (lines.isEmpty || !lines.first.startsWith('最新更新时间：')) {
      violations.add(
        const ResourceOwnerViolation(
          rule: 'document-date',
          resource: 'RESOURCE_OWNERSHIP.md',
          message: '文档首行必须包含最新更新时间标记。',
        ),
      );
    }
    if (!lines.any(
      (line) => line.trim() == '| Resource | Owner | Scope | Release |',
    )) {
      violations.add(
        const ResourceOwnerViolation(
          rule: 'table-header',
          resource: 'RESOURCE_OWNERSHIP.md',
          message: '缺少 Resource/Owner/Scope/Release 表头。',
        ),
      );
    }

    final records = _parseRecords(lines);
    final byResource = <String, ResourceOwnerRecord>{};
    for (final record in records) {
      if (byResource.containsKey(record.resource)) {
        violations.add(
          ResourceOwnerViolation(
            rule: 'duplicate-resource',
            resource: record.resource,
            message: '资源不得在 Owner 表中重复声明。',
          ),
        );
      }
      byResource[record.resource] = record;
      if (_isBlankOrPlaceholder(record.owner) ||
          _isBlankOrPlaceholder(record.scope) ||
          _isBlankOrPlaceholder(record.release)) {
        violations.add(
          ResourceOwnerViolation(
            rule: 'incomplete-resource',
            resource: record.resource,
            message: 'Owner、Scope 和 Release 均必须填写，不能使用占位符。',
          ),
        );
      }
    }
    for (final resource in requiredResourceNames) {
      if (!byResource.containsKey(resource)) {
        violations.add(
          ResourceOwnerViolation(
            rule: 'missing-resource',
            resource: resource,
            message: '关键资源没有 Owner 表记录。',
          ),
        );
      }
    }
    return ResourceOwnerReport(records: records, violations: violations);
  }

  List<ResourceOwnerRecord> _parseRecords(List<String> lines) {
    final records = <ResourceOwnerRecord>[];
    for (final line in lines) {
      if (!line.trimLeft().startsWith('|')) continue;
      final cells = line.split('|').map((cell) => cell.trim()).toList();
      if (cells.length < 6 ||
          cells[1] == 'Resource' ||
          cells[1].startsWith('---')) {
        continue;
      }
      records.add(
        ResourceOwnerRecord(
          resource: cells[1],
          owner: cells[2],
          scope: cells[3],
          release: cells[4],
        ),
      );
    }
    return records;
  }
}

bool _isBlankOrPlaceholder(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized.isEmpty ||
      normalized.contains('todo') ||
      normalized.contains('tbd') ||
      normalized.contains('待补') ||
      normalized == 'unknown' ||
      normalized == '???';
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';

void main() {
  final report = ResourceOwnerAuditor(
    repositoryRoot: Directory.current,
  ).audit();
  stdout.writeln(
    'Resource owner audit: ${report.records.length} records, '
    '${requiredResourceNames.length} required resources.',
  );
  if (report.isValid) {
    stdout.writeln('Resource owner audit passed.');
    return;
  }
  stderr.writeln(
    'Resource owner audit failed with '
    '${report.violations.length} violation(s):',
  );
  for (final violation in report.violations) {
    stderr.writeln('  $violation');
  }
  exitCode = 1;
}
