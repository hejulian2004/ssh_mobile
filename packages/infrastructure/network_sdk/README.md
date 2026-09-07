最新更新时间：2026-09-07

# network_sdk

`network_sdk` 是 Flutter 层的网络业务客户端契约与纯适配包。当前开发阶段接受
Network V2 的 breaking-only API；不保留旧 LAN pairing/storage migration、旧 API
wrapper、V1/V2 dual path 或 HTTP binary fallback。业务通过
`NetworkFacade` 消费高层操作（连接/断开对端、批量文件传输、可靠消息、实时会话、
Presence 提示事件流），并通过 `CommunicationClass` 表达通信语义，不按 QUIC、
TCP 或 WebSocket 暴露传输客户端。底层 `BootstrapClient`、`AuthenticatedApiClient`、
`SessionClient` 和 `EventStreamClient` 是 Facade 或 App Shell 的内部边界。

LAN Control Protocol V2 与 Native Network Protocol V2 是独立版本域：LAN Control
只负责 discovery、pairing、capabilities、control HTTP 以及当前 text/clipboard 的
authenticated HTTPS + application E2E；Native Network V2 负责 peer registry、
session、Direct/Relay route、E2EE、binary transfer 和 Realtime。LAN Control 的
breaking refactor 不得把 native wire schema 升为 V3。

## 边界

- 定义可注入的客户端、结果、错误、Session、Route、Transfer、事件和请求执行器契约；
- `NetworkFacade` 是业务唯一门面，隐藏 Candidate/Resolve/PathManager/RelayClient
  状态机；`CommunicationClass` 固定五种业务类别（ReliableStream/ReliableMessage/
  BulkTransfer/UnreliableDatagram/RealtimeMedia），映射到现有 native tag；
- `NetworkFacade.registerPeer` 只更新 native 对端身份、E2E 密钥、endpoint 和 route
  authorization，不发起连接；`connectPeer` 只表达实际连接意图，调用方必须先完成
  register，不能依靠隐式 register；`removePeer` 只用于显式 trust revoke/unpair，
  不由 Discovery timeout、Relay disconnect、route change 或 Feature deactivate 触发；
- `SdkPeerConfig.allowDirect/allowRelay` 是已经经过 Peer Trust/authorization 过滤的
  route eligibility。Local PIN trust 默认 `allowDirect=true, allowRelay=false`；本机
  Relay enrollment 不自动改写任何 peer 的 Relay authorization。
- 提供不持有 HTTP 资源的 `JsonBootstrapClient` 与
  `JsonAuthenticatedApiClient`，统一 JSON 编解码、Bearer 注入、刷新重试和错误映射；
- `SessionClient` 只提交业务意图，作为 `NetworkFacade` 的低层内部实现，
  数据面连接由 Rust/native runtime 持有；
- `NetworkFacade.sendMessage` 在本 breaking refactor 中保持稳定
  unavailable/invalid-argument 边界；Feature text/clipboard 继续使用 authenticated
  HTTPS + application E2E，SDK 不增加临时 message 实现或明文 fallback。
- `RealtimeClient` 只提供 Feature-facing `RealtimeSession`，包括
  `start()`、`stop()`、`state`、`revision`、native-authoritative `generation`/
  `mediaToken` 和 `audioState`；屏幕媒体端点与渲染
  capability 由独立 `realtime_media` 生命周期契约协调，PeerConnection、ICE、SDP、
  signaling、socket 和 native media resource 全部由 App/native Owner 持有；
- 不创建 Socket、FFI handle、HTTP client 或 secure-storage 实现；
- `SdkRequestExecutor`、TLS、连接复用和平台网络策略由 App Shell 提供；
- 不拥有数据库或 App/Feature 生命周期资源。

## Public API

```dart
import 'package:network_sdk/network_sdk.dart';
```

`NetworkSdk` 聚合四类客户端；`Json*Client` 只消费 App Shell 注入的
`SdkRequestExecutor`，不会自行创建 HTTP client。Feature 只使用所需的最小客户端
或 App Shell 注入的 Feature Port。

`RealtimeSession` 是唯一的 Realtime 信令/状态 Feature 边界。`RealtimeClientImpl` 只协调
App Shell 注入的 backend 事件和生命周期；它不再提供合成视频帧流。屏幕共享使用
`realtime_media` 的不透明 endpoint/surface 生命周期，未解码的视频帧和音频设备能力
保持 unavailable，不把 SDP/ICE 事件泄漏给 Feature。`start()`/`stop()` 的 Future 等待 App Shell 关联到
`NativeCommandResultEvent` 的命令完成；队列入列成功不会被当作操作完成，且 stop
只有在 native `closed` 状态事件到达后才把 session 状态置为 `stopped`。

Native state/snapshot events also carry the native-authoritative Realtime
`generation`. `RealtimeSession.mediaToken` exposes `(realtimeId, peerId,
generation)` only after that event arrives; media adapters must pass this token
unchanged to the native endpoint ABI and must never derive it from signaling
`revision`.

Network V2 的命令边界按功能域提供 Connection、Identity、Transfer、Realtime 和
Relay lifecycle ports；`NetworkV2FacadeImpl` 只编排这些 port，不拥有注入的
`NetworkV2CommandPort`。Facade `dispose()` 只释放自身状态，App/native owner
仍负责 command port 的 stop/dispose。Feature deactivate 只取消自己的订阅，不得
调用 Facade `start`/`stop`/`dispose`。

开发阶段的旧网络类型别名也集中在本包中；Feature 必须直接导入
`package:network_sdk/network_sdk.dart`，不得再创建或导出本地
`network_models.dart` 桥接文件。

## 验证

```bash
flutter analyze --no-pub
flutter test --no-pub
```

Network V2 breaking refactor 的定向入口至少覆盖：

```bash
flutter test --no-pub test/network_facade_v2_refactor_test.dart \
  test/network_sdk_contract_test.dart test/network_v2_contract_test.dart \
  test/network_v2_facade_test.dart

(cd ../../../native/network_core && cargo test -p network-core --locked --lib two_runtimes -- --test-threads=1 && cargo test -p network-core --locked --lib receiver_runtime_restart_restores_direct_trust_without_repairing -- --test-threads=1 && cargo test -p network-core --locked --lib peer_runtime_restart_replaces_session_and_keeps_e2ee_delivery -- --test-threads=1 && cargo test -p network-core --locked --lib network_v2_route_auth -- --test-threads=1)
```

App Shell adapter 与 LAN trust/route 的定向选择由成对的
`lan-network-v2-targeted` Bash/PowerShell CI job 执行；完整 Feature/App 套件仍是
必要门禁。`NetworkFacade.sendMessage` 在本边界保持 unavailable，text/clipboard
继续使用 authenticated HTTPS + application E2E。
