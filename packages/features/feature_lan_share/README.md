最新更新时间：2026-09-12

# feature_lan_share

LAN Quick Share 的独立 Feature Package。当前开发阶段只接受破坏性的
`LAN Control Protocol V2`：负责设备发现、配对、capabilities、authenticated
control HTTP、WSS Relay enrollment/编排、Web Share、传输历史和非秘密配对元数据。
二进制附件只有 Native `Network Protocol V2 Transfer` 一条正式数据面；按照 V2 控制面
决定，文本和剪贴板使用 authenticated HTTPS + application E2E。

## 边界

- 只通过 `app_core`、`app_ui`、`network_transport`、`network_sdk` 及本包定义的
  Port 使用 App 设置、日志、数据保护、网络和 Relay 能力；`network_sdk` 只提供
  Flutter 客户端契约和 canonical 网络模型，不拥有传输实现；本 Feature 不再维护
  本地网络模型桥接。
- `LAN Control Protocol V2` 与 Native `Network Protocol V2` 版本域独立。LAN Control
  不得推动 Native wire schema 升级或恢复旧 V1/V2 双栈、旧 pairing migration、
  compatibility adapter 或 HTTPS binary fallback。
- 不依赖 SSH、其他 Feature 的实现或 App 的 `/src/` 路径。
- `LanShareModule` 独占 `lan_share.db`、历史 Repository 和接收器资源；App
  Shell 创建并注入 App Scope NetworkIdentity、NetworkRuntime 和共享 NetworkFacade，
  只负责配置是否激活接收器。
- LAN 的可信在线设备卡片可以通过注入的 `LanShareScreenSharePort` 发起
  screen-share secondary action。该 Port 只表达 `canShareWith`、
  `canReceiveScreenShareFrom` 和 `startScreenShare`；LAN Feature 不导入
  `feature_screen_share`，也不创建 Realtime session 或路由。
- `canReceiveScreenShareFrom` 是 incoming global host 的独立 trust/self/
  platform capability，不得用 outgoing `canShareWith` 代替。
- `LanReceiverCoordinator` 负责 LAN listener、discovery、pairing 和 ViewModel
  生命周期，借用 AppRuntime 的共享 Facade；它不得创建、启动、停止、释放或重新
  配置 NetworkRuntime/native handle。其内部 `LanRelayCoordinator` 独占 enrollment、
  credential refresh、Relay 事件订阅和有限重连状态机，只借用 App Shell 注入的
  Facade，并通过纯 Dart `LanRelay*Port` 借用 endpoint、日志、enrollment 和 capability，
  绝不停止或释放 App Scope Runtime。
- Trust、Discovery、Reachability、Route Availability 和 Relay
  Enrollment/Authorization 是五个独立状态域。Trust Record 只保留完整双向凭据和
  pinned identities；Discovery endpoint 与 runtime-generation native port 只保留在
 运行时快照。Local PIN trust 默认只有 `localDirect`，Relay authorization 必须显式
  授予并独立于本机 Relay enrollment。
- 数据库只保存传输历史和不含密钥、Token 的配对元数据；密钥、PIN、Bearer
  Token 和 Relay 凭据继续由安全存储边界管理。
- Native/WebShare 控制请求使用一次性租约，pending 与 active 共用并发上限；
  重放、重复元数据和中途失败都不得留下无 owner 写入。桌面导出通过
  目录选择和流式复制完成，不整体加载大文件。
- TLS context 与静态 X25519 密钥首次创建为单飞操作，TLS cache 绑定唯一
  device ID；所有 LAN 客户端端点用结构化 URI 构造、固定证书并关闭自动重定向。
  重复广播会先收敛旧 mDNS/UDP owner，旧 socket 回调不得读取新代次数据。
- LAN HTTPS 控制端点与 native QUIC/TCP 文件端点使用独立端口。Receiver 让 native
  绑定系统分配端口，再通过 mDNS/UDP、受认证 capabilities 和新二维码字段发布；
  发送端不得把 `LanDiscoveredPeer.controlPort`（HTTPS）复用为 native 文件传输端口。
- 每一代 Receiver native runtime 在发布 native 端点前，必须从安全存储恢复所有
  仍有效且同时具备 32 字节 Network Identity/X25519 公钥的配对对端；缺失或畸形
  记录 fail closed，不得注册或覆盖 pinned identity；需要新一轮受认证 V2 pairing。
  配对成功由 Coordinator 主动刷新并注册，不依赖 LAN 页面是否已创建。
- `LanNativePeerRegistry` 是唯一的 Trust → `registerPeer` / 显式 unpair →
  `removePeer` 同步 Owner。Trust restore 使用 `endpointAddress=''`；Discovery
  只更新动态 direct endpoint，离线或 route loss 不删除 trust。Coordinator 持有
  稳定的传入文件 offer 广播流，并在 Facade 代际变化时替换其内部订阅；UI 不绑定
  某一代 native runtime。
- 二进制 image/video/audio/file 统一使用 Network V2 Transfer；不提供
  `POST /api/lan/upload` 或 HTTP binary fallback。按照 V2 控制面决定，已配对的文字和
  剪贴板使用 authenticated HTTPS + application E2E，不提供明文或逐消息加密开关。
- Relay 设置页只接收当前会话的 enrollment Token；Token 不进入偏好设置、数据库、
  日志或导出。Relay origin 可持久化，但更换 origin 会先断开旧 socket 并清除旧
  enrollment。原生层只保持一个 Relay socket，直连优先、Relay 兜底；断线按
  服务端 `retry_disposition` 重连（`retryAfter` 用建议秒数、`credentialExpired`
  静默刷新凭据、`noRetry`/`identityConflict` 终止），默认 `1/2/4/8/16/30` 秒
  指数退避最多六次，传输历史记录实际的 Direct/Relay 路线。
