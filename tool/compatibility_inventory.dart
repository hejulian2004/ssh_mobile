/// 模块化迁移期间的旧入口清单。
///
/// 这里记录的是 App 包对旧 `ssh_mobile` URI 的引用，而不是 App Shell
/// adapter。Adapter 仍然可以依赖 App Scope 的兼容后端；模块关闭前，旧
/// 业务入口的引用数量只能下降，不能回增。

/// 当前模块的兼容层状态。
enum CompatibilityModuleState {
  /// 调用方仍在迁移，旧引用允许存在但不得超过基线。
  migrating,

  /// 调用方已经完成迁移，任何旧引用都应使架构检查失败。
  closed,
}

/// 单个 Feature 的兼容引用、Owner 和删除条件。
final class CompatibilityModule {
  const CompatibilityModule({
    required this.id,
    required this.packageName,
    required this.state,
    required this.legacyImportPrefixes,
    required this.packageSourceRoot,
    required this.legacySourceRoots,
    required this.baselineReferenceCount,
    required this.baselineSourceCount,
    required this.appShellAdapters,
    required this.removalCondition,
  });

  /// 稳定的迁移清单编号。
  final String id;

  /// 迁移后的唯一 Package Owner。
  final String packageName;

  /// 是否已经切换到零旧引用失败门禁。
  final CompatibilityModuleState state;

  /// 旧 App `package:ssh_mobile/...` 导入 URI 前缀。
  final List<String> legacyImportPrefixes;

  /// 维护实现所在的 Package `lib/` 根目录。
  final String packageSourceRoot;

  /// 迁移期间可能存在重复业务实现的旧 App 源码根目录。
  ///
  /// App Shell 适配器和仍被多个 Feature 使用的协议后端不放在这里，
  /// 因而不会被重复实现检查误判为 Feature 副本。
  final List<String> legacySourceRoots;

  /// 当前清单基线中的旧导入条数。
  final int baselineReferenceCount;

  /// 当前清单基线中的引用文件数。
  final int baselineSourceCount;

  /// 仍然需要保留的 App Shell 适配边界。
  final List<String> appShellAdapters;

  /// 可以删除旧入口的可验证条件。
  final String removalCondition;

  /// 判断导入 URI 是否属于该模块。
  bool matches(String importUri) =>
      legacyImportPrefixes.any(importUri.startsWith);
}

