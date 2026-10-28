最新更新时间：2026-10-28

# app_notifications 维护约束

- Scope: Android `NotificationManager` 与 Windows WinRT Toast 的共享适配。Public API 只在 `package:app_notifications/app_notifications.dart`。不得依赖 Feature，不得导入 Feature `/src/`。
- 一个进程只初始化一次插件。`present` 在中心尚未由宿主初始化时返回 false，不能改用 Full App 身份补初始化。
- 通知正文、日志和载荷不得包含聊天正文、文件路径、凭据或未脱敏的展示名。诊断只记录失败种类和 `runtimeType`。
- SSH 前台渠道与客户端工具渠道的 id、重要性归各自 Owner。本包只提供创建渠道的入口。
- 点击队列只保留最后一次有效载荷，并在导航就绪后逐次交给宿主。宿主负责业务校验；本包不接受文件传输或屏幕共享。

## 验证（代码变更）

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、`flutter test --coverage`。新增手写生产文件保持独立测试。local aggregate CI 仅按用户明确要求运行。
