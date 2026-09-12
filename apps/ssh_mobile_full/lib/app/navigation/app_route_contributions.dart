import 'package:app_core/app_core.dart';
import 'package:feature_ai/feature_ai.dart' as feature_ai;
import 'package:feature_connection/feature_connection.dart'
    as feature_connection;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:feature_sftp/feature_sftp.dart' as feature_sftp;
import 'package:feature_terminal/feature_terminal.dart' as feature_terminal;

/// App Shell 自己拥有的固定路由名称。
abstract final class AppShellRouteNames {
  /// 启动路由。
  static const root = '/';

  /// 兼容旧入口的性能监控 Home 子页面路由。
  static const performance = '/performance';

  /// Explicit screen-share consent/media route.
  static const screenShare = '/screen-share';
}

/// App Shell 聚合 Feature 公共 API 暴露的路由元数据。
///
/// 贡献只包含稳定名称，不持有 Widget、ViewModel 或 Module 实例；真正的
/// 页面构建仍在 App Shell 的 Route Scope 中完成。
final class AppRouteContributionCatalog {
  AppRouteContributionCatalog._();

  /// 当前 Full App 的所有 Feature 路由贡献快照。
  static final List<ModuleRouteContribution> all = List.unmodifiable([
    ...feature_connection.connectionRouteContributions,
    ...feature_terminal.terminalRouteContributions,
    ...feature_sftp.sftpRouteContributions,
    ...feature_ai.aiRouteContributions,
    ...feature_playbook.playbookRouteContributions,
    ...feature_rag.ragRouteContributions,
    ...feature_mcp.mcpRouteContributions,
  ]);

  /// 判断路由是否已经由某个 Feature 公共 API 注册。
  static bool contains(String? routeName) =>
      routeName != null && all.any((item) => item.routeName == routeName);
}
