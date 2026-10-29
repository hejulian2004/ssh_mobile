最新更新时间：2026-10-29

# feature_sftp

SFTP 文件浏览、传输、预览、编辑和路径收藏 Feature。

## 边界

- `SftpModule` 独占 `sftp.db`、路径 Repository 和 Feature Service。
- `sftp.db` 只保存 recent paths、favorite paths 和必要的传输元数据，不保存密码、
  私钥或 Token。
- Android 上，App Shell 可以注入 `SftpDocumentAccessPort`，用系统文档选择器
  读写单个 content URI。上传和下载仍走现有路径 API，文档内容按块经过一次
  临时文件。其它平台继续使用路径选择器。远程目录不会出现在系统文件管理器里。
- 文档上传在打开选择器前保存连接 ID、目标指纹和目录快照，复制结束仍须一致；
  切换服务器、同 ID 改绑或切换目录会拒绝上传。文档暂存同一时间只允许一次，
  通过现有传输状态展示进度；取消和 Module 释放会主动关闭源/中止目标，
  进行中的操作在返回前等待这次清理。`SftpModule.dispose()` 等待
  `SftpService.close()` 排空文档操作后再关闭数据库，不关闭 App-owned 后端或 SSH。
  临时文件只保留这次尝试，成功、错误、取消和文档关闭失败都会收敛删除。
- Feature 通过 `SftpBackend` 使用 App Shell 注入的旧 SFTP 后端，并通过
  `ssh_core.SshSessionManager` 共享 App Scope SSH 初始化；Feature 不创建或关闭
  全局 SSH/SFTP 资源。
- 页面使用 Route-scoped `SftpViewModel`。页面关闭时解除监听；共享的旧
  `SftpService` 仍由 `AppRuntime` 持有，只能通过 App Shell backend adapter 注入。
- Module 初始化与销毁按 generation 串行收敛；销毁开始后，迟到 initializer 必须
  关闭自己的局部数据库且不能重新发布 Repository/Service 或改回 active 状态。
- 目录条目携带创建时的不可变 target fingerprint。预览、编辑、下载和删除必须
  与当前会话的 fingerprint 完全匹配；同一连接 ID 改绑主机后，旧页面 fail closed。
- Feature 日志不得传递远端路径、本地路径或底层异常文本；App Shell 只记录操作名、
  稳定错误码、非敏感计数和不可逆路径摘要。
- 公共入口提供 SFTP 路由的纯 metadata；App Shell 负责聚合并创建 Route Scope，Feature
  不依赖其他 Feature 的实现。

## 公共入口

只通过 `package:feature_sftp/feature_sftp.dart` 引用 `SftpModule`、
`SftpViewModel`、页面、模型和 Port。App Shell 的 Feature 适配器位于
`apps/ssh_mobile_full/lib/app/sftp_feature_adapters.dart`；仍共享的 native
后端仅通过 `sftp_backend_adapters.dart` / `sftp_io_backend_adapters.dart` 暴露。

## 验证

```powershell
flutter analyze
flutter test --no-pub
```

Drift schema 变化后，在本目录运行 `dart run build_runner build`，并提交生成的
`lib/src/data/database/sftp_database.g.dart`。

## Package contract

- 职责：提供 SFTP 浏览、传输、预览、编辑、路径历史和收藏。
- 不负责：全局 SSH/SFTP 连接、凭据存储或其他 Feature 的实现。
- Public API：`package:feature_sftp/feature_sftp.dart`，包括 `SftpModule`、页面、
  ViewModel、模型和 Port。
- 依赖：`app_core`、`app_ui`、`ssh_core`、Drift、Provider、SFTP/预览直接插件。
- 数据库：`SftpModule` 独占 `sftp.db`；只保存路径/传输元数据，不保存密码、私钥或 Token。
- 生命周期与资源 Owner：Module 负责数据库、Repository 和 Feature Service；Route
  Scope 负责 ViewModel；AppRuntime 负责注入的 SSH Manager 和兼容 Backend。
- 测试命令：`dart run build_runner build`、`flutter analyze --no-pub`、
  `flutter test --no-pub`。
