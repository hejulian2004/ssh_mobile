> 最新更新时间：2026-10-22

# SSH Mobile 跨平台 P2P 网络平台实施计划

**Status:** Relay / Admin Backend split and Relay Bootstrap V2 complete (2026-08-27). Network Protocol V2 ownership closeout complete (2026-08-20). WireGuard, `/v1` bootstrap, and transparent route upgrade are not part of the current project.
**Target Repository:** `hejulian2004/ssh_mobile`
**Plan Type:** Architecture + Implementation + Protocol + Engineering Specification

---

# 当前实施状态（2026-08-23）

以下状态只描述已经接入生产调用链的部分。当前生命周期以 v2 ADR 为准。

## Network Protocol V2 ownership closeout（2026-08-20）

本节是本文件中当前 Network Protocol V2 实现状态的权威补充。v1 生命周期、透明迁移和后台升级不再代表当前实现。

- `PeerSupervisor` 是每个 Peer 唯一的可变 connectivity owner。并发 waiter
  按能力完成；更强需求扩展当前 attempt，业务 ensure 不开启 maintenance，只有
  显式 `ConnectPeer` 才会保持连接。
- `PeerPathManager` 是 Direct/Relay `PhysicalPath` 与 carrier 的唯一强 owner。
  `PathHandle`/projection 不持有 carrier，业务操作按一次发送或一次 Stream/Transfer
  生命周期取得 `PathLease`；Direct Ready、Direct Probe 和 Relay Ready 可以共存，
  normal drain 与 hard close/revoke 的语义分离。
- Delivery 每次发送取得并释放一个 lease，ACK 不持有 lease；Transfer 身份是
  `(peer_id, transfer_id)`，断线按 confirmed offset 在新 ConnectionSession 恢复；
  ReliableStream 按 `(opener_device_id, stream_id)` 定址并绑定原路径，不透明迁移。
- Required E2EE 在新连接安装 fresh application root；Direct Disabled 只允许
  authenticated identity-only plaintext，Relay Disabled、加密/明文策略不匹配均
  fail closed。Relay 只转发 opaque payload，Frozen Relay V2 wire semantics 未改变。
- authenticated passive inbound 进入 Online 但不启用 maintenance。环境变化刷新
  discovery、保留健康 Relay/Realtime，并只为 maintained peer 在 Relay Ready 后按
  `1/2/4/8/15/30s + jitter` 做有限 Direct recovery；无业务 lease 的临时路径闲置
  60 秒后回收。
- Native/FFI/Dart 事件 lane 使用 Control `256/4 MiB`、Data `128/8 MiB`、单事件
  `1 MiB` 和最多连续 8 个 Control；diagnostics 从 PeerSupervisor、PathManager、
  Stream/Transfer owner 读取实时计数。
- `protocol/contract_tests/acceptance_matrix.json` 的 71/71 案例均有行为测试或
  contract-test evidence；source-only marker 不计为覆盖。CI 的 pinned protocol
  工具为 `protoc 27.1` 与 `buf 1.47.2`。

- 已完成 Rust Tokio runtime、版本化 Protobuf command/event FFI 和 Dart
  helper-isolate 生命周期。
- 已完成 Quinn 直连、固定 Ed25519 peer 身份握手、显式接收审批、512 KiB
  有界流式传输、SHA-256 校验、临时文件提交、接收端持久化完成确认、取消和进度事件。
- `LanShareViewModel` 通过借用的 `NetworkFacade` 提交 native 文件任务；命令接受与
  `TransferCompleted`/`TransferFailed` 终态事件严格分离，历史只保存稳定错误码。
- peer 公布的 candidate 会进入每 peer `ConnectivityAttempt`；PathManager 只
  保留已建立连接的 RTT/loss metrics，不保存远端 discovery truth。
  Candidate Offer/Answer 与 Direct race 受 attempt 版本边界约束，Direct First
  在固定窗口内选择一次 transport；Relay 不进行无触发的透明升级到 Direct。
  仅在独立的 network-environment change 触发下，maintained peer 才会在 Relay
  Ready 后按 bounded recovery schedule 重新探测 Direct。
  Transport loss 销毁当前 ConnectionSession，下一次业务连接重新 Resolve。
- Network Protocol V2 ownership cutover 已完成：`PeerSupervisor` 是唯一的
  Peer connectivity owner，`PeerPathManager` 实际持有 Direct/Relay
  `PhysicalPath`，`ConnectionSessionStore` 只保存 connection/security admission，
  Delivery/Transfer/Stream 通过 `PathLease` 选择一次性 carrier。Frozen Relay V2
  wire contract 未修改。
