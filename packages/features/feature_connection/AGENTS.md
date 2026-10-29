最新更新时间：2026-10-29

# feature_connection 维护约束

- `ConnectionCredentialEditor` 由编辑 Route 创建和释放，只保存本次显式解锁的
  完整凭据 pair；受保护连接初始化禁止读取旧明文 getter。锁定、App 隐藏和
  Route 关闭清除编辑明文（包括尚未保护时的启用认证），使迟到认证结果失效。
  编辑目标从首次加载固定，观察到外部结构变更后必须重开页面；重试或再次
  initialize 不得重绑旧表单。发布前复核目标与凭据 revision。
- 生物识别加解密只调用 Core `CredentialProtectionRepository`，禁止把认证布尔值
  当作解密授权。启停保护与保存/删除共用现有 mutation queue；保护保存使用
  opaque snapshot 恢复密文，绝不额外读取明文作为回滚副本。创建 snapshot 的
  保存操作在 finally 释放它；平台密钥/认证生命周期仍由 App/Core 拥有。

- 独立连接 Feature；禁止导入 Full App 或其他 Feature `/src/`。数据只经
  `connection_core` Public API；本包不创建 Drift、Secure Storage、SSH、SFTP 或
  Monitoring Service。跨模块行为定义本包 Capability Contract，由 App 注入。
- `ConnectionViewModel` 由 Route/Provider Scope 拥有，不关闭 App Scope 服务。旧
  App Connection 入口已关闭；调用方只能用 `feature_connection.dart` 或
  `connection_core.dart`（App adapter 除外）。新增/重构代码补中文职责/生命周期/
  安全注释。
- Contract：允许编辑 UI、ViewModel、文案、Route metadata、Ports、测试；公共 API
  变更同步 App Route Scope/adapters。无数据库；Connection 数据由
  `connection_core` 管理；Route 释放监听，AppRuntime 释放服务。

## 验证（代码变更）

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、
`flutter test`；local aggregate CI 仅按用户明确要求运行。
