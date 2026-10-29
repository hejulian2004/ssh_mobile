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
- 可选 `CredentialCryptoPort` 由 App 注入平台认证加密能力；
  `SecureCredentialRepository` 仍是唯一凭据存储 Owner。`CredentialProtectionRepository`
  暴露保护开关、只读 revision、一次完整 pair 解锁和显式受保护更新。
  普通 getter/save 遇到保护记录只返回 typed locked/corrupt，不读取旧键。
- 保护 pair 的 JSON 明文预算为 512 KiB；AES-GCM、认证与按 revision 的密钥均由平台
  Owner 负责，AAD 绑定规范连接 ID 和随机 revision。新保护 API 接受 1–256 字符 ID，
  不改变未保护凭据的既有 ID 契约。每个 ID 的读写、迁移和保护状态变更严格串行。
- 密文记录经写入回读核验后才清理旧键。失败/不明写入保留可恢复密文和密钥；
  删除尽最大努力清理各版本键和已知 Keystore revision，部分失败保留阻断旧键读取的
  tombstone，可重试。保护记录、revision 账本和秘密都只进入同一 Secure Storage 命名空间。
  新 revision 的清理账本必须先持久化并回读核验，平台才可 seal/生成 Keystore 密钥；
  提示框期间 engine/进程终止后，重建的 Owner 仍能发现并清理未交付的密钥。
- 保存协调使用 `captureProtectedSnapshot` 保留旧密钥的 opaque 租约；成功后必须
  `discardProtectedSnapshot`，失败用 `restoreProtectedSnapshot` 无解密回滚。
  restore 消费租约，discard 对同 Owner 已消费租约幂等。租约只能恢复自己直接产生的
  后继状态，不能覆盖别的 Repository、后续 revision 或关闭保护后的正常凭据更新。
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