/// 迁移清单。修改基线前必须先删除真实调用方，并同步文档中的引用数。
const compatibilityInventory = <CompatibilityModule>[
  CompatibilityModule(
    id: 'connection',
    packageName: 'feature_connection / connection_core',
    state: CompatibilityModuleState.closed,
    legacyImportPrefixes: <String>['package:ssh_mobile/features/connection/'],
    packageSourceRoot: 'packages/features/feature_connection/lib',
    legacySourceRoots: <String>['apps/ssh_mobile_full/lib/features/connection'],
    baselineReferenceCount: 0,
    baselineSourceCount: 0,
    appShellAdapters: <String>[
      'apps/ssh_mobile_full/lib/app/connection_feature_adapters.dart',
      'apps/ssh_mobile_full/lib/app/connection_runtime_adapters.dart',
    ],
    removalCondition: '旧 Connection Feature 路径已删除；仅保留 App Shell Port 适配器。',
  ),
  CompatibilityModule(
    id: 'terminal',
    packageName: 'feature_terminal',
    state: CompatibilityModuleState.closed,
    legacyImportPrefixes: <String>['package:ssh_mobile/features/terminal/'],
    packageSourceRoot: 'packages/features/feature_terminal/lib',
    legacySourceRoots: <String>['apps/ssh_mobile_full/lib/features/terminal'],
    baselineReferenceCount: 0,
    baselineSourceCount: 0,
    appShellAdapters: <String>[
      'apps/ssh_mobile_full/lib/app/terminal_feature_adapters.dart',
      'apps/ssh_mobile_full/lib/app/terminal_ssh_capability_adapter.dart',
      'apps/ssh_mobile_full/lib/services/terminal_history_service.dart',
      'apps/ssh_mobile_full/lib/services/terminal_session_metadata_store.dart',
    ],
    removalCondition:
        '旧 Terminal Feature 路径和导出已删除；App Shell 的 SSH/历史元数据后端保留至 SSH method-level migration。',
  ),
  CompatibilityModule(
    id: 'sftp',
    packageName: 'feature_sftp',
    state: CompatibilityModuleState.closed,
    legacyImportPrefixes: <String>['package:ssh_mobile/features/sftp/'],
    packageSourceRoot: 'packages/features/feature_sftp/lib',
    legacySourceRoots: <String>['apps/ssh_mobile_full/lib/features/sftp'],
    baselineReferenceCount: 0,
    baselineSourceCount: 0,
    appShellAdapters: <String>[
      'apps/ssh_mobile_full/lib/app/sftp_feature_adapters.dart',
      'apps/ssh_mobile_full/lib/app/sftp_backend_adapters.dart',
      'apps/ssh_mobile_full/lib/app/sftp_io_backend_adapters.dart',
      'apps/ssh_mobile_full/lib/services/sftp_service.dart',
      'apps/ssh_mobile_full/lib/services/sftp_path_history_store.dart',
      'apps/ssh_mobile_full/lib/services/sftp/sftp_cache.dart',
      'apps/ssh_mobile_full/lib/services/sftp/sftp_connection_lifecycle.dart',
      'apps/ssh_mobile_full/lib/services/sftp/sftp_directory_navigation.dart',
      'apps/ssh_mobile_full/lib/services/sftp/sftp_entry_parser.dart',
      'apps/ssh_mobile_full/lib/services/sftp/sftp_operations.dart',
      'apps/ssh_mobile_full/lib/services/sftp/sftp_service_io.dart',
      'apps/ssh_mobile_full/lib/services/sftp/sftp_service_stub.dart',
    ],
    removalCondition:
        '旧 SFTP Feature 页面/ViewModel/测试已删除；App Shell SftpService、缓存和协议后端作为明确适配边界保留至 SSH/SFTP backend convergence。',
  ),
  CompatibilityModule(
    id: 'monitoring',
    packageName: 'feature_monitoring',
    state: CompatibilityModuleState.closed,
    legacyImportPrefixes: <String>[
      'package:ssh_mobile/features/performance/',
      'package:ssh_mobile/services/performance_monitor_service.dart',
      'package:ssh_mobile/services/performance_monitor_models.dart',
      'package:ssh_mobile/services/performance_monitor_tool_service.dart',
      'package:ssh_mobile/services/server_status_probe.dart',
    ],
    packageSourceRoot: 'packages/features/feature_monitoring/lib',
    legacySourceRoots: <String>[
      'apps/ssh_mobile_full/lib/features/performance',
    ],
    baselineReferenceCount: 0,
    baselineSourceCount: 0,
    appShellAdapters: <String>[
      'apps/ssh_mobile_full/lib/app/monitoring_feature_adapters.dart',
      'apps/ssh_mobile_full/lib/app/monitoring_widget_adapter.dart',
      'apps/ssh_mobile_full/lib/app/system_admin_feature_adapters.dart',
      'apps/ssh_mobile_full/lib/services/server_diagnostics_service.dart',
      'apps/ssh_mobile_full/lib/services/server_status_probe.dart',
    ],
    removalCondition:
        '旧 Performance service/tool/probe、诊断组合和测试均改用 Monitoring Port。',
  ),
  CompatibilityModule(
    id: 'system_admin',
    packageName: 'feature_system_admin',
    state: CompatibilityModuleState.closed,
    legacyImportPrefixes: <String>[
      'package:ssh_mobile/features/system_admin/',
      'package:ssh_mobile/services/system_admin_service.dart',
    ],
    packageSourceRoot: 'packages/features/feature_system_admin/lib',
    legacySourceRoots: <String>[
      'apps/ssh_mobile_full/lib/features/system_admin',
    ],
    baselineReferenceCount: 0,
    baselineSourceCount: 0,
    appShellAdapters: <String>[
      'apps/ssh_mobile_full/lib/app/system_admin_feature_adapters.dart',
    ],
    removalCondition: '旧 System Admin 页面、命令服务、诊断组合和测试均改用 Feature 公共入口。',
  ),
  CompatibilityModule(
    id: 'lan_share',
    packageName: 'feature_lan_share',
    state: CompatibilityModuleState.closed,
    legacyImportPrefixes: <String>[
      'package:ssh_mobile/features/lan_share/',
      'package:ssh_mobile/services/lan_share/',
      'package:ssh_mobile/services/lan_',
    ],
    packageSourceRoot: 'packages/features/feature_lan_share/lib',
    legacySourceRoots: <String>[
      'apps/ssh_mobile_full/lib/features/lan_share',
      'apps/ssh_mobile_full/lib/services/lan_share',
    ],
    baselineReferenceCount: 0,
    baselineSourceCount: 0,
    appShellAdapters: <String>[
      'apps/ssh_mobile_full/lib/app/lan_share_feature_adapters.dart',
      'apps/ssh_mobile_full/lib/app/lan_share_emulator_discovery.dart',
      'apps/ssh_mobile_full/lib/app/lan_share_emulator_host.dart',
    ],
    removalCondition: '旧 LAN 路由、页面、测试、Service 和 Runtime getter 均为零引用。',
  ),
  CompatibilityModule(
    id: 'playbook',
    packageName: 'feature_playbook',
    state: CompatibilityModuleState.closed,
    legacyImportPrefixes: <String>[
      'package:ssh_mobile/features/playbook/',
      'package:ssh_mobile/services/playbook_service.dart',
    ],
    packageSourceRoot: 'packages/features/feature_playbook/lib',
    legacySourceRoots: <String>['apps/ssh_mobile_full/lib/features/playbook'],
    baselineReferenceCount: 0,
    baselineSourceCount: 0,
    appShellAdapters: <String>[
      'apps/ssh_mobile_full/lib/app/playbook_feature_adapters.dart',
    ],
    removalCondition:
        '旧 Playbook UI/service、AI 调用和测试均使用 PlaybookAutomationPort。',
  ),
  CompatibilityModule(
    id: 'rag',
    packageName: 'feature_rag',
    state: CompatibilityModuleState.closed,
    legacyImportPrefixes: <String>[
      'package:ssh_mobile/features/rag/',
      'package:ssh_mobile/services/rag_service.dart',
    ],
    packageSourceRoot: 'packages/features/feature_rag/lib',
    legacySourceRoots: <String>['apps/ssh_mobile_full/lib/features/rag'],
    baselineReferenceCount: 0,
    baselineSourceCount: 0,
    appShellAdapters: <String>[
      'apps/ssh_mobile_full/lib/app/rag_feature_adapters.dart',
    ],
    removalCondition: '旧 RAG 页面/service、AI 调用和测试均使用 RagCapability。',
  ),
  CompatibilityModule(
    id: 'network',
    packageName: 'network_transport / network_sdk',
    state: CompatibilityModuleState.closed,
    legacyImportPrefixes: <String>[
      'package:ssh_mobile/services/network/',
      'package:ssh_mobile/services/relay/',
    ],
    packageSourceRoot: 'packages/infrastructure/network_transport/lib',
    legacySourceRoots: <String>[
      'apps/ssh_mobile_full/lib/services/network',
      'apps/ssh_mobile_full/lib/services/relay',
    ],
    baselineReferenceCount: 0,
    baselineSourceCount: 0,
    appShellAdapters: <String>[
      'apps/ssh_mobile_full/lib/app/network_sdk_adapters.dart',
      'apps/ssh_mobile_full/lib/app/lan_share_feature_adapters.dart',
      'apps/ssh_mobile_full/lib/services/network/network_identity_service.dart',
      'apps/ssh_mobile_full/lib/services/network/network_protocol_v2_codec.dart',
      'apps/ssh_mobile_full/lib/services/network/network_service.dart',
      'apps/ssh_mobile_full/lib/services/network/network_service_command_coordinator.dart',
      'apps/ssh_mobile_full/lib/services/network/network_service_event_hub.dart',
      'apps/ssh_mobile_full/lib/services/network/network_service_event_router.dart',
      'apps/ssh_mobile_full/lib/services/network/network_service_lifecycle.dart',
      'apps/ssh_mobile_full/lib/services/network/network_service_peer_adapter.dart',
      'apps/ssh_mobile_full/lib/services/network/network_service_relay_adapter.dart',
      'apps/ssh_mobile_full/lib/services/network/network_service_route_adapter.dart',
      'apps/ssh_mobile_full/lib/services/network/network_service_runtime_gateway.dart',
      'apps/ssh_mobile_full/lib/services/network/network_service_state_projection.dart',
      'apps/ssh_mobile_full/lib/services/network/network_service_support.dart',
      'apps/ssh_mobile_full/lib/services/network/network_service_transfer_adapter.dart',
    ],
    removalCondition:
        '旧 relay enrollment 已迁入 feature_lan_share；network v1 codec/service/identity 仅作为 App Scope native adapter 保留，调用方和测试均通过 typed network_sdk contract。',
  ),
  CompatibilityModule(
    id: 'mcp',
    packageName: 'feature_mcp',
    state: CompatibilityModuleState.closed,
    legacyImportPrefixes: <String>[
      'package:ssh_mobile/features/mcp_console/',
      'package:ssh_mobile/services/mcp/',
    ],
    packageSourceRoot: 'packages/features/feature_mcp/lib',
    legacySourceRoots: <String>[
      'apps/ssh_mobile_full/lib/features/mcp_console',
      'apps/ssh_mobile_full/lib/services/mcp',
    ],
    baselineReferenceCount: 0,
    baselineSourceCount: 0,
    appShellAdapters: <String>[
      'apps/ssh_mobile_full/lib/app/mcp_feature_adapters.dart',
    ],
    removalCondition: '保持 feature_mcp 公共入口和 App Shell adapter，不恢复旧 MCP 业务入口。',
  ),
  CompatibilityModule(
    id: 'webview',
    packageName: 'feature_webview',
    state: CompatibilityModuleState.closed,
    legacyImportPrefixes: <String>[
      'package:ssh_mobile/features/client_webview/',
      'package:ssh_mobile/services/client_webview/',
    ],
    packageSourceRoot: 'packages/features/feature_webview/lib',
    legacySourceRoots: <String>[
      'apps/ssh_mobile_full/lib/features/client_webview',
      'apps/ssh_mobile_full/lib/services/client_webview',
    ],
    baselineReferenceCount: 0,
    baselineSourceCount: 0,
    appShellAdapters: <String>[
      'apps/ssh_mobile_full/lib/app/webview_feature_adapters.dart',
    ],
    removalCondition:
        '保持 feature_webview 公共入口和 App Shell adapter，不恢复旧 WebView 业务入口。',
  ),
  CompatibilityModule(
    id: 'developer',
    packageName: 'feature_developer',
    state: CompatibilityModuleState.closed,
    legacyImportPrefixes: <String>[
      'package:ssh_mobile/features/developer/',
      'package:ssh_mobile/services/developer/',
    ],
    packageSourceRoot: 'packages/features/feature_developer/lib',
    legacySourceRoots: <String>[
      'apps/ssh_mobile_full/lib/features/developer',
      'apps/ssh_mobile_full/lib/services/developer',
    ],
    baselineReferenceCount: 0,
    baselineSourceCount: 0,
    appShellAdapters: <String>[
      'apps/ssh_mobile_full/lib/app/developer_feature_adapters.dart',
    ],
    removalCondition:
        '保持 feature_developer 公共入口和 App Shell adapter，不恢复旧诊断业务入口。',
  ),
];

/// 按旧导入 URI 找到唯一的迁移模块。
CompatibilityModule? compatibilityModuleForImport(String importUri) {
  for (final module in compatibilityInventory) {
    if (module.matches(importUri)) return module;
  }
  return null;
}
