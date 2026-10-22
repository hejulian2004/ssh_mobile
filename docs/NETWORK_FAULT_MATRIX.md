最新更新时间：2026-10-22

# Network Fault Matrix

本矩阵是 SSH Mobile 网络 SDK 下一阶段 Step 9 的固定验收入口。当前固定场景覆盖
A–S；每次网络核心、Relay、Native Realtime、Delivery 或文件 Resume 变更后，按同一
场景编号记录证据，不得只以“连接恢复”判定成功。连接生命周期遵循
`ADR-CONNECTION-LIFECYCLE-V2`：`ConnectionSession` 与单个已认证 transport
connection 同生共死，不做跨连接的透明 route migration 或 SessionId 延续。

## 统一通过条件

每个场景都必须记录：

`ConnectionSessionId`（每个 transport connection 各自记录）、当前 `Route`、Delivery
终态、文件 offset（如适用）、应用命令执行次数、恢复耗时、RTT/loss、进程内存和
Runtime task 数量。

必须同时满足：

- transport loss 后必须显式执行 `Resolve → new Connection → new ConnectionSession`；
  同一个应用命令至多执行一次，重放只允许产生安全的协议层重 ACK；
- 没有业务 ACK 的 queue acceptance、transport ACK 或 `complete` 事件不能被报告为
  应用成功；
- 新 ConnectionSession 不得复用旧 SessionId、Noise root 或旧 transport crypto；
  Delivery 的 MessageId、TransferId、Manifest Hash、File Hash 和 confirmed
  checkpoint offset 才是允许跨连接延续的业务状态；
- 一个 ConnectionSession 建立后 Route 保持不变；Direct/Relay 的变化必须通过下一次
  显式建连观察，不得以后台升级或透明迁移作为通过条件；
- stop/dispose 返回后，Runtime supervisor、session group、Relay worker 和
  Realtime adapter subscription 均为零；
- 失败证据保留稳定错误码，不记录密码、私钥、Token、SDP 或 ICE secret。
- Relay 凭据刷新必须携带 Unix 秒时间戳，并签名精确 transcript
  `POST\n/v1/devices/refresh\n<timestamp>\n<nonce>`（无末尾换行）；
  ±300 秒边界包含，±301 秒拒绝，防重放 Cache 故障必须返回 503
  且不得签发凭据。

本矩阵区分四类证据：组件/契约测试只验证 owner 内部协议；本地 Rust/内存集成测试
验证客户端状态机；`scripts/bash/e2e/client_backend_e2e.sh` 才启动真实 Dart/Rust 客户端、
Caddy 和 Go Relay 跨进程链路；真实 Android/iOS 设备网络场景仍需设备记录，不能由
Linux 容器测试替代。

## 固定场景