- E2EE policy 已贯穿 PeerConfig、Noise/path admission 与业务发送：Required
  每条新 Transport 安装 fresh application root；Disabled 仅允许 Direct
  identity-only，Relay Disabled fail closed。Stage A/B/C 分别保持纯 Direct
  cache、authoritative Resolve→Offer、受预算与策略约束的 Relay fallback。
- Rust Relay V2 client 已实现 WSS control/data separation、opaque payload、
  admission、取消、接收入站审批及安全落盘；Flutter 仍只负责 bootstrap
  enrollment、凭据安全存储和 native 配置，不建立 Dart Relay 数据面。
- `network-core::RealtimeManager` 已作为当前 ConnectionSession 上的 Realtime Route 接入
  WebRTC；Offer/Answer/ICE/Restart/Close 只走认证 Relay control plane，
  `ssh_mobile_network_native` 通过 helper isolate 提供有界 typed Realtime
  command/event API，不向 Dart 暴露 Quinn、Socket 或 WebRTC 原生句柄。
- native `network-core::connection` now models routes as `RouteTopology × RouteTransport`.
  Each transport Connection has exactly one ConnectionSession with a fresh SessionId
  and Noise root; transport loss destroys it, while Delivery/Transfer business state
  resumes by business ID across a fresh ConnectionSession.
- Plan 3 Step 1 now separates native Delivery active receive state from
  processed dedup history. TTL/LRU pruning cannot remove `InFlight` or
  `OrderedBuffered`; application ACK timeout fails a strict ordered channel
  without skipping Sequence, and explicit ConnectionSession close clears receive-side
  active state.
- Plan 3 Step 2 now separates Realtime queue acceptance from command completion.
  `NetworkRealtimeGateway` returns a `NativeCommandTicket`; the App Shell keeps a
  bounded `commandId → Completer<SdkResult<void>>` map with timeout and dispose
  cleanup. `RealtimeSession` lifecycle states remain native-state-event driven, and
  a successful stop command waits for native `closed` before reporting `stopped`.
- Plan 3 Step 3 now admits each authenticated generic carrier as a
  `ConnectionSession` with a bounded carrier. TCP and direct WebSocket routes can
  carry Delivery data/ACK frames; every new transport uses a fresh SessionId and
  Noise root, while pending Delivery resumes by MessageId/channel state. UDP has
  no reliable-message capability, and transport loss destroys the session rather
  than migrating its route. Public peer/route events expose
  `RouteTopology × RouteTransport` metadata.
- Plan 3 Step 4 installs each ConnectionSession root only after an authenticated
  `Noise_XX_25519_AESGCM_SHA256` exchange and the v3 post-handshake export.
  After pinned identity proof, Noise TransportState protects a fresh random
  RootSeed plus RootConfirm/Accept; the transcript hash is context, not secret
  root material. Every new transport gets a new SessionId and Noise root;
  Delivery/Transfer state is re-encoded under the current root. Production
  nonces are structured epoch/direction prefixes plus monotonic counters,
  bounded key rotation is enforced, and missing E2EE context returns an error
  instead of silently downgrading to plaintext. See `docs/adr/ADR-028-forward-secret-session-e2ee.md`.
- V2 makes `ConnectionSession` transport-scoped. A transport loss destroys the
  current session and its crypto context; the next explicit connection performs
  Resolve and creates a new SessionId and Noise root. Delivery resumes pending
  messages by MessageId/channel state, and Transfer resumes by transfer_id plus
  confirmed_offset. No old SessionId, root, route, or transport ciphertext is
  carried into the new connection.
- Public async connect commands now report terminal completion from the
  `PeerSupervisor` result, not from task startup. RemovePeer, environment-change
  recovery, diagnostics, and duplicate command correlation use the live
  supervisor/path/business owners.
- The acceptance matrix has 60/60 cases covered. Local Rust workspace gates,
  the strict Python/Rust/Go/Dart/Relay-proto/FFI gate, and selected architecture/
  protocol/SDK jobs pass; the broader App/feature/device/integration matrix remains
  a CI responsibility.
- `network_sdk.RealtimeClient` now provides a Feature-safe `RealtimeSession` boundary;
  the App Shell maps native lifecycle events while Features cannot encode SDP/ICE or
  touch PeerConnection, sockets, or native handles. Native DataChannel media remains
  typed-unavailable until a native decoder/media event is implemented.
- Step 9 has a fixed A–L real-network fault matrix in
  `docs/NETWORK_FAULT_MATRIX.md`; its v1 route-migration/reconnect entries remain
  historical validation records. Current v2 checks cover Direct/Relay fallback,
  fresh ConnectionSessions, Delivery/Transfer recovery, Relay restart, and
  checkpoint/resume; physical network switching and 1 GiB+ transfer still need evidence.
