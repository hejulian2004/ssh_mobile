最新更新时间：2026-10-22

# feature_connection

SSH Mobile 的连接 Feature，负责连接配置编辑界面和连接配置的应用编排。

## 边界

- 只通过 `connection_core` 的 `ConnectionRepository`、`CredentialRepository` 和 `HostKeyRepository` 访问连接数据。
- SSH/SFTP/监控等运行时能力通过 `ConnectionRuntimePort` 和 `ConnectionVerificationPort` 注入，Feature 不创建 App Service。
- 验证 Port 只返回候选 Host Key，不提前持久化；ViewModel 通过独立的持久化
  Coordinator 串行提交连接结构、Host Key 与凭据，并在任一步失败时按逆序
  补偿恢复旧状态。
- 保存、删除、批量删除和排序共用同一 mutation queue；删除一旦开始结构持久化，
  即使 Route generation 已切换也会继续完成凭据清理，避免残留孤儿秘密。
- 不拥有 Connection 数据库；数据库生命周期仍由 AppRuntime 管理。
- 连接专属页面组件、布局指标和双语文案由本 Feature 维护，并使用共享 `app_ui`。
- 公共入口同时提供纯 Route metadata；App Shell 只聚合这些描述并在 Route Scope 创建
  ViewModel，不把 Widget 或 ViewModel 放入 Core。
- Full App 中旧 `features/connection/` 路径已完成零引用清理并删除；
  `apps/ssh_mobile_full/lib/app/connection_*_adapters.dart` 仍是保留的
  App Shell Port 适配边界，不属于旧业务实现。

## 公共入口

业务代码只能导入 `package:feature_connection/feature_connection.dart`，不能导入 `lib/src/`：

- `ConnectionViewModel`
- `ConnectionSaveRollbackException`
- `ConnectionRuntimePort`
- `ConnectionVerificationPort`
- `ConnectionStrings`
- `AddEditScreen`

## 生命周期

`ConnectionViewModel` 是 Route/Provider Scope 资源，释放时只解除 Repository 监听；Repository、凭据存储和 SSH/SFTP 服务由 AppRuntime 或注入方负责释放。

## Package contract

- 职责：提供连接编辑页面、ViewModel、文案和 Route metadata。
- 不负责：Connection 数据库、Secure Storage、SSH/SFTP 实现或 App Scope 资源。
- Public API：`package:feature_connection/feature_connection.dart`。
- 依赖：`app_core`、`app_ui`、`connection_core`、Flutter、Provider 和 UI 直接依赖。
- 数据库：不拥有数据库；Connection 数据由 `connection_core` 管理。
- 生命周期与资源 Owner：Route Scope 拥有 `ConnectionViewModel`；AppRuntime 拥有
  Repository、凭据、Host Key 和 SSH/SFTP 资源。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
