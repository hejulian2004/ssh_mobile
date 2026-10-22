最新更新时间：2026-10-22

# Transport Network V2 文档与验证审计（历史记录）

> 注（2026-08-27）：Relay Bootstrap 已完成 V2 升级（`POST /v2/devices/enroll`、`POST /v2/devices/refresh`，`protocol_version=2`），且 Backend 已拆分为独立 Relay 与 Admin 两个 Go 服务。历史 Bootstrap V1 边界已完全清退。

## 审计范围

本记录保存迁移期间对 v2 相关实现的审计快照，覆盖 Rust `network-core` 与
`network-nat`、Dart native/transport、Go Relay 以及 Relay Protocol V2 的测试
入口。它是迁移期间的审计记录，不替代代码、测试、协议契约或 Accepted ADR。
当前 final-fix 验证以 `docs/NETWORK_V2_FINAL_ACCEPTANCE_REPORT.md` 与代码/测试
为准。

## 结论

- **协议与架构文档已存在**：`protocol/RELAY_V2_CONTRACT.md`、
  `ADR-TRANSPORT-NETWORK-V2`、`ADR-DISCOVERY-V2`、
  `ADR-CONNECTION-LIFECYCLE-V2`、`ADR-BUSINESS-RECOVERY-V2` 和
  `ADR-RELAY-DATA-PLANE-V2` 分别覆盖 wire、Resolve/Discovery、连接生命周期、
  业务恢复和 Control/Data 分离；本次没有新增架构决策，因此不创建重复 ADR。
- **CI/验证入口已存在**：`.github/workflows/flutter.yml` 的
  `protocol-v2-contract`、`native-network-quality`、`relay-quality` 和
  `sdk-dart-quality` 覆盖协议 fixtures、Rust、Go Relay 与 Dart SDK。现有
  `scripts/bash/contracts/relay_v2_contract.sh` 负责 fixtures/proto/buf 合同检查，不应被误读为
  Rust/Go 单元测试替代品；`acceptance_matrix.json` 当前 60/60 为
  `covered`，后者由对应 CI job 执行。
- **Memory 已补齐当前高成本事实**：SDK Memory 记录 command-result 去重、peer
  connect intent、CandidatePayloadV2 cache 和 Delivery attempt 边界；Backend
  Memory 记录 v2 request/attempt 校验、Resolve fail-closed、epoch 要求、数据面
  role binding 与吊销关闭。
- **V2 ownership 与本地 Rust 验证已收口**：`PeerSupervisor` 是唯一可变的
  Peer connectivity owner，`PeerPathManager` 持有 Direct/Relay
  `PhysicalPath`，`ConnectionSessionStore` 只保存 identity/admission/security，
  业务操作通过 `PathLease` 取得一次性路径。`cargo fmt --all -- --check`、
  `cargo check --workspace --locked`、workspace Clippy `-D warnings` 和
  `cargo test --workspace --locked` 均通过；其中 `network-core` 为 273 项，
  workspace 测试包含 network-ffi、network-nat、network-protocol、Relay 和
  network-webrtc（1 个需要外部 coturn 的 ignored 测试）。
- **Go/Dart 本地门禁已完成**：strict acceptance 的 Go Relay selector 与三组
  Flutter owner suite 均通过；`protocol-v2-contract` 也通过 protoc、buf lint
  和 frozen Relay breaking checks。完整 App/feature 矩阵仍属于更广的 CI 门禁，
  不在本次 ownership closeout 的选定本地 jobs 内。
- **Network SDK/Data V2 已完成切换**：native Rust/Dart wire envelope 使用协议版本
  2，schema package 为 `network.v2`，QUIC ALPN 为 `ssh-mobile/2`，App codec 为
  `NetworkProtocolV2Codec`；Relay Bootstrap `/v1/devices/*` 与 C FFI ABI `1`
  保持独立，不因 Network Protocol V2 自动升级。