| ID | 场景与故障注入 | 自动化证据 / 命令 | 必须观察的结果 | 当前状态 |
| --- | --- | --- | --- | --- |
| A | LAN Direct；两端在同一局域网，优先 native QUIC/WebRTC direct | `cargo test -p network-webrtc --locked -- two_local_drivers_exchange_data_channel_payloads`；`cargo test -p network-core --locked --lib` | direct Route；同一 transport 生命周期内 ConnectionSessionId 固定；DataChannel/Delivery 一次执行、task=0 after stop | CI/native loopback 已覆盖；真实双设备 LAN 仍需设备记录 |
| B | WAN P2P；公网/受限 NAT 下候选交换和 authenticated direct punch | `cargo test -p network-nat --locked`；`cargo test -p network-core --locked --lib direct_wins_when_relay_is_still_starting` | direct nomination、RTT/loss 采样、旧 candidate 不复活、无重复应用执行 | native candidate/QUIC flow 已覆盖；真实公网双设备需设备记录 |
| C | Relay fallback；禁止/失败 direct，使用 WSS Relay | `bash scripts/bash/e2e/client_backend_e2e.sh smoke`；native `crypto_handshake::tests::relay_noise_xx_preserves_the_same_session_root`、`tampered_relay_root_seed_ciphertext_fails_closed` | 真实 Rust/Dart 客户端经过 Caddy 到 Go Relay；控制面、reservation 数据面、opaque payload、ACK/关闭成功；组件 Noise 测试继续验证六阶段和篡改失败 | client-backend smoke 负责跨进程链路；native v3 framing/tamper 仍是组件证据 |
| D | Relay 连接故障；业务显式重新 Resolve 后，新的 Direct attempt 成功 | `cargo test -p network-core --locked --lib file_transfer_resumes_across_a_fresh_connection`；`cargo test -p network-core --locked --lib connect::connectivity_attempt::tests::` | 旧 Relay ConnectionSession 销毁；新 Direct ConnectionSessionId/Noise root；Delivery/Transfer 只按业务 ID 与 confirmed offset 延续，不发生原地 route swap | native 新连接业务恢复已覆盖；真实 Relay→Direct 故障注入仍需设备记录 |
| E | Direct transport loss；显式重新 Resolve 后下一次 attempt 可选择 Relay | `cargo test -p network-core --locked --lib delivery_reliable_message_resends_same_message_id_after_reconnect`；Relay `recover` smoke | 旧 Direct ConnectionSession 关闭并得到新 SessionId；旧 ACK 不误判成功，Relay 重放不重复执行，MessageId/TransferId 与 offset 不回退 | native recovery/Relay harness 已覆盖 |
| F | Wi-Fi disconnect/reconnect；注入 Caddy/链路断开后恢复 | `bash scripts/bash/e2e/client_backend_e2e.sh strict`（含 Caddy restart probe）；真实设备另按 G/I 记录 | 凭据刷新/重连、Caddy 重启后路由恢复；真实设备仍需记录 TransferId/offset、recovery time、task count、duplicate count | Linux strict 覆盖进程级重连；真实 Wi-Fi 需设备记录 |
| G | Wi-Fi → 4G/5G；系统网络接口切换 | Android/iOS physical-device runbook（见下文） | 记录切换前后 ConnectionSessionId/Route；同一已认证 QUIC connection 内部 path migration 仅作为 transport 观测，若 connection 丢失则必须显式新建 Session；不能依赖旧 socket token | 需要真实 Android/iOS 设备，未在 Linux CI 伪造 |
| H | Relay restart；memory 模式内存状态清空，Compose mysql 模式保留 enrollment | `bash scripts/bash/e2e/client_backend_e2e.sh strict`（含 Relay restart 和未认证路由 probe）；`CLIENT_BACKEND_E2E_STORAGE=mysql bash scripts/bash/e2e/client_backend_e2e.sh strict` | 短 TTL 旧 credential 被拒绝；只有包含新鲜时间戳的 refresh 可续签并重连，过时证明返回类型化认证失败；Relay restart 后健康检查和 `/v2` 路由恢复；mysql 模式验证 MySQL/Redis wiring 与 enrollment 持久性 | strict 已覆盖显式内存模式生命周期与在线撤销；mysql 持久性由 `CLIENT_BACKEND_E2E_STORAGE=mysql` 覆盖 |
| I | App background/foreground；挂起/恢复 App | Android/iOS physical-device runbook（见下文） | adapter/session 生命周期、后台策略、恢复时间、task/订阅无泄漏；前台恢复不重复执行命令 | 需要真实 Android/iOS 设备，未在 Linux CI 伪造 |
| J | 1GB+ file resume；在 checkpoint 后断网并继续传输 | `cargo test -p network-transfer -p network-core --locked`；设备上用 1 GiB+ fixture 重复 F/G | offset 单调、Manifest/File Hash 相同、最终 exactly-once、内存不随文件大小线性增长 | native checkpoint/resume 已通过；1 GiB+ physical transfer 需设备记录 |
| K | Ordered long handler；应用处理超过 processed dedup TTL 后再 ACK，期间收到后续序号 | 当前工作区 `cargo test -p network-core --locked`；覆盖 `inflight_survives_processed_dedup_ttl_until_application_ack`、`ordered_buffer_survives_processed_dedup_ttl_and_releases_in_sequence` 与 Runtime owner 测试 | active handler 与 ordered buffer 不被 TTL/LRU 删除，ACK 后严格按 `0 → 1 → 2` 推进；显式 Session close 清空接收态 | native 自动化测试已通过；真实设备长 handler 时间窗尚未执行 |
| L | Realtime command result delayed/rejected；queue accepted 但 native result 或 `closed` state delayed | `apps/ssh_mobile_full/test/app/realtime_feature_adapters_test.dart`；`packages/infrastructure/network_sdk/test/realtime_test.dart`；`packages/infrastructure/network_transport/test/network_runtime_test.dart` | start/stop Future 只由 `commandId` 对应的 `NativeCommandResultEvent` 完成；超时/ dispose 有界清理；stop 等 native `closed` 才变为 `stopped` | 代码与测试场景已加入；当前 WSL Flutter tester 无法完成测试子进程 loopback，需 CI/可用 Flutter tester 复核 |
| M | QUIC unavailable；authenticated direct TCP fallback | `cargo test -p network-core --locked --lib tcp_fallback_authenticates_delivery_and_gets_a_fresh_session_on_reconnect -- --nocapture` | TCP route enters its own authenticated ConnectionSession, Delivery reaches the peer, application ACK completes it；after transport loss the next connection gets a fresh SessionId/Noise root, and bounded carrier shutdown leaves no stale active route | native integration test passed |
| N | QUIC/TCP direct unavailable；authenticated direct WebSocket fallback | `cargo test -p network-core websocket_fallback_authenticates_delivery_and_ack -- --nocapture` | binary WebSocket route is identity-authenticated, composed event metadata identifies direct/WebSocket, Delivery ACK completes, and no plaintext/unauthenticated route enters Session | native integration test passed |
| O | TCP transport closes；下一次显式 Resolve 发现可用 QUIC 并建立新 Direct connection | `cargo test -p network-core --locked --lib connect::connectivity_attempt::tests:: -- --nocapture` | 旧 TCP ConnectionSession 在 transport loss 时销毁；新 QUIC connection 重新认证并获得新的 SessionId/Noise root，pending Delivery 只按 MessageId 恢复；禁止原子 route swap、旧 `CryptoContext` Arc 或 KeyEpoch 跨连接复用 | native stage/route tests 已覆盖；真实 TCP→QUIC 故障窗口仍需设备记录 |
| P | Wrong pinned identity, unsupported v2, incomplete/tampered v3 E2EE exchange on QUIC/generic/Relay | `cargo test -p network-core crypto_handshake -- --nocapture`；`cargo test -p network-core session_root_source_requires_noise_transport_secret_export -- --nocapture` | handshake hash 不作为 secret IKM；wrong identity 不发送 RootSeed；v2、tampered RootSeed、wrong RootConfirm、missing Accept 均无 `CryptoContext`、无 Connected、无 plaintext fallback | native v3 security and structural tests passed |
| Q | High-volume nonce use, epoch rotation, authenticated Delivery replay | `cargo test -p network-core crypto::tests::structured_nonce_is_unique_across_one_hundred_thousand_messages -- --nocapture`; `cargo test -p network-core crypto::tests::key_rotation_accepts_one_new_epoch_and_rejects_large_jump -- --nocapture` | 100k nonce values are unique, current/recent epoch messages are accepted, large epoch jumps and unauthenticated replay are rejected, while authenticated Delivery duplicates retain dedup semantics | native crypto tests passed |
| R | Direct transport forced-close → 显式新连接；未 ACK 的 Delivery replayed once | `cargo test -p network-core --locked --lib delivery_reliable_message_resends_same_message_id_after_reconnect -- --nocapture` | 旧 ConnectionSession/Noise root 被 retire，显式新连接获得新的 SessionId；pending Delivery 按同一 MessageId 保留并只重放一次（dedup、无自动 ACK），显式 ACK 用当前 Session 的结果完成；不要求自动 reconnect 或 route migration | native 集成测试已覆盖；两端并发重连的 connection churn 仍需单独设备/并发场景证据 |
| S | Peer runtime restart → `ReplaceWithNew`；旧 Session 的 pending Delivery 被显式清理、绝不错误恢复进新 Session | `cargo test -p network-core --locked peer_runtime_restart_replaces_session_and_keeps_e2ee_delivery -- --nocapture` | 新 SessionId ≠ 旧 SessionId、旧 `CryptoContext` alias 被 retire（`get` 报错）、旧 Session pending 快照为空（`close_session` 显式清理 sender 侧 pending）、新 Session 恢复快照不含旧消息、孤儿 transfer 终止、新 E2EE 消息正常送达并 ACK | native 集成测试已通过 |

