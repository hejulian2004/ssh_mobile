最新更新时间：2026-10-22

# 行为边界

修一个已命名功能的 bug 时，只读该功能的卡片和卡片点名的下一层。本文是阅读路由和前向依赖合同。包级 DAG、资源创建/释放、兼容引用基线仍分别由 [模块依赖](MODULE_DEPENDENCY.md)、[资源 Owner](RESOURCE_OWNERSHIP.md)、[兼容清单](COMPATIBILITY_MIGRATION_INVENTORY.md) 维护。

## 停止规则

1. 先命名用户可见症状，命中一张卡片，只读该卡片的第一路径和它写明的借用层。
2. 呈现问题停在页面和本领域 ViewModel。跨层症状才打开 App Port 适配器。契约的形状、错误、生命周期或所有权变了，才打开提供方领域。
3. 同一连接上终端正常、文件列表失败：读 `feature_sftp` 和 `apps/ssh_mobile_full/lib/services/sftp/`。局域网和 SDK 不在这条链上。
4. 局域网能配对但文件不过：读局域网卡片里的 Native transfer 协调，再按网络链下钻。SSH 不在这条链上。
5. 屏幕共享按症状拆开：同意和超时停在 `feature_screen_share`；进路由、抢占、释放停在 App `screen_share_*.dart`；黑屏、尺寸、采集停在 media coordinator 和平台插件。
6. 管理台数字先分清 Front 查询参数和 Admin/Telemetry 聚合。设备在线状态才进入 Relay。
7. 卡片没有覆盖的新行为，先补卡片再改代码。少读文件不能成为合并 Owner 的理由。

## 五层

每一层只认识紧邻下一层的公开契约。

| 层 | 拥有 | 前向依赖 | 越层时停住 |
| --- | --- | --- | --- |
| 1. 呈现 | Widget、Route、本页 Controller、局部 UI 状态 | 本领域 ViewModel，以及 `app_ui` | 领域服务、数据库、`ssh_core`、`network_sdk`、socket、FFI |
| 2. 业务应用 | Module、Service、Repository、状态机、本领域数据库 | 本领域端口，加上下面该领域的相邻模块 | 传输实现、native、Relay、其他业务包的 `/src/` |
| 3. App 组合根 | `AppRuntime` / Factory、Port 适配器、路由聚合、进程级身份和门面 | 业务包公共入口，以及这些入口要注入的相邻实现 | 在适配器里新增业务规则；让业务包看见 native |
| 4. 基础设施运行时 | SSH Pool、NetworkFacade/Runtime、native handle、Rust 的 peer、path、crypto、Delivery、Transfer、Realtime | 紧邻的协议或平台插件 | Feature 页面、Relay 业务库、Admin 会话 |
| 5. 控制面 | Relay 设备/在线/预约、Admin 鉴权、遥测入库、React 管理台 | 紧邻的那一个版本化 HTTP、内部管理 API 或 wire 契约 | Flutter Feature、SSH 会话、E2EE 明文；Admin 进入 Relay 存储 |

跨层只有三种交互：

1. **Port 注入。** App 适配器把 App 资源翻译成 Feature Port。适配器认识两侧，业务判断留在 Feature。
2. **Lease / 订阅借用。** Feature `acquire` 之后只 `release` 自己的 Lease，或取消自己的订阅。
3. **意图契约。** Feature 经 `network_sdk` 提交连接、传输、Realtime 意图。路径、套接字、SDP/ICE、FFI handle 停在 App 适配器之下，Rust 才执行。

四个组合根各管自己的进程资源：

- `apps/ssh_mobile_full` 拥有唯一生产 `NetworkFacade`、唯一 `SshSessionManager` 和全部 Feature。
- `apps/ssh_mobile_ssh` 做直连 TCP SSH，不创建 `NetworkRuntime`。
- `apps/ssh_mobile_network` 只组合 `feature_lan_share`，自有 `NetworkRuntime`，不创建 `NetworkFacade`。
- `apps/ssh_mobile_terminal` 只组合终端，不加载连接编辑器，也不实现 AI、RAG、MCP、WebView、LAN、SFTP。

控制面 HTTP（Bootstrap、注册、遥测、Admin）和 native 数据面分开。Relay 做认证后的不透明转发，不拥有 ConnectionSession 或 E2EE。LAN Control V2（发现、配对、能力、控制 HTTPS、文本/剪贴板）和 Native Network V2（peer、session、Direct/Relay、E2EE、二进制传输、Realtime）是两个版本域。

## 前向依赖

业务领域是一张能力卡片对应的包，不是 App 组合根。依赖只指向更稳定的下一层，可以同时指向该层的多个模块。跳过中间层就是违规，即使包级 DAG 没有环。

