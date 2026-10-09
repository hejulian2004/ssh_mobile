最新更新时间：2026-10-09

# ssh_mobile_ssh

SSH-only App 是只组合直接 TCP SSH 的 Flutter App。它装配 `app_core`、
`app_ui`、`connection_core`、`ssh_core`、`feature_connection` 和
`feature_terminal`，用 `SshClientFactory` 打开原始 TCP 会话。它不创建
`NetworkRuntime`，也不依赖网络传输、LAN Share、SFTP、AI、RAG、MCP 或
WebView。

完整版 `ssh_mobile_full` 保持原有组合根，不从这里借用实现。

## 生命周期

- `SshOnlyAppRuntime` 持有 Connection 数据库、凭据仓储、直接 TCP SSH
  Manager 和 Logger；
- `SshOnlyAppState` 是可等待、幂等的 Widget Owner；退出时先卸载页面，再
  按 ViewModel → Terminal Module → SSH → 数据库 → Port → Logger 释放；
- `TerminalModule` 独占 `terminal.db`；Connection 结构由 `connection_core`
  的数据库持有，密码和私钥只进入安全存储；
- 未知 Host Key 必须经过页面确认，没有页面回调时拒绝连接；
- 配置了跳板主机的连接在打开 Socket 前失败，因为这个 App 没有跳板转发。

## 验证

```bash
flutter pub deps
flutter analyze
flutter test
```

`flutter pub deps` 输出中不应出现 `network_transport`、`network_sdk`、
`ssh_mobile_network_native`、`feature_lan_share`、`feature_sftp` 或
`feature_ai`。

## 覆盖率排除

下列入口没有独立业务分支，widget 测试不执行它们。原因是它们会打开平台
数据库、安全存储或调用 `runApp`。排除只覆盖进程入口，不覆盖连接、终端
或 Host Key 行为。

- `lib/main.dart`：两行委托给 `SshAppBootstrap.run`，与 Full App 入口一样
  用 `coverage:ignore` 标记。
- `lib/app/ssh_app_bootstrap.dart`：绑定 `WidgetsFlutterBinding`，调用
  `SshOnlyAppRuntime.create()`，再 `runApp`。Zone 只在运行时已经存在时
  记录未捕获错误。
- `SshOnlyAppRuntime.create()`：打开平台 Connection 数据库和 Flutter
  安全存储。`forTesting` 覆盖释放顺序，以及单项清理失败后继续释放。

## Package contract

- 职责：提供只使用直接 TCP 的 SSH 连接编辑和终端会话。
- 不负责：网络传输运行时、LAN、SFTP、监控、AI 或 Full App 的后台 SSH。
- Public API：`SshOnlyAppRuntime`、`SshOnlyTerminalCapability` 及应用入口。
- 依赖：`app_core`、`app_ui`、`connection_core`、`ssh_core`、
  `feature_connection`、`feature_terminal`、`dartssh2` 和 Flutter SDK。
- 数据库：`TerminalModule` 拥有 `terminal.db`；Connection 数据库由
  `connection_core` 拥有。
- 生命周期与资源 Owner：Runtime 负责 App Scope；Module 负责终端数据库；
  Route Scope 负责页面资源。单项清理失败仍继续释放后续 Owner。
- 测试命令：`flutter pub deps`、`flutter analyze`、`flutter test`。
