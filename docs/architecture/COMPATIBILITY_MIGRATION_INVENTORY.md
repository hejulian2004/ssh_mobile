最新更新时间：2026-09-07

# 兼容层迁移引用清单

本清单记录模块迁移期间仍然存在的旧 App `package:ssh_mobile/...` 引用。
引用基线由 `tool/compatibility_inventory.dart` 管理，
`dart run tool/compatibility_check.dart` 和 `tool/architecture_check.dart`
都会校验：迁移中的模块旧引用只能减少，已关闭的模块必须为零引用。

`apps/ssh_mobile_full/lib/app/*_feature_adapters.dart` 是正常的 App Shell
Port 适配边界，不属于删除目标。App Scope 的基础设施和仍被多个 Feature
使用的协议后端也不因这份清单而复制或提前删除。
只有清单明确列出的 App Shell adapter 才允许被 `apps/*/test`
直接导入以验证边界行为；这些引用不计入旧入口基线，命令行报告会
将其作为 `approved adapter-test refs` 单独显示。

本清单只统计旧 App import/path compatibility 引用，不表示 LAN Control 或 Native
Network V2 的 wire/pairing/storage 重构已经完成。LAN Share 当前遵循
`ADR-032-lan-control-v2-breaking-refactor.md` 的 breaking-only 约束：旧 pairing
schema、`pending_remote` 和 `/api/lan/upload` 的删除由该 ADR 的专项验收负责，不能
以本表的“旧 App 路径已关闭”代替。

屏幕共享的 `realtime_media` 是新增的 Infrastructure 生命周期契约，不是旧 App
路径兼容层：此前 `network_sdk` 中的合成 `remoteVideo` 帧占位 API 已在 Phase 2
删除，替换为绑定 `(realtimeId, peerId, generation, direction)` 的不透明 native
endpoint。没有保留帧流别名、降级路径或旧导出。

| 模块 | 唯一 Package Owner | 旧引用基线 | 状态 | 保留的 App Shell 边界 | 删除条件 |
| --- | --- | ---: | --- | --- | --- |
| Connection | `feature_connection` / `connection_core` | 0 条 / 0 个文件 | 已关闭 | `connection_feature_adapters.dart`、`connection_runtime_adapters.dart` | 旧 Connection Feature 路径已删除；仅保留 App Shell Port 适配器 |
| Terminal | `feature_terminal` | 0 条 / 0 个文件 | 已关闭 | `terminal_feature_adapters.dart`、`terminal_ssh_capability_adapter.dart`、Terminal history/metadata backend | 旧 Feature 路径、导出和测试已删除；App Shell SSH/历史后端保留至 method-level migration |
| SFTP | `feature_sftp` | 0 条 / 0 个文件 | 已关闭 | `sftp_feature_adapters.dart`、`sftp_backend_adapters.dart`、`sftp_io_backend_adapters.dart` | 旧 Feature UI/ViewModel/测试已删除；共享 SftpService/cache/protocol 后端保留为 App Shell 边界 |
| Monitoring | `feature_monitoring` | 0 条 / 0 个文件 | 已关闭 | `monitoring_feature_adapters.dart`、`system_admin_feature_adapters.dart`、diagnostics/probe backend | 旧 Performance service/tool 已删除；诊断后端只作为 App Shell adapter 保留 |
| System Admin | `feature_system_admin` | 0 条 / 0 个文件 | 已关闭 | `system_admin_feature_adapters.dart` | 旧页面、命令 facade、测试和 Feature 目录已删除 |
| LAN Share | `feature_lan_share` | 0 条 / 0 个文件 | 已关闭 | `lan_share_feature_adapters.dart` | 旧 LAN 路由、页面、测试、Service、Relay facade 和 Runtime getter 已删除 |
| Playbook | `feature_playbook` | 0 条 / 0 个文件 | 已关闭 | `playbook_feature_adapters.dart` | 旧 UI/service、AI 调用和测试已切到 Package API |
| RAG | `feature_rag` | 0 条 / 0 个文件 | 已关闭 | `rag_feature_adapters.dart` | 旧页面/service、AI 调用和测试已切到 `RagCapability` |
| Network | `network_transport` / `network_sdk` | 0 条 / 0 个文件 | 已关闭 | `network_sdk_adapters.dart`、LAN Network adapter、Network Protocol V2 codec/service/identity | Relay 业务 facade 已删除；Network Protocol V2 App Scope 后端仅通过 typed `network_sdk` contract 使用 |
| MCP | `feature_mcp` | 0 条 / 0 个文件 | 已关闭 | `mcp_feature_adapters.dart` | 不恢复旧 MCP 业务入口 |
| WebView | `feature_webview` | 0 条 / 0 个文件 | 已关闭 | `webview_feature_adapters.dart` | 不恢复旧 WebView 业务入口 |
| Developer | `feature_developer` | 0 条 / 0 个文件 | 已关闭 | `developer_feature_adapters.dart` | 不恢复旧诊断业务入口 |

基线只统计 Dart 的 `import`、`export`、`part` 指令；App Shell 对旧后端的
相对路径注入仍由各模块 README/AGENTS 和资源 Owner 清单管理。完成一个模块
后，先确认调用方、测试和生命周期测试全部切换，再把该模块的状态改为
`closed`，最后删除零引用旧入口并同步本文件和清单代码。
