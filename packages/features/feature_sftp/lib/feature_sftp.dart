// SFTP Feature 的唯一公共入口。
//
// App Shell 只能通过此文件使用 SFTP 的 Module、Route VM、模型和 Port，
// 不得直接引用 package 内部的 src 路径。
library;

import 'package:app_core/app_core.dart';

export 'src/application/sftp_module.dart';
export 'src/application/sftp_viewmodel.dart';
export 'src/data/database/sftp_database.dart';
export 'src/data/repository/drift_sftp_path_history_repository.dart';
export 'src/data/sftp_service.dart';
export 'src/domain/sftp_document.dart';
export 'src/domain/sftp_models.dart';
export 'src/domain/sftp_ports.dart';
export 'src/domain/sftp_strings.dart';
export 'src/presentation/sftp_editor_screen.dart';
export 'src/presentation/sftp_file_viewer_screen.dart';
export 'src/presentation/sftp_screen.dart';
export 'src/presentation/sftp_settings_screen.dart';

/// SFTP Feature 对外公布的稳定路由名称。
abstract final class SftpRouteNames {
  /// SFTP 浏览页面。
  static const browser = '/sftp';
}

/// SFTP Feature 的路由元数据贡献；App Shell 负责解释页面构建。
final List<ModuleRouteContribution> sftpRouteContributions = List.unmodifiable([
  ModuleRouteContribution(routeName: SftpRouteNames.browser),
]);
