/// Connection Feature 的唯一公共入口。
///
/// App 和其他模块只能通过这里取得 ViewModel、页面和 Capability Contract，
/// 避免跨 Package 依赖 `src/` 实现细节。
library;

import 'package:app_core/app_core.dart';

export 'package:connection_core/connection_core.dart'
    show
        AuthMethod,
        ConnectionConfig,
        ConnectionProfile,
        ServerPlatform,
        TerminalLaunchMode;
export 'src/application/connection_ports.dart';
export 'src/application/connection_credential_editor.dart';
export 'src/application/connection_persistence_coordinator.dart'
    show ConnectionSaveRollbackException;
export 'src/application/connection_view_model.dart';
export 'src/presentation/add_edit_screen.dart';
export 'src/presentation/connection_strings.dart';

/// Connection Feature 对外公布的稳定路由名称。
abstract final class ConnectionRouteNames {
  /// 新增连接页面。
  static const add = '/add';

  /// 编辑连接页面。
  static const edit = '/edit';
}

/// Connection Feature 的路由元数据贡献；App Shell 负责解释页面构建。
final List<ModuleRouteContribution> connectionRouteContributions =
    List.unmodifiable([
      ModuleRouteContribution(routeName: ConnectionRouteNames.add),
      ModuleRouteContribution(routeName: ConnectionRouteNames.edit),
    ]);
