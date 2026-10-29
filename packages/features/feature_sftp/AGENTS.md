最新更新时间：2026-10-29

# feature_sftp 维护约束

- Android 单个文档的选择和保存由 App Shell 注入 `SftpDocumentAccessPort`。
  上传和下载仍调用现有路径 API；文档字节先按块写入一次临时文件。非 Android
  继续使用路径选择器。这里不把远程目录挂进系统文件管理器。
- `SftpBackend.targetFingerprint` 提供当前连接的目标身份，即使目录为空也可绑定。
  文档上传必须使用 picker 前捕获的 `(connectionId, targetFingerprint, directory)`，
  暂存后再次核验；App 后端必须在异步文件 I/O 前冻结上传路径。取消与 dispose
  主动释放当前文档源/目标，进行中的操作 finally 等待同一次关闭操作；Module
  用 awaitable `SftpService.close()` 排空操作后关闭数据库，不能重置/覆盖另一次暂存，
  也不能关闭借用的 App SSH/后端资源。
- 只依赖 `app_core`、`app_ui`、`ssh_core` 和本包 Ports；禁止 Full App services、
  其他 Feature `/src/` 或旧 App UI。App Shell 将旧 SFTP/Connection/Settings/
  logging/Host-Key 对话框适配为 Ports，适配逻辑不回流 Feature。
- `SftpModule` alone owns `sftp.db` and path Repository; Route VM releases only its
  listeners. App SSH Manager/compatibility backend are injected and never disposed
  here. DB fields/DAO changes run Drift generator and Repository/Module tests;
  passwords, private keys, Tokens, and raw credentials never enter DB.
- Target fingerprint, browse/preview/edit/upload/download/delete, Repository,
  lifecycle, or fail-closed changes start with a failing behavior test asserting
  result, target binding, and release. Contract: allowed SFTP UI/VM/Module/
  Repository/Service/Ports/tests; public API only `feature_sftp.dart`, syncing
  adapters/Route Scope/generated code; Module owns DB/listeners, AppRuntime owns
  SSH/compat backend.

## 验证（代码变更）

Package: `dart run build_runner build`, `flutter analyze --no-pub`,
`flutter test --no-pub`. Full App checks run from `apps/ssh_mobile_full/` so
native assets resolve correctly. Local aggregate CI is user-opt-in.
