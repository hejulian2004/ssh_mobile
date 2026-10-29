最新更新时间：2026-10-29

# feature_system_admin

System Administration 的 UI、Route ViewModel、管理命令协调和安全确认流程。

Package 只依赖 `app_core`、`app_ui`、`connection_core`、`ssh_core` 及显式 Port。
连接目录、SSH 管理会话、监控数据、SFTP 家目录浏览、文案和 Host Key 确认均由
App Shell 注入；不会创建全局 SSH/Storage，也不会直接引用
`feature_monitoring` 的实现。

当前模块不创建独立数据库。`SystemAdminModule` 持有管理服务并在 dispose 时关闭
当前管理会话和活动命令；`SystemAdminViewModel` 由 Route Scope 持有。

`FeatureSystemAdminScreen.monitoringConnectionId` 是可选的只读展示焦点，供 App
从桌面 Widget 导航到现有监控页时使用。监控页展示该服务器的详情或已移除提示；
此参数不修改监控选择，不启动监控、管理会话或 SSH。App 路由在传入前重新核对
当前 Connection 目录，Feature 仍只消费已注入的公开监控 Port。

管理会话使用 `SshTargetBinding` 不可变目标和 generation 绑定的专用 Lease；目标
切换、Route dispose、连接迟到或输出超限都会使旧 generation 失效并释放 Lease。
动态命令只通过 argv 参数传递，密码只写入受限 stdin；stdout/stderr 合计上限为
2 MiB。重启和关机确认 Token 同时绑定 target/generation，并由按有效期淘汰的
有界 registry 原子地一次性消费。

旧 `apps/ssh_mobile_full/lib/features/system_admin/` 路径、命令 facade 和旧测试
已删除；App Shell 仅保留 `system_admin_feature_adapters.dart` 这一 Port 适配边界。

## Package contract

- 职责：提供系统管理页面、Route ViewModel、管理命令协调和安全确认。
- 不负责：监控 Feature 实现、SSH/连接/SFTP 基础设施、数据库或 App 全局资源。
- Public API：`package:feature_system_admin/feature_system_admin.dart`。
- 依赖：`app_core`、`app_ui`、`connection_core`、`ssh_core` 和注入的管理 Port。
- 数据库：不拥有数据库；实时管理快照不得新增 `system_admin.db`。
- 生命周期与资源 Owner：Route Scope 拥有 `SystemAdminModule` 和 ViewModel；
  Module 负责管理 Service、活动命令、在途连接收敛和专用 SSH Lease，AppRuntime
  仅拥有注入的连接、凭据、Host Key 和 SSH 基础设施。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
