最新更新时间：2026-10-12

# ssh_mobile_full

## 职责

Full App 是 SSH Mobile 的完整 App Shell 和组合根，负责启动协调、`AppRuntime`
生命周期、路由聚合、App Port 适配器以及兼容清单中明确保留的 App Scope 后端。

Network V2 的组合根约束：`AppRuntimeFactory` 创建 App-owned `AppNetworkResources`，
首次网络操作才加载/创建 `NetworkIdentityBundle` 并 exactly-once 配置原生
`NetworkRuntime` 和共享 `NetworkFacade`；事件订阅和诊断不触发初始化。LAN、SSH、
SFTP、Realtime 和 Relay 只借用这些 App Scope 资源；Feature
或 Route Scope 不得创建第二个 runtime/facade，也不得在 deactivate/reactivate 时
停止、销毁或重新配置它们。

## 不负责什么

新的 Feature 业务实现、跨 Feature 的 `/src/` 调用和第二套全局 SSH/Network Owner
不应继续放入本 App；新能力应进入对应的 Core、Infrastructure 或 Feature Package。

## Public API

App Shell 的稳定组合入口是 `lib/main.dart`、`lib/app/app_bootstrap.dart`、
`lib/app/app_runtime.dart` 和 `lib/app/navigation/`。外部调用方不得把旧
`lib/screens/`、`lib/models/` 或兼容 Service 当作新模块 API。

`AppBootstrap` 立即挂载 Logo 启动壳，并在后续 microtask 开始 Runtime 装配，
不等待首帧绘制或栅格化；异步 I/O 与首帧重叠，并保留同一个加载动画。
`SshMobileApp.onStartupReady` 在初始首页或电源引导完成首帧布局后通知启动壳移除
遮罩；准备期间 App 隐藏且暂停 Ticker，异步数据读取继续执行。该回调不转移 Runtime
资源所有权。

LAN 接收在首次打开快传页面时激活，随后由 Module 保持接收；启动时全局配对宿主
仅订阅事件。遥测只准备独立的 Relay enrollment 门禁，不初始化接收器。网络密钥
推导和 TLS 证书首次生成在工作 isolate 执行，安全存储读写仍使用平台 isolate。
首次网络激活完成后，组合根为 Realtime 接收适配器接入同一原生运行时的借用
gateway，确保从未主动共享过屏幕的设备也能收到邀请；冷启动订阅仍不初始化网络。

启动品牌资源为 `assets/app_icon.svg`：透明边缘、浅蓝面板、蓝色终端提示符和青绿色
光标。`StartupBranding` 使用 SVG 等比显示，按可用短边限制在 64–128 逻辑像素，
保留安全区和大字号滚动空间。Android 原生启动页使用同款 VectorDrawable，日间与
夜间启动底色均为白色。系统图标通过 `dart run tool/generate_app_icons.dart` 生成
各平台 PNG 和包含 16–256 像素图层的 Windows ICO；调整 SVG 形状或配色时须同步
生成器与 Android vector。启动页仍使用白底；iOS 的系统图标按平台要求保持不透明。

## 依赖

屏幕共享支持已配对设备的原生 Direct QUIC/TCP 信令，无需配置 Relay；入口先经
LAN 的身份钉扎能力查询与 peer-policy Owner 准备直连，再创建 Realtime session。
无可用 Direct 时保留 Relay Control 路径。邀请、接受与拒绝仍由用户明确确认，
画面仍走 native WebRTC，不能把共享信令送达当作真实 capture/render 验收。

