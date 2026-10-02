> 最新更新时间：2026-10-02

# 应用启动按需初始化架构 (On-demand Startup Initialization Architecture)

## 概述
为了大幅提升应用冷启动速度，降低 CPU/内存占用并减少未访问功能引起的后台 I/O 和网络开销，应用采用了**按需初始化架构（On-demand Initialization Architecture）**。

## 架构要点

### 1. 核心 Bootstrap (`AppBootstrapCoordinator`)
- `main()` 仅委托给 `AppBootstrap.run()`；`AppRuntimeFactory` 创建唯一的 App Scope 服务，`AppRuntime` 负责其生命周期，并发起 `AppBootstrapCoordinator.ensureBootstrap()`。
- `AppBootstrapCoordinator` 仅装载核心偏好（语言、主题、色板、SFTP 限制等）；Feature/Module Repository 按各自 Owner 惰性初始化，不再由统一存储门面承载。
- MCP Token 生成与平台设备名获取仍按具体功能触发；Network V2 的 App-owned
  `NetworkIdentityBundle` 则必须在 AppRuntime composition root 中先加载/创建，随后
  exactly-once 配置共享 `NetworkRuntime`/`NetworkFacade`，避免 LAN/SSH/Realtime 各自
  建立 identity 或 native runtime。
- `AppBootstrap` 先挂载不依赖 Runtime 的轻量首帧壳，再异步等待完整
  `AppRuntimeFactory` 装配；Runtime 提交后才切换到 `SshMobileApp`。这样数据库、Secure
  Storage、native capability 和 Telemetry 的启动 I/O 不会让 Android 原生 LaunchTheme
  长时间停留在黑屏；装配失败只显示不泄漏异常细节的启动失败态。

### 2. ConnectionViewModel 与 SshService 解耦 (`ConnectionRuntimeActions`)
- `ConnectionViewModel` 构造函数仅依赖 `ConnectionRepository`。
- `SshService`、`SftpService`、`PerformanceMonitorService` 改为通过 `ConnectionRuntimeActions` 惰性工厂访问。
- `SshService` 构造函数保持轻量，不直接启动后台事件监听与 tmux 会话恢复；通过 `ensureInitialized()` 按需初始化。

### 3. Feature Scope 隔离
- `SystemAdminFeatureScope` 在页面路由层级为模块提供局部 ViewModel 作用域。
- `SftpViewModel` 自 2026-08-03 起由应用根提供（SFTP 页、编辑/查看路由与设置路由共享一个稳定实例）；页面级 `SftpFeatureScope` 已移除。
- 根级 `MultiProvider` 不再放置未访问页面的重型 ViewModel。
- 移除了 Home 页切换时 SFTP 对 `SystemAdminViewModel` 的跨模块强行读取。

### 4. LAN 后台接收器分离 (`LanReceiverCoordinator`)
- 提取 `LanReceiverCoordinator` 管理全局 HTTPS 接收端口、mDNS 广播及配对邀请处理，保持后台配对功能完备。
- Coordinator 只借用 AppRuntime 已配置的共享 NetworkFacade；激活、停用和重新激活
  只改变 LAN HTTP/Discovery/Transfer 资源与订阅，不 start/stop/reconfigure native
  NetworkRuntime。显式 unpair 才触发 `removePeer`，网络离线不会删除 Trust。
- `LanShareFeatureScope` 按需取得 Coordinator 持有的唯一共享 `LanShareViewModel`，主页面、全局配对路由与聊天路由复用同一底层运行时，不会重复绑定端口。
- `LanShareViewModel` 仅在用户进入 LAN Share 页面或收到配对邀请时创建，主动扫描与历史记录数据库 watch 不进入核心启动路径。

### 5. MCP 工具图惰性构造 (`LazyAiToolExecutor`)
- `McpServerController` 在已启用模式下自动监听端口，但注入 `LazyAiToolExecutor` 代理。
- 首次收到 `tools/list` 或 `tools/call` JSON-RPC 请求时，才首次触发全量 `AiToolService` 依赖图及底层服务的构造。

### 6. 条件生命周期与导入刷新
- 移除首帧后固定 900ms 的全局后台服务预热 Timer。
- 规范配置导入（Import）回调，等待所有已注册系统的异步刷新完成后才返回。

### 7. Runtime initializer Owner 与失败回滚
- `AppRuntimeInitializationOwner` 先惰性登记非阻塞 initializer，只在完整 Runtime
  所有权提交后统一启动；构造中途失败不会留下访问待释放数据库的后台任务。
- Owner 为已启动任务提供 cancellation signal，逆序调用可取消 initializer，并以
  3 秒屏障等待收敛；超时后关闭诊断入口，迟到错误不得访问已经释放的 Logger。
- 正常 `AppRuntime.dispose()` 仍先等待已提交 initializer，再按 Adapter → Module →
  Realtime → SFTP → SSH → Network → Database → Logger 逆序释放。