- **V2 ownership 命名已收口**：连接尝试由
  `ConnectivityAttemptCoordinator` 编排，ConnectionSession 由
  `ConnectionSessionStore` 保存，`ReadySessionIndex` 只保存可复用摘要；Peer
  lifecycle 由 `PeerSupervisorRegistry` 负责，物理 carrier 由
  `PeerPathManager` 负责。Network V2 `SendMessage` / `DataMessage` 不再携带
  per-message crypto mode；Required 使用 fresh application E2EE root，Disabled
  仅允许 Direct identity-only，Relay Disabled fail closed。
- **关键生产队列已收口**：Runtime event mailbox 与 Transfer progress channel
  有界；WebRTC I/O event sink 也必须使用有界 Tokio channel。测试适配器可以使用
  unbounded channel，但不进入生产运行时。
- **历史文档边界已标明**：旧 ADR 和模块化迁移记录中的 v1 名称只保留决策历史；
  当前实现、README、AGENTS 与 V2 ADR 才是 Network Protocol V2 的权威说明。

## stale-v1 边界

- `docs/baseline_records.md` 保留为 `network-v1-final` 的历史冻结记录，不代表
  当前 v2 实现状态。
- `docs/architecture/RELAY_CONTROL_PLANE.md` 只保留当前 v2 边界。v1 控制面流程已移除，不能再从该文检索。
- `ADR-010` 仍保留 Delivery 的基础不变量，但其中关于 Session/Connection 连续
  性的 v1 语句由 `ADR-BUSINESS-RECOVERY-V2` 与
  `ADR-CONNECTION-LIFECYCLE-V2` 取代。
- `ADR-022` 仍保留 Runtime supervisor 的根取消、任务 join 与 stop 边界，但其中
  把 reconnect、direct-upgrade 或 Delivery retry 归属到旧 Session task group 的
  v1 语句由 v2 生命周期/业务恢复 ADR 取代。
- Relay Bootstrap/WebSocket V1 contract、历史 fixtures 和被 superseded 的 ADR
  仍保留，但必须显式标注为独立 Bootstrap/历史边界。Network SDK/Data V1 的
  active package、旧 codec、旧 schema 和 per-message crypto-mode compatibility
  path 已退休；它们不再作为当前 V2 的 fallback。

## 验证边界与环境记录

- PathHandshakeV2 已折叠进既有 Noise transcript；Relay 只转发
  `DATA_ENV_CRYPTO`，PairReady 后完成 crypto admission，只有
  `complete_relay_admission` 完成后才设置 `relay_path_ready` 并发布 Connected。
  Rust workspace、Phase 0 contract baseline、Go Relay selector 和 Dart owner
  suites 均已通过。
- CandidatePayloadV2/cache 现在由 `RuntimeState` 持有，Stage A 会先读取 fresh
  monotonic cache/configured direct candidates，失败后才进入 Resolve→Offer；Resolve
  与 ConnectivityAnswer 会刷新 cache；过期 Stage B refresh、heartbeat 不刷新、
  epoch invalidation 和 server TTL 已有 Candidate V2 测试。
- RelayData L1 已补 PairReady Ping、30s/15s Ping-Pong liveness、single-writer
  control frames、pair 后 reservation consumption、active TTL 解耦和 upgrade
  pending revoke tracking；过期 data admission、idle natural expiry、explicit
  revoke close 和 persistent-failure fail-closed 均由 Go 测试覆盖。
- ReliableStream manager 已在 Session teardown 保留 per-peer tombstone，旧
  `(peer, opener, stream_id)` handle 不能在重连后透明复用；未实现跨路径透明迁移，
  符合 lease=lifetime 约束。
- Core Runtime 对外事件根队列已改为 count+byte bounded sender；FFI/Dart EventMux
  继续执行 control/data fairness、overflow policy 和单事件硬上限。测试专用
  `UnboundedSender` 适配器不进入生产 Runtime。
- 本次本地 protocol job 已执行 `protoc` descriptor、`buf lint`、frozen Relay
  `buf breaking`、Go Relay 和 Dart/Flutter owner tests；完整 App/feature 矩阵仍
  由 CI 的其他 job 覆盖。
- 未运行真实多主机/移动设备硬件部署验收：当前证据来自 WSL 本地 Rust/Go/Dart
  测试与 committed protocol fixtures，原因是本地没有外部设备/Relay 集群 endpoint。
