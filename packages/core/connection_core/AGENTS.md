最新更新时间：2026-10-29

# connection_core 维护约束

- 只放 Connection 领域模型、Repository/Capability、Connection Drift DB 和
  Secure Storage 凭据实现；不放 Screen/ViewModel/SSH 会话。Drift 只保存非敏感
  结构；密码、私钥、Token 经 `CredentialRepository` 进入平台 Secure Storage。
- `ConnectionDatabase`（固定 `connection.sqlite`）由 AppRuntime 创建/关闭；
  Repository 不创建全局 DB、不静态隐藏 Owner。禁止旧统一业务 DB 或
  SharedPreferences 迁移适配器。生产打开失败不得回退内存。
- Full App 旧 Connection 入口/模型导出（`apps/ssh_mobile_full/lib/features/connection/`）
  已关闭；调用方只能使用公开契约。
- 可选保护只经 `CredentialCryptoPort` 使用平台认证/Keystore；Core 不实现密码算法，
  不弹 UI。所有公开凭据操作按规范 ID 串行；保护记录存在即禁止 v2/legacy fallback。
  任何普通 getter/save 不得隐式弹认证或解密。解锁只返回短生命周期完整 pair。
- 保护 save/enable/disable 的异步认证后提交前核验 request `isCurrent`，更新核对
  `expectedRevision`；每次 seal 使用随机新 revision。保护回滚只用同 Owner 创建的
  opaque snapshot，不解密备份，不能恢复到外部后继状态或复活显式删除的凭据。
  密文和 revision 账本都放现有 Secure Storage；不新增明文 DB/偏好设置存储。
  调用平台 seal 前必须先持久化并核验新 revision 的清理账本；不能先生成平台密钥
  再登记 Owner。失败与取消保留旧凭据，不确定或清理失败的 revision 保留可重试记录。
- CRUD、并发顺序、凭据隔离、Host Key/迁移和生命周期变化先以失败/characterization
  测试定义结果；新增/修改代码补充中文职责/约束注释。
- Contract：允许模型、Repository、Host Key/凭据契约、DB 输入/生成代码和测试；
  API 变更同步 `connection_core.dart`、AppRuntime adapter、迁移文档和生成物。

## 验证（代码变更）

`dart run build_runner build`、`flutter analyze`、`flutter test`；local aggregate
CI 仅按用户明确要求运行。
