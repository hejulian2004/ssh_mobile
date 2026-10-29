最新更新时间：2026-10-29

# connection_core

`connection_core` 是 Connection 领域的 Core Package，负责非 UI 领域模型、
Connection/凭据/Host Key 公共契约，以及只保存非敏感连接结构的独立 Drift
数据库。

## 边界

- `ConnectionConfig` 的密码和私钥字段只用于短生命周期运行时数据，数据库映射
  会主动排除它们。
- `ConnectionRepository` 只管理连接结构和排序；`CredentialRepository` 只管理
  Secure Storage 中的密码、私钥；`HostKeyRepository` 只管理 Host Key 信任元数据。
- 可选的公开 `ConnectionCatalogChanges.watchConnections()` 能力由
  `DriftConnectionRepository` 提供：从原有数据库订阅首次、更新和删除后的不可变
  连接结构快照，排除凭据字段。查询订阅由调用方取消，数据库仍由 AppRuntime 关闭。
  `test/connection_catalog_changes_test.dart` 验证目录变化及凭据隔离。
- Connection ID 必须非空且已规范化，Repository 不会静默 trim；Secure Storage
  使用版本化、无碰撞编码键，并在首次读取时按“先写新键、再删旧键”迁移历史键。
- `ConnectionDatabase` 是本 Package 的资源，由 AppRuntime 创建并关闭；它使用
  `connection.sqlite`，不读取或迁移旧统一业务数据库/SharedPreferences 连接数据。
- 本 Package 不依赖任何 Feature，也不暴露 `/src/` 路径给外部调用方。
- Full App 的旧 Connection 模型、ViewModel 和页面入口已完成零引用清理；
  AppRuntime 仍通过公开 Repository/Host Key/Credential 契约提供唯一 Owner。

## 验证

```bash
flutter pub get
dart run build_runner build
flutter analyze
flutter test
```

## Package contract

- 职责：提供 Connection 模型、Repository、凭据/Host Key 契约和非敏感 Drift 数据库。
- 不负责：UI、SSH 会话、Feature 编排或 App 全局生命周期。
- Public API：`package:connection_core/connection_core.dart`。
- 依赖：`app_core`、Drift、`flutter_secure_storage` 和 Flutter SDK。
- 数据库：`ConnectionDatabase` 独占 `connection.sqlite`，表中不得出现密码、私钥或
  Token 字段。
- 生命周期与资源 Owner：AppRuntime 创建并关闭数据库、Repository 和 Secure Storage
  能力；调用方不得通过静态单例隐藏 Owner。
- 测试命令：`dart run build_runner build`、`flutter analyze`、`flutter test`。