Windows Full App 在 LAN 广播期间通过注入的 discovery Port 识别本机在线 Android
Emulator。ADB 从已配置 Android SDK、Android Studio 默认 SDK 或 PATH 解析；未安装
或不可用时保留普通 LAN 发现。适配器只创建/释放自己的 console UDP 发现映射、
TCP HTTPS 映射以及独立 TCP/UDP native 映射，不读取配对密钥、不操作已有 ADB
forward、不停止模拟器。Windows 和模拟器内 Android 都需要使用支持来源端口
PONG 的版本；仍需双向 PIN 配对和原生传输接收审批。
模拟器 NAT 可能改写 PONG 的回复源端口，适配器为每台模拟器保留独立的回环
请求/接收 socket，按接收通道绑定其映射，不按回包源端口关联模拟器。
真实设备映射核验入口为 `flutter test --no-pub test/manual/lan_emulator_mapping_smoke.dart`：
需要唯一在线的本地模拟器，使用临时 TCP/UDP 应答器并清理本次映射，不访问 App 数据。

依赖由本 App 的 `pubspec.yaml` 声明，包含 Flutter、Core/Infrastructure/Feature
Package 和 App Shell 直接使用的插件；Feature 实现不得通过 App `/src/` 反向获取依赖。

## 数据库

App Shell 只拥有独立的 `app_logs` 日志数据库。Connection、AI、Terminal、SFTP、
Playbook、RAG、MCP 和 LAN Share 数据库分别由对应 Core/Feature Module 拥有；不再创建
统一 `AppDatabase`。

## 生命周期与资源 Owner

`AppRuntimeFactory` 创建 App Scope 资源，`AppRuntime` 按依赖逆序释放 Module → Realtime
→ SFTP → SSH → Network → Database → Logger（适配器与 Route Scope 资源先于 Module
解除）；错误 handler bridge 与结构化 telemetry sink 在 TelemetryClient 关闭前
先恢复/排空。Route Scope 负责 ViewModel、Controller、Timer 与 Subscription。控制面由
`network_sdk` 的 typed client 使用 App Shell 注入的 `SdkRequestExecutor`，LAN 数据面
仍由 AppRuntime-owned native gateway/共享 `NetworkFacade` 负责。LAN Receiver 只关闭
自己的 HTTP/Discovery/Transfer 资源与订阅，不释放 NetworkRuntime/native handle。

LAN Control Protocol V2 和 Native Network Protocol V2 是独立版本域；LAN Control
breaking refactor 不保留旧 pairing schema、`/api/lan/upload` binary fallback 或旧
API compatibility wrapper。按本 ADR 的控制面决定，Feature-facing
`NetworkFacade.sendMessage` 保持 unavailable 边界，text/clipboard 由 Feature 走
authenticated HTTPS + application E2E。

后台 SSH 的平台前台服务与 isolate runtime 分属不同 Owner：
`BackgroundServiceManager` 只负责通知/权限/power lock/服务启停，后台入口点创建的
`_BackgroundSshRuntime` 独占 session registry、SSH/tmux、keepalive 和事件订阅；两者
不得共享 SSH client、shell 或 Timer。

前台 `SshService` 中，`_SshBackgroundEventBridge` 独占后台插件事件订阅，
`_SshSessionProjection` 独占不可变 session 列表与 connection overview 聚合；连接、
会话、命令和 history queue 仍由 `SshService` 拥有。前后台建连在登记到 session
registry 前由 attempt owner 持有，并以 per-session generation 阻止迟到回调覆盖新资源；
`SshService.close()` 会等待 connect/reconnect、后台 isolate 确认、订阅、runtime、history
queue、Session Pool 和 native stream connector 完成释放。Network V2 codec 是窄 facade，命令
编码与 Peer/Transfer/SSH Stream typed decoder 彼此独立；Realtime 使用自己的 native
protocol，不属于当前 V2 event schema。

System Admin 的 App Shell 组合按职责拆为 Port/Route 聚合、设置与本地化投影、
SSH 目标绑定与有界命令执行；后者返回 Route-owned Lease，并在取消、超时、输出超限
或目标代次变化时关闭全部局部 process/client，不关闭 App Scope SSH owner。

## 测试命令

```bash
flutter analyze
flutter test
```