## Docker Relay 故障运行约定

从 WSL/Linux 仓库根目录运行统一入口。脚本默认创建隔离的 Compose 项目、临时网络
子网和临时 `.env`，并在退出时清理容器、卷和目录；它不会写 `relay/.env`：

```sh
bash scripts/bash/e2e/client_backend_e2e.sh smoke
bash scripts/bash/e2e/client_backend_e2e.sh strict
```

smoke 成功标志为 `CLIENT_BACKEND_SMOKE_PASS`，strict 成功标志为
`CLIENT_BACKEND_STRICT_PASS`。也可同时设置 `CLIENT_BACKEND_E2E_BASE_URL` 和
`RELAY_ENROLLMENT_TOKEN` 复用外部测试部署；日志不输出凭据。`full_test.sh` 默认不
启动 Docker E2E，需显式使用 `--with-client-backend-smoke`。

## 设备场景记录格式

真实设备运行 G/I/J 时，附上脱敏后的如下记录：

```text
scenario: G
device_a/device_b: <stable non-secret labels>
session_id: <redacted stable id>
route_before/after: <route>
delivery_result: <completed|failed|paused>
file_offset_before/after: <bytes or n/a>
application_execution_count: <integer>
recovery_ms: <integer>
rtt_ms/loss_pct: <numbers>
peak_memory_mb: <integer>
runtime_tasks_before/after: <integer>/<integer>
evidence: <screen recording or test log path>
```

