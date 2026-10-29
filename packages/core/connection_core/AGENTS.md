最新更新时间：2026-10-29

# connection_core 维护约束

- 只放 Connection 领域模型、Repository/Capability、Connection Drift DB 和
  Secure Storage 凭据实现；不放 Screen/ViewModel/SSH 会话。Drift 只保存非敏感
  结构；密码、私钥、Token 经 `CredentialRepository` 进入平台 Secure Storage。
- `ConnectionDatabase`（固定 `connection.sqlite`）由 AppRuntime 创建/关闭；
  Repository 不创建全局 DB、不静态隐藏 Owner。禁止旧统一业务 DB 或
  SharedPreferences 迁移适配器。生产打开失败不得回退内存。
- `ConnectionCatalogChanges.watchConnections()` 是可选的公开只读目录能力，
  `DriftConnectionRepository` 通过原有数据库发出不可变、无凭据的持久化快照。
  订阅者只取消自己的订阅，不关闭数据库或另建目录缓存；导入、更新、删除必须
  由同一查询流观察。App 层自行转换最小安全目录，不把结构配置传给平台插件。
- Full App 旧 Connection 入口/模型导出（`apps/ssh_mobile_full/lib/features/connection/`）
  已关闭；调用方只能使用公开契约。
- CRUD、并发顺序、凭据隔离、Host Key/迁移和生命周期变化先以失败/characterization
  测试定义结果；新增/修改代码补充中文职责/约束注释。
- Contract：允许模型、Repository、Host Key/凭据契约、DB 输入/生成代码和测试；
  API 变更同步 `connection_core.dart`、AppRuntime adapter、迁移文档和生成物。

## 验证（代码变更）

`dart run build_runner build`、`flutter analyze`、`flutter test`；local aggregate
CI 仅按用户明确要求运行。
