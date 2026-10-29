最新更新时间：2026-10-29

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
- App 注入实现 `CredentialProtectionRepository` 的凭据 Repository 时，现有编辑页
  支持对已保存连接启停生物识别保护。保护依赖平台认证加密，Feature 不实现密钥
  或密码存储。受保护凭据默认锁定，显式认证一次取得完整 pair 后才显示编辑字段；
  保存受保护凭据会再次认证加密。未保存的凭据修改不能直接改变已保存保护状态。
- `ConnectionCredentialEditor` 由 Route 拥有；锁定、App 隐藏或 Route 关闭清除本次
  编辑明文，启用保护尚在认证中也在隐藏时失效，恢复前台后可显式重试。
  目标结构冻结在首次加载；观察到外部修改后直到重开页面都保持失效，重试不能
  把新目标的凭据填入旧表单。目标、revision 或编辑生命周期变化时安全失败；
  不支持、用户取消、密钥失效和损坏状态均使用本 Feature 双语稳定文案。
- 保存点击和验证前核验冻结目标；进入提交后，由 ViewModel 比较该次原始结构与
  待提交结构。Editor 只提供同一 pair、revision 和 Route generation 的短期租约，
  使用户明确修改 host 的合法提交不会被自身结构写入误判为外部重绑。
- 密钥失效或密文损坏时，本阶段的恢复入口是删除连接后重新添加凭据；编辑页
  不提供绕过认证的关闭保护或明文回退，旧受保护记录仍由 Core 安全失败处理。
- 受保护保存只租用 Core opaque 密文 snapshot；失败时恢复它并补偿连接结构与
  Host Key，成功或失败后均释放租约。不会为回滚读取旧密码或私钥，也不会在
  认证失败时降级为普通明文保存。其它平台和未保护连接保留原有存储路径。
- 公共入口同时提供纯 Route metadata；App Shell 只聚合这些描述并在 Route Scope 创建
  ViewModel，不把 Widget 或 ViewModel 放入 Core。
- Full App 中旧 `features/connection/` 路径已完成零引用清理并删除；
  `apps/ssh_mobile_full/lib/app/connection_*_adapters.dart` 仍是保留的
  App Shell Port 适配边界，不属于旧业务实现。

## 公共入口

业务代码只能导入 `package:feature_connection/feature_connection.dart`，不能导入 `lib/src/`：

- `ConnectionViewModel`
- `ConnectionCredentialEditor`
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