```text
呈现 → 应用 → 领域端口
                ├→ app_core / app_ui / connection_core
                ├→ ssh_core
                └→ network_sdk

App 组合根 → 业务包公共入口 + 该入口要注入的相邻实现
network_transport → ssh_mobile_network_native → Rust network_core → protocol
Relay → protocol
Admin → Relay 的 /internal/v2 管理客户端
Front 页面 → Front API client → Admin HTTP
```

领域内部同样只依赖相邻层：

```text
presentation → application → domain ports
application → 本领域 data
data → domain 模型
```

| 业务领域 | 允许的前向模块 | 越层目标 |
| --- | --- | --- |
| 连接档案 | `app_core`、`app_ui`、`connection_core` | `ssh_core`、网络包 |
| 终端、监控、系统管理、Playbook | `app_core`、`app_ui`（监控没有这包）、`connection_core`（只用档案时）、`ssh_core` | `dartssh2`、`network_sdk`、`network_transport`、native、Relay |
| SFTP | 上一行，再加本包 `SftpBackend` | 页面直接使用 `SftpService`；包依赖 `dartssh2` |
| AI | `app_core`、`app_ui`、`connection_core`、`ssh_core`，以及 `feature_playbook` 的公开 `PlaybookAutomationPort` | `feature_playbook/lib/src`、WebView 实现、网络传输 |
| RAG、MCP、WebView、开发者诊断 | `app_core`、`app_ui`，加各自注入端口 | SSH 池、网络运行时、其他 Feature |
| 局域网共享 | `app_core`、`app_ui`、`network_sdk` | `network_transport`、native、`ssh_core`、`feature_screen_share` |
| 屏幕共享 | `app_ui`、`network_sdk` 的会话元数据 | `realtime_media`、native、SDP/ICE、传输门面 |

组合根是唯一同时看见「业务公共入口」和「该入口相邻实现」的层。`ssh_mobile_full` 和 `ssh_mobile_network` 可以依赖 `network_transport` 来注入门面。`feature_lan_share` 的网络边停在 `network_sdk`。native 绑定只属于 `network_transport` 的下一层。

`feature_ai` 到 `feature_playbook` 是唯一登记的横向端口，只走公开 `PlaybookAutomationPort`。新的业务包依赖另走架构评审，默认不加。

### 现有跳跃

已登记的跳跃已经收口。终端页面只读本领域 ViewModel，不导入 `ssh_core`。局域网页面只读本领域 ViewModel，发现地址和传输结果留在应用层，页面不导入 `network_sdk` 或 `LanDiscoveryService`。新的越层依赖由 `business-forward-dependency` 拒绝，不能把这里当作可以模仿的边界。

## 同名概念

| 词 | 含义 | Owner |
| --- | --- | --- |
| Connection | 保存的主机档案 | `connection_core` 持有数据和凭据契约；`feature_connection` 持有编辑页 |
| SSH Session | 到一台主机的 shell/SFTP 通道 | `ssh_core` 的 Pool；Feature 只持 Lease |
| ConnectionSession | 一条网络传输上的安全会话 | Rust；断线即销毁，业务恢复交给 Delivery/Transfer |
| Realtime session | 一次屏幕共享的会话租约 | App `AppScreenShareSessionLease` 借用 SDK；Feature 不持有 |
| Admin session | 管理员登录 | `relay/internal/admin` |
| Route（Flutter） | 页面路由 | App `ssh_mobile_app_routes.dart` 聚合 Feature metadata |
| Route（网络） | Direct 或 Relay 路径是否可用 | Rust `PeerPathManager`；Dart 只看到授权后的 eligibility |
| NetworkRuntime | 进程内 native 运行时 | Full App 的 `AppRuntimeFactory` 一份；Network App 另有自己的一份 |
| NetworkFacade | 业务门面 | 只有 Full App 创建；Feature 借用 |
| Trust | 配对后的持久信任记录 | `feature_lan_share` 的 TrustStore |
| Discovery | 当前是否看得见设备 | LAN Receiver；丢失端点不删除信任 |
| Relay enrollment | 本机是否注册到中继 | `LanRelayCoordinator`；不改写任何 peer 的信任 |

`removePeer` 只表示显式解除配对。发现超时、Relay 断开、路由变化、Feature deactivate 都不调用它。

## App 壳

这些行为留在 Full App。修它们时从下表进入，不从 `packages/features` 进入。