- 当前项目不再支持或实现 WireGuard，也不把它列入发布验收。
- Go Relay 使用 `POST /v2/devices/enroll` 与 `POST /v2/devices/refresh` 管理设备凭据，
  transport 只使用 `/v2/control` 与 `/v2/relay/{reservation_id}` 两条物理分离的
  WebSocket；不存在 `/v1/connect`。Go 进程仍支持显式 `memory` 模式；随附 Compose
  部署默认启用 MySQL 持久化 enrollment/revocation，并要求 Redis 承载共享 live state。
- Flutter 公共网络层统一返回 `NetworkResult`，公开事件使用类型化事件；
  Realtime command result 只在 App Shell adapter 内部关联，不向 Feature 暴露。
  LAN HTTP 错误使用稳定的
  `code`、`message`、`operation`、`peer_id` 结构，WebShare 固定 HTTPS，
  浏览器不满足安全上下文时禁止传输而不自动降级。
- WireGuard 不属于当前项目；Feature-safe Realtime 生命周期与 signaling 已交付，
  native decoded media event/decoder 和仍缺少设备证据的公网场景不得标记为已验收。

开发阶段 Drift 只维护 `schemaVersion = 1` 的当前 schema；字段变化后删除本地
开发数据库并重新生成代码，不编写迁移或旧数据导入逻辑。

---

# 1. Plan 目标

本计划的目标是在不推翻现有 SSH Mobile 架构的前提下，将当前：

- SSH / SFTP
- LAN Quick Share
- 公网 WebSocket Relay
- Flutter 跨平台客户端

逐步升级为一套统一的跨平台网络通信平台。

当前目标架构支持：

1. Windows / Android / iOS / macOS 多端。
2. 设备身份与可信设备管理。
3. IPv6 优先直连。
4. IPv4 NAT 穿透。
5. P2P 优先、Relay 自动回退。
6. QUIC 高速文件传输。
7. 服务器只参与控制和必要的数据转发，不保存业务 Payload 或文件内容。
8. Feature-safe Realtime 生命周期与 signaling；decoded media 能力按独立契约扩展。
9. Flutter 只承担 UI、业务意图和 App Shell 适配。
10. Rust 统一实现跨平台网络核心。
11. Go 负责服务端控制平面与 Relay。

最终技术栈：

| 层 | 技术 |
|---|---|
| UI | Flutter / Dart |
| 客户端网络核心 | Rust |
| 异步运行时 | Tokio |
| 文件传输 | QUIC |
| QUIC 首选实现 | Quinn |
| QUIC 实现 | Quinn |
| NAT | IPv6 + multi-server STUN + Candidate Exchange + simultaneous QUIC connectivity checks |
| VPN | 不在当前项目范围 |
| 服务端 | Go |
| 控制连接 | HTTPS + WSS |
| 控制消息 | Protobuf |
| Relay | Go；Compose 默认 MySQL + Redis（memory 仅显式本地测试） |
| 文件 E2E | X25519 + AEAD |
| 实时音视频 | WebRTC（后续） |

---

# 2. 当前仓库状态分析

当前 SSH Mobile 已经不是一个简单 SSH 客户端。

仓库采用 package-first MVVM：

```text
packages/core/
packages/features/feature_*/
packages/infrastructure/
apps/ssh_mobile_full/lib/app/
apps/ssh_mobile_full/lib/services/
apps/ssh_mobile_full/lib/features/{home,settings,startup}/
```

并明确规定：

- 产品 Feature UI 与业务逻辑进入 owning `packages/features/feature_*`
- 跨 Feature 契约进入 `packages/core/`，App 组合与适配进入 `apps/ssh_mobile_full/lib/app/`
- SSH/Network 运行时进入 owning Infrastructure package 或 App Scope adapter
- Package 之间只使用公共入口，不导入另一 Package 的 `/src/`
- ViewModel 不承担底层协议实现
- 非生成生产文件超过 500 行时必须审查真实职责边界；解耦以逻辑 Owner 为准

因此，本计划不会重新设计 Flutter 层架构，而是在现有 MVVM 下面增加：

```text
Flutter Feature/ViewModel
        ↓
NetworkFacade（由 App 注入）
        ↓
ssh_mobile_network_native FFI
        ↓
Network Core
```


WireGuard、`/v1/connect`、旧 App 本地 Feature 路径、透明 Route 升级和 memory-only Relay 的历史规划正文已移除。
当前实现以本节、[`memory_docs/sdk/current-state.md`](../memory_docs/sdk/current-state.md)、[`memory_docs/backend/current-state.md`](../memory_docs/backend/current-state.md)、Accepted ADR、代码与测试为准。
