最新更新时间：2026-10-22

# feature_terminal

Terminal Pilot 的独立 Feature Package。

## 边界

- `lib/src/domain`：终端模型、Repository 和 App/Infrastructure Port；
- `lib/src/data`：只属于 Terminal 的 Drift `terminal.db`；
- `lib/src/application`：Module 与路由级 ViewModel；
- `lib/src/presentation`：终端页面和专属 Widget。页面只读本包 ViewModel 和
  `app_ui`，不导入 `ssh_core`。

`TerminalFeatureScope` 是 Feature 自己拥有的 Provider 组合边界。App Shell
只注入 App Scope 的 `SshSessionManager`、Terminal Port 和历史 Repository；
Scope 不拥有这些资源，也不负责关闭 App 或 Module Owner。Terminal-only App
通过该公共 Scope 复用页面组合，不需要直接依赖 Provider 实现。

Terminal 不直接依赖统一存储门面、`AppSettings`、`SshService` 或其他
Feature；App 通过公开 Port 提供兼容适配器。旧 App 路径在迁移期间保留导出桥，
以便外部调用方逐步切换。
- `feature_terminal.dart` 暴露终端路由的纯 metadata；路由页面和 ViewModel 仍由
  App Shell 的 Route Scope 创建，Core 不持有 UI 实例。

终端元数据由 `TerminalModule` 独占的 `terminal.db` 保存；加密的原始输出历史
服务也已迁入本包，并由 App Shell 的 SSH Owner 注入数据保护与日志 Port。App
组合根只保留终端元数据的显式兼容适配器，不再通过统一存储门面双写/读取。

历史加载期间的实时输出和渲染背压队列均使用保留最新尾部的 UTF-16 安全有界
buffer，单个超大事件也不能绕过 200,000 字符上限。旧明文历史按 32 KiB 字符块
流式加密到同文件系统临时文件，完整 flush 后才原子替换原文件。

## 生命周期

`TerminalModule` 负责打开和关闭 `terminal.db`。Route Scope 负责创建页面
ViewModel；ViewModel 只拥有页面内 Controller、Subscription 和 Timer，不能
关闭 App Scope SSH Manager。

Module 初始化与销毁按 generation 串行收敛；销毁开始后，迟到 initializer 关闭
自己的局部数据库，不能重新发布 Repository、恢复 active 状态或复活已释放 Module。

## Package contract

- 职责：提供终端页面、交互 ViewModel、历史 Repository、`terminal.db` 和 Feature Scope。
- 不负责：创建/关闭 App Scope SSH Manager、统一存储门面或其他 Feature 实现。
- Public API：`package:feature_terminal/feature_terminal.dart`，包括
  `TerminalFeatureScope` 和路由 metadata。
- 依赖：`app_core`、`app_ui`、`ssh_core`、Drift、Provider、xterm 和终端 UI 直接插件。
- 数据库：`TerminalModule` 独占 `terminal.db`；原始输出历史按既有保护 Port 处理。
- 生命周期与资源 Owner：Module 负责数据库/Repository；Route Scope 负责页面
  ViewModel、Controller、Timer 和 Subscription；AppRuntime 负责 SSH Manager。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