设备证据不得包含凭据、Token、私钥、原始 SDP/ICE payload 或文件正文。

## Source-level guardrails

固定矩阵的代码断言位于：

- `native/network_core/crates/network-core/src/tests/`：Delivery duplicate、
  application ACK、RecoveryEpoch 与 SessionId；
- `native/network_core/crates/network-core/src/delivery/`：
  `DuplicateInFlight`/`DuplicateProcessed` 和 ACK gate；
- `native/network_core/crates/network-nat/src/tests/path_manager.rs`：
  direct path metrics；
- `native/network_core/crates/network-transfer/src/{manager,receiver}.rs`：
  checkpoint/offset、Manifest/File Hash 绑定和原子完成；
- `scripts/bash/e2e/client_backend_e2e.sh`、`tests/client_backend_e2e/`：真实客户端—Caddy—Go
  Relay smoke/strict 编排、临时凭据和清理边界；
- `packages/infrastructure/network_sdk/`：Feature-facing RealtimeSession lifecycle；
- `packages/infrastructure/network_transport/`：Runtime-owned gateway 和 task/handle
  生命周期。
- `apps/ssh_mobile_full/lib/app/realtime_feature_adapters.dart`：command ticket/result
  correlation、pending timeout、dispose cleanup 和 native state mapping。

任何新增场景必须先加入本表并定义可重复的故障注入与通过字符串，再修改实现。