| 行为 | 第一阅读路径 | 停止线 |
| --- | --- | --- |
| 启动、首屏、冷启动监听 | `apps/ssh_mobile_full/lib/features/startup/`、`lib/app/app_bootstrap.dart`、[启动设计](../STARTUP_INITIALIZATION.md) | 冷启动监听不初始化密钥和 native handle；第一次网络动作才配置 Runtime |
| 主页服务器列表、设置面板 | `lib/features/home/`、`lib/features/settings/`、`lib/services/app_settings.dart` | 设置不拥有连接库、SSH 或网络运行时 |
| 进程生命周期、日志库 | `lib/app/app_runtime.dart`、`lib/services/app_log_*` | `app_logs` 是唯一 App 自有诊断库；业务库归各自 Feature 或 Core |
| 前台服务 / 后台 SSH isolate | `lib/services/background_service.dart`、`lib/services/ssh/` | UI isolate 管通知、权限、电源锁；后台 isolate 管自己的会话登记。这和 `ssh_core` Pool 是两套对象 |

`apps/ssh_mobile_full/lib/services/` 只放 App 基础设施、Port 适配器和已登记的协议后端。新业务进对应 Feature、Core 或 Infrastructure 的公共入口。分类见 [App Shell Services](../../apps/ssh_mobile_full/lib/services/README.md)。

## 客户端功能

| 功能 | 呈现与应用 | 存储 | 向 App 借什么 | 下一层才打开 |
| --- | --- | --- | --- | --- |
| 连接档案 | `feature_connection`；数据契约在 `connection_core` | `connection_core` 的连接库；凭据在安全存储。Feature 不拥有数据库 | 无网络运行时 | 症状是保存后的 SSH 握手时才读 `ssh_core` |
| 终端 | `feature_terminal` 的 presentation / application / domain / data | `TerminalModule` 独占 `terminal.db`；加密原始历史在本包 | `SshSessionLease`；历史保护 Port | 连接建立、后台事件、会话代数才读 `lib/services/ssh/` 和 `ssh_core` |
| SFTP | `feature_sftp` | `SftpModule` 独占 `sftp.db`，只存路径和传输元数据 | `SftpBackend` 接到 App `SftpService`；SSH Lease | 目录列表和上传下载字节才读 `lib/services/sftp/`，经 `sftp_*_adapters.dart` |
| 监控 | `feature_monitoring`；展示由调用方组合 | 受限内存窗口；没有 `monitoring.db` | SSH 命令 Lease | 采样阈值和健康分在本包的 Sample Store / Alert Evaluator |
| 系统管理 | `feature_system_admin` | 不创建数据库；实时快照不落 `system_admin.db` | SSH 命令 Lease | 监控采样实现留在 `feature_monitoring` |
| Playbook | `feature_playbook` | `PlaybookModule` 独占 `playbook.db`；敏感字段加密 | SSH Lease | AI tool loop 留在 `feature_ai` |
| AI | `feature_ai` | `AiModule` 独占 `ai.db`；敏感字段写入前加密 | SSH、WebView、日志、保护存储端口；Playbook 只走公开端口 | `feature_playbook` 的公开入口；其 `/src/` 不在阅读链上 |
| RAG | `feature_rag` | `RagModule` 独占 `rag.db` 和有界缓存；库内只有元数据 | 设置、日志、API Key 端口 | AI 检索走 `RagCapability`；tool 执行器留在 `feature_ai` |
| MCP | `feature_mcp` | `McpModule` 独占 `mcp.db` | 本地工具 Port | 释放的是 MCP HTTP Server 和审批队列，然后才是本库 |
| WebView | `feature_webview` | 不拥有数据库，不把页面正文写入持久化存储 | App 注入的安全策略；会话控制器由 AppRuntime 持有 | AI 编排留在 `feature_ai` |
| 开发者诊断 | `feature_developer` | 不拥有数据库；展示注入的脱敏状态 | 日志和遥测 Port | Relay 设备库不在这条链上 |
| 局域网共享 | `feature_lan_share` | `LanShareModule` 独占 `lan_share.db`；密钥和 Token 在安全存储 | 借用 Full App 的 `NetworkFacade`；控制 HTTP 由 App 注入 | 路径、E2EE、二进制传输失败才下钻 SDK。屏幕共享包不在本包依赖里 |
| 屏幕共享 | `feature_screen_share` 拥有同意、超时和业务状态。入口、仲裁、路由、会话租约、媒体协调在 `apps/ssh_mobile_full/lib/app/screen_share_*.dart` | Feature 不存媒体帧 | `LanShareScreenSharePort`、SDK Realtime、`realtime_media` 不透明端点 | 平台采集在 `realtime_media_android` / `realtime_media_windows`。TURN 凭证颁发才读 `relay/internal/relay/turn_credentials.go` |

终端按键、渲染、历史停在 `feature_terminal`。SFTP 页面、路径收藏、目标指纹校验停在 `feature_sftp`。两边的字节和连接生命周期仍在上表的 App 后端，那是兼容边界，不是新功能的落地处。

## 网络与 SDK

网络症状沿这条链下钻，命中一层就停。

