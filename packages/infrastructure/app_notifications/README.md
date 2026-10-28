最新更新时间：2026-10-28

# app_notifications

Android 与 Windows 系统通知的基础设施包。Full App 和 Network App 共用同一次插件初始化，Feature 不依赖本包。

## 依赖边界

本包只依赖 Flutter 和 `flutter_local_notifications`。它不依赖任何 Feature，也不读取聊天正文、文件路径或凭据。通知正文由 `notificationCopy` 生成；调用方传入的正文不会展示。

## 生命周期

每个进程使用 `AppNotificationCenter.shared` 初始化一次。Full App 身份是 `Hejulian.SSHMobile`，Network App 身份是 `Hejulian.SSHMobile.Network`。`present` 不会自行选择身份；宿主必须先用对应身份调用 `ensureInitialized`。

Android 消息使用 `ssh_mobile_messages`，文件申请使用 `ssh_mobile_transfer_requests`。SSH 前台服务渠道 `ssh_mobile_foreground` 和客户端工具渠道 `ssh_mobile_client_tools` 仍由各自 Owner 创建，不能覆盖这两个渠道的重要性。

点击载荷只包含版本、类型、peer id 和业务 id。导航未就绪时只保留最后一次点击。权限或插件失败记一条不含正文的诊断，并返回失败。

## Package contract

- 职责：系统通知初始化、渠道、脱敏文案、稳定通知 id 和点击队列。
- 不负责：局域网消息收发、文件审批、屏幕共享接受，或应用被系统杀死后的投递。
- Public API：`package:app_notifications/app_notifications.dart`。
- 依赖：Flutter SDK 与 `flutter_local_notifications`。
- 数据库：无。
- 生命周期与资源 Owner：App 组合根持有 `SystemNotificationScope`，并在进程内初始化共享中心。

## 验证

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、`flutter test --coverage`。
