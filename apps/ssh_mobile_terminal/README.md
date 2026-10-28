最新更新时间：2026-10-23

# ssh_mobile_terminal

Terminal-only App 是模块化编译裁剪验证用的最小 Flutter App。它只声明并
装配 `app_core`、`app_ui`、`connection_core`、`network_transport`、
`ssh_core` 和 `feature_terminal`，不会引入 Full App
的 AI、RAG、MCP、WebView、LAN Share 或 SFTP 依赖。

## 生命周期

- `TerminalAppRuntime` 持有 Connection、Network、SSH 和 Logger App Scope 资源；
- `TerminalOnlyAppState` 是可等待、幂等的 Widget Owner；退出时先卸载 Feature
  borrower，再等待 Runtime 屏障；同步 Widget teardown 触发同一个释放 Future；
- `TerminalModule` 独占 `terminal.db`，由 Runtime 在退出时释放；
- `TerminalFeatureScope` 只注入公开 Port，不拥有 App Scope 资源；
- 未选择的 Feature 不会创建数据库、初始化 SDK 或注册路由。

本 App 是依赖裁剪和生命周期验证切片。真实 SSH 连接实现仍由 Full App 的
App Shell 负责；Terminal-only 切片使用安全空 Capability 展示无会话状态，
避免为了验证编译图而复制第二套 SSH Owner。

## 验证

```bash
flutter pub deps
flutter analyze
flutter test
```

`flutter pub deps` 输出中不应出现 `feature_ai`、`feature_rag`、
`feature_mcp`、`feature_webview`、`feature_lan_share` 或 `feature_sftp`。

## Package contract

- 职责：验证最小 Terminal App Shell 的依赖裁剪和生命周期组合。
- 不负责：Full App 业务、真实 SSH 兼容实现或未选择 Feature 的初始化。
- Public API：`TerminalAppRuntime`、`TerminalFeatureScope` 及 App 的启动入口。
- 依赖：`app_core`、`app_ui`、`connection_core`、`network_transport`、`ssh_core`、
  `feature_terminal` 和 Flutter SDK。Connection 编辑 Feature 不属于此编译切片，
  连接数据通过 `connection_core` 公共契约注入。
- 数据库：只由 `TerminalModule` 拥有 `terminal.db`。
- 生命周期与资源 Owner：Runtime 负责 App Scope；Module 负责数据库；Route Scope
  负责 ViewModel 和页面资源。Runtime 清理单项失败仍继续释放后续 Owner，最后
  重新抛出第一个错误。
- 测试命令：`flutter pub deps`、`flutter analyze`、`flutter test`。

## Local development diagnostics

Runtime output and agent queries follow the [local diagnostic contract](../../docs/agent/runtime-diagnostics.md).
App composition roots inject `app_diagnostics` through public Core logging
contracts; Feature dependencies remain unchanged. Development tools own launched
processes and file queries, and are never imported by runtime packages.