```text
Feature 意图
  → network_sdk（NetworkFacade：register / connect / transfer / realtime）
  → App 适配器（apps/ssh_mobile_full/lib/app/network_sdk_adapters.dart、realtime_feature_adapters*.dart）
  → network_transport（门面和 native handle）
  → ssh_mobile_network_native（FFI 编解码）
  → native/network_core（socket、加密、路径、Delivery、Transfer、Realtime）
```

| 症状 | 停在 | 再下一层的条件 |
| --- | --- | --- |
| 按钮、同意、列表、文案 | 对应 Feature 的呈现层 | 症状涉及真实连接或传输结果 |
| 未注册就去连接，或解除配对删错了记录 | `network_sdk` 与 LAN Trust/Registry | Rust 路径状态和 Dart 意图不一致 |
| Full App 重复 configure、退出顺序、身份束 | `lib/app/app_runtime_factory*.dart`、`app_network_resources.dart` | Feature 业务状态本身错了才回到 Feature |
| 命令/事件字段、tag、信封 | App `lib/app/network/*codec*` 与 native protocol；以 `protocol/` 和生成契约为准 | Feature 只提交意图，不解析 wire |
| 候选路径、Relay 回退、会话销毁后能否续传 | `native/network_core/crates/network-core/src/connect`、`peer`、`delivery`、`transfer*` | Flutter 页面只在投影错了时才回看 |
| 屏幕视频帧、采集、编解码 | `network-webrtc`、`realtime_media*`、App `screen_share_media_coordinator.dart` | 未同意就开始采集时才回 `feature_screen_share` |
| 中继只转发、不解密 | `relay/internal/relay` 与 [Relay V2 契约](../../protocol/RELAY_V2_CONTRACT.md) | Admin 和 Front 只在管理 API 的字段变了时打开 |

`apps/ssh_mobile_full/lib/services/network/` 是 App Scope 的 V2 协议调用面。`network_transport` 拥有 Runtime/handle 门面。TCP、UDP、QUIC、WebShare 的协议实现留在它们现在的 Owner，不在这个目录里再写一遍。

## 服务端与管理台

| 行为 | Owner | 相邻交互 | 再下一层的条件 |
| --- | --- | --- | --- |
| 设备注册、在线、控制通道、Relay 数据预约 | `relay/cmd/relay`、`relay/internal/relay` | 设备走 V2 wire；管理走 `/internal/v2/*` | `internal/admin` 有独立导入隔离，管理逻辑留在 Admin |
| 管理员登录、设备目录、吊销、接入令牌 | `relay/cmd/admin`、`relay/internal/admin` | 只经 `RelayManagementClient` | Relay 设备库和签名密钥留在 Relay |
| 遥测入库、策略、保留 | `relay/internal/telemetry` | 设备 `/api/v1/telemetry/*`，管理 `/api/admin/v1/telemetry/*`，独立 Analytics 库 | 事件不写入 Relay 设备库 |
| 管理台页面 | `front/src` 的页面、feature 组件、`components/ui.tsx` | TanStack Query 持有服务端状态；组件走 Front API client | 接口字段变化才打开 Admin handler。呈现规则见 [Front UI 架构](FRONT_ADMIN_UI_ARCHITECTURE.md) |
| 客户端埋点产生 | `packages/core/app_core` 的 TelemetryClient；目录在 `contracts/telemetry/` | 有效 Relay 注册确认后才记录；`uploadEnabled=false` 只暂停上传 | 埋点不写入业务库或 `app_logs`。设计见 [数据埋点架构](../数据埋点架构.md) |

## 尚未收口的缝

移动这些代码需要单独的重构任务。读 bug 时把它们当成已登记边界。

1. **SSH 双运行时。** `ssh_core` Pool 与 App `SshService`、后台 isolate 并存。终端方法面迁移完成前保留 `SshService`。
2. **SFTP 双层。** Feature 拥有页面和 `sftp.db`，字节传输仍在 App `SftpService`。收口后 Feature 只看见 Port，传输 Owner 保持一个。
3. **协议编解码在 App。** `lib/app/network/*codec*` 与 native protocol 包并存。后续只改生成输入和对应 typed mapper。
4. **主页和设置仍在 App。** 它们是壳。拆包另开任务。
5. **屏幕共享按 Owner 拆文件。** 新逻辑落入现有的 lease、media、arbitration、incoming host，不合成一个总控对象。
6. **静态定位器。** 已登记的只有 `AppLogService.instance`、`ClientSystemToolService.instance`、`ClientWebViewService.instance`、`DataProtectionService.instance`、`NativeMemoryService.instance`。新代码走注入。

后续约束重构的顺序：依赖检查已经拒绝新的越层边，已登记的呈现层跳跃已经收口。最后才考虑主页和设置是否独立成包。
