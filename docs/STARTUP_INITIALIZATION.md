> 最新更新时间：2026-10-11

# 应用启动按需初始化架构 (On-demand Startup Initialization Architecture)

## 概述
为了大幅提升应用冷启动速度，降低 CPU/内存占用并减少未访问功能引起的后台 I/O 和网络开销，应用采用了**按需初始化架构（On-demand Initialization Architecture）**。

## 架构要点

### 1. 核心 Bootstrap (`AppBootstrapCoordinator`)
- `main()` 仅委托给 `AppBootstrap.run()`；`AppRuntimeFactory` 创建唯一的 App Scope 服务，`AppRuntime` 负责其生命周期，并发起 `AppBootstrapCoordinator.ensureBootstrap()`。
- `AppBootstrapCoordinator` 仅装载核心偏好（语言、主题、色板、SFTP 限制等）；Feature/Module Repository 按各自 Owner 惰性初始化，不再由统一存储门面承载。
- MCP Token 生成与平台设备名获取仍按具体功能触发；Network V2 的 App-owned
  `NetworkIdentityBundle` 由 AppRuntime composition root 的 `AppNetworkResources`
  在首次网络动作时加载/创建，并 single-flight 配置共享 `NetworkRuntime`/`NetworkFacade`；
  启动和事件订阅不触发密钥或原生句柄创建，LAN/SSH/Realtime 仍共享唯一 Owner。
- `AppBootstrap` 先挂载不依赖 Runtime 的轻量首帧壳，再异步等待完整
  `AppRuntimeFactory` 装配；Runtime 提交后在启动壳下挂载 `SshMobileApp`。这样数据库、Secure
  Storage、native capability 和 Telemetry 的启动 I/O 不会让 Android 原生 LaunchTheme
  长时间停留在黑屏；装配失败只显示不泄漏异常细节的启动失败态。
- 生产路径同步挂载轻量启动壳，再在后续 microtask 开始 Runtime 装配，不等待
  首帧 post-frame 或 rasterization；必要的异步 I/O 与首帧绘制重叠。同步重计算
  不应进入装配入口：网络能力按需初始化，密钥和 TLS 证书生成使用工作 isolate。
  启动壳显示应用标识与单个加载动画，不依赖 Runtime。
- Network Identity 的 Ed25519/X25519 安全存储读取并行执行，两个读取全部收敛后才
  在工作 isolate 派生密钥，再回平台 isolate 持久化；缓存、single-flight、读取失败
  重试和畸形密钥 fail-closed 保持不变。TLS 首次证书生成也使用工作 isolate。
- Android 已持久化 `powerGuideSeen` 时直接显示首页，不再为跳过电源引导等待一次
  post-frame 检查；首次引导仍保留系统状态查询与超时处理，查询期间也显示应用标识，
  避免 Runtime 交接后再次只显示转圈。
- 启动壳的同一个 Logo/动画保留到 `StartupScreen` 确认首页或电源引导就绪后才移除；
  Runtime 交接期间通过稳定的 Widget key 保留动画状态。准备中的 App 使用 Offstage
  隐藏并暂停其 Ticker，继续异步加载和电源状态查询，不显示或运行第二段加载动画。
- 启动页始终使用白底浅色 SVG Logo，不受用户深色主题影响；Logo 保持正方形和
  等比缩放，适配安全区、小窗口、横屏与大字号。Android 原生启动页同步白底，
  Android 12 的系统图标掩码额外保留内边距。

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
- `LanReceiverCoordinator` 管理全局 HTTPS 接收端口、mDNS 广播及配对邀请处理。
  Full App 在首次进入快传页面时激活接收，之后保持 App Scope 接收生命周期。
  全局配对宿主仅订阅事件，不主动初始化；遥测通过 `ensureRelayEnrollment()` 独立
  检查持久化 enrollment，不创建接收器、网络密钥或 TLS。
- Coordinator 只借用 AppRuntime 按需配置的共享 NetworkFacade；激活、停用和重新激活
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
- Feature 数据库装配与 LAN Module 注册在 Core 完成后并行执行，原生网络配置移到
  首次网络动作；共享 Facade 订阅和原生句柄分阶段释放，SSH
  后台事件桥和 tmux 恢复不再登记为启动 initializer，而由首次 SSH/Terminal 使用触发。
- Telemetry connectivity recovery 也在 Runtime 提交后后台启动，不阻塞首帧或 Runtime
  交接。