- Wave 1 中唯一的数据面配置仍走现有 `ConfigureRuntime`，该入口会无条件初始化直接
  QUIC/TCP 基础设施；QUIC-free WSS-only 数据面路径推迟到后续协议能力切换（Wave 2），
  当前并不存在。`NetworkCapability.runtime` 只表示 native command-worker handle
  存在，不代表 WSS 数据面已独立配置。

旧 `apps/ssh_mobile_full/lib/features/lan_share/**`、
`apps/ssh_mobile_full/lib/services/lan_share/**`、V1 pairing/trust helpers 和 Relay
facade 已删除；App Shell 只保留 `lan_share_feature_adapters.dart`、LAN Control V2
HTTP/identity adapters 以及 Native Network V2 的共享 facade 借用边界。当前 LAN
Control 只暴露 V2 pairing/upload contract。

## Package contract

- 职责：提供 LAN Control V2 发现/配对/capabilities/control HTTP、WSS Relay
  enrollment/状态、Web Share 和传输历史；二进制数据面只消费 Network V2 Transfer。
- 不负责：SSH、其他 Feature 实现、App `/src/`、未审批的网络写入或秘密持久化。
- Public API：`package:feature_lan_share/feature_lan_share.dart`，包括 Module、
  Receiver 配置、页面和 Port。不再保留旧 `AppLanguage`、`AppSettings`、`AppStrings` 别名
  或 `services/*.dart` 兼容导入 shim。纯 Dart WebShare route worker 使用
  `package:feature_lan_share/lan_web_share.dart`；该窄入口只导出生产
  `LanWebShareRequestHandler` 及其 DTO/回调契约，不携带 Flutter 服务或页面。
  worker 只验证真实 TLS listener 与 production route handler；Native Network V2
  transfer 由独立测试负责。
- 依赖：`app_core`、`app_ui`、`network_transport`、`network_sdk` 及 LAN 直接插件。
- 数据库：`LanShareModule` 独占 `lan_share.db`，只存历史和非秘密配对 metadata。
- 生命周期与资源 Owner：Module 负责数据库、历史 Repository、Receiver、TrustStore
  和 `LanNativePeerRegistry`；Receiver 内部 Relay Owner 负责 Relay Timer、credential
  client 和事件订阅，Module 仍负责等待两者关闭及 WebSocket/HTTPS 资源；
  AppRuntime/NetworkRuntime 负责 NetworkIdentity、native handle 和共享
  NetworkFacade。Feature 只能释放自己的订阅、HTTP/Discovery/Transfer 资源和
  Session 使用状态，不能停止或释放 App Scope 网络资源。
  Receiver 初始化只请求 `NetworkCapability.runtime`；App Shell adapter 将
  Runtime-owned `NetworkCommandGateway`（因此不隐式要求 QUIC）适配为
  `network_sdk.SessionClient`，并将控制面请求执行器组装为
  `network_sdk.BootstrapClient`；Feature 只能释放自己的订阅和 Session 使用状态。
  最终释放先等待 Discovery/WebShare 停止，再等待 Transfer 关闭全部
  socket/server 和事件流；ViewModel 在释放前还会收敛 keep-alive、历史迁移和
  持久化队列，单项 cleanup 失败不跳过后续 owner。同步 `dispose()` 只是
  Flutter 兼容入口。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。

## Breaking-refactor implementation ledger (2026-08-25)

本表是当前代码审查快照，不把设计目标误报为已完成：

| Contract | 当前状态 |
| --- | --- |
| AppRuntime single NetworkRuntime/identity/facade owner | App Shell 已组装共享 identity、runtime 和 facade；AppRuntime/App adapter 测试覆盖一次 runtime capability/gateway 初始化、共享 facade 借用和幂等 dispose。 |
| Explicit `registerPeer` → `connectPeer` → `removePeer` | `network_sdk` 与 App adapter 已提供显式链；`LanNativePeerRegistry`/`LanNativeTransferCoordinator` 已承接 restore、endpoint、connect、transfer，ViewModel forget action 统一经 Coordinator/Registry 完成显式 trust revoke。 |
| V2 atomic trust / no half-pair | pairing server/client 绑定双类静态 identity，并只写完整 `LanPeerTrustRecord`；旧 V1 pairing/trust helpers 已删除，当前持久化入口只有 V2 atomic record。 |
| Trust/discovery/route/relay separation | `LanPeerTrustRecord`、Discovery-only models、`LanPeerViewState`、route flags、registry restore/invalidate 和 Relay authorization 已有实现及定向测试；生产 UI、配对入口和 ViewModel 已统一消费分离后的模型。 |
| Binary Network V2 only | `/api/lan/upload` 已不再暴露；HTTP metadata 明确拒绝 binary，regular-file Network V2 coordinator 统一负责发送。 |
| Text/clipboard | 按 V2 控制面决定，Feature-facing `NetworkFacade.sendMessage` 保持稳定 unavailable 边界；text/clipboard 使用 authenticated HTTPS + application E2E。 |

上表记录的是当前代码与定向测试已经观察到的粒度。AppRuntime exactly-once、双
Runtime/device-restart transfer、V2 pairing/storage safety 和显式 peer removal 均由
当前 App/Feature/SDK/native 定向测试覆盖；text/clipboard 的 HTTPS + application E2E
是本 breaking refactor 的明确数据面决定。
