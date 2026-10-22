> 最新更新时间：2026-10-22

# ADR-RELAY-DATA-PLANE-V2：Control/Data 物理分离、Reservation 模型、Relay Protocol V2

## Status

Accepted for the transport-network v2 breaking refactor (2026-08-15). Companion
to ADR-TRANSPORT-NETWORK-V2; implements design doc §24-§25, §31-§33 and
Steps 2, 7.

## Context

v1 用单个 `GET /v1/connect` WebSocket 复用控制帧（JSON）与 0x10 binary 数据帧，
`RelayClient` 共享一个 socket 与一个 outbound mpsc；控制面还携带文件投递信封
（`channel_message` / `channel_ack` / session accept|complete|cancel）。v2 要求
Control 与 Relay Data **物理拆开**，数据面使用 Reservation 模型，协议升级为
Protobuf Binary over WebSocket。

## Decision

### Control Plane 与 Relay Data 必须物理拆开

```text
/v2/control
/v2/relay/{reservation_id}
```

- **Control Connection**（长期存在）只传：Auth、Heartbeat、Discovery、Resolve、
  Connectivity Signaling、Presence Hint、Realtime Signaling、Relay Reservation。
  绝不允许 File Chunk、Delivery Payload、Bulk Payload。
- **Relay Data Connection** 只负责：Connect/PairReady 配对握手、Encrypted Payload
  Forwarding、Flow Control、Close。服务器不解密业务数据；只有 reservation 的
  initiator 与 responder 两个 token 角色都在线后，Relay 才向双方发送 PairReady
  WebSocket Ping。
- Rust 端拆分 `RelayControlClient` / `RelayDataClient`，二者**严禁共享**
  outbound queue、rate limit budget、socket。大流量不能阻塞 heartbeat /
  signaling / Resolve。

### Control 与 RelayData 独立认证

两条 WebSocket 都必须独立生成 32 字节 nonce 与正整数 Unix 秒时间戳，并携带
`X-Relay-Timestamp`、`X-Relay-Nonce`、`X-Relay-Signature`。Ed25519 transcript
固定为 `GET\n<path>\n<timestamp>\n<nonce>`，末尾没有换行；`<path>` 必须是
实际 `/v2/control` 或 `/v2/relay/{reservation_id}`。Relay 包含式接受 ±300 秒，
nonce 保留到签名时间戳加 301 秒。缺失、非法、过时、超前、重放或 Cache 消费
失败均 fail closed 为 HTTP 401，不升级 socket。Rust 共享请求构造器服务两种
物理连接，但每次调用独立生成证明；旧三段 transcript 没有兼容回退
（[ADR-031](ADR-031-relay-refresh-proof-freshness.md)）。

证明通过后，Control 与 RelayData 都必须在一个 5 秒 device-security 总 deadline
内完成 per-device stripe 等待、第一次持久 enrollment 检查、WebSocket upgrade、
不可路由 staging、第二次持久 enrollment/lease 检查与 activation。禁止每个阶段
重置 deadline。staged worker 必须等待 activation barrier，不能在登记后复查失败前
发送 Ready/PairReady 或处理客户端流量；激活后立即释放 stripe，长连接不长期持锁。

### Relay Data 使用 Reservation 模型

Direct 失败后，且仅在同一条 Control Connection 上完成 Resolve → Offer gate 后：

```text
A → ReserveRelay(B) → Relay Control
   → RelayReservation { reservation_id, relay_data_endpoint, expires_at, local_token }
B 同时收到 IncomingRelayReservation
双方分别连接 /v2/relay/{reservation_id}
Relay 确认两端角色后 → WebSocket Ping PairReady → encrypted payload
```

数据通道只负责配对握手、encrypted forwarding / flow control / close。
`relay_data_endpoint` 与 `local_token` 由 reservation 授予；连接双方凭
`reservation_id` 进入同一数据通道。`RELAY_PUBLIC_URL` 表示公开 HTTP edge origin：
HTTPS 规范化为 WSS，显式 WSS 保持不变，回环 HTTP 规范化为 WS；除可选根路径
`/` 外含其它 path，或含 query/fragment/凭据、非回环 HTTP/WS 和回环 HTTPS/WSS
的 origin 均拒绝。

未完成配对时，相同角色的重试替换旧端点，不会把两个 initiator 或两个 responder
互相配对。active pair 上的同角色重试会使两个旧端点都失效并关闭；重试端成为新
pending pair 的第一端，counterpart 必须重新连接。两端完成 Connect 后，Relay 通过
single writer 向双方各发送一次 WebSocket Ping：
`ssh-mobile-relay-paired-v1:<reservation_id>`。PairReady 不是 protobuf
`RelayDataFrame`，也不是 `RelayDataReady` 消息。两端 writer queue 都成功接收 marker
后 registry 才提交 pair；每个端点只有在自己的 marker 实际写入 socket 后才能转发
数据，接收端 FIFO 保证 marker 位于后续 payload 之前。任一 enqueue/commit 失败都回滚
两端，不能发布部分 Ready。

已完成 PairReady 的 pair 是一次性的。仅当当前 active pair 仍登记时，同角色 retry
才可原子关闭两个旧端点，并以 retry 端建立 fresh pending；counterpart 必须再次
Connect 后才能形成一次新的 PairReady。普通断线会关闭 counterpart 并终结该 pair；
reservation 已被消费，后续重连必须先取得新 reservation，不能复用旧 token。Relay
不会向仍在线的旧客户端发送第二个 PairReady。30 s Ping / 15 s Pong 保活使用不同的 Ping payload
`ssh-mobile-relay-keepalive-v1`，不能被客户端解释为 PairReady。

Reservation `expires_at` 只约束尚未完成配对的 admission。PairReady 之后，active Relay
Data lifetime 与 reservation TTL、自然 credential expiry 解耦；显式 device revoke
仍会关闭 pending、active 及其 counterpart。revoke 与业务帧 forwarding 在 registry
mutex 下线性化；最大 512 KiB 业务帧的 protobuf 编码和分配在进入该锁前完成，锁内只做
pair/terminal 复核、flow budget 预留和非阻塞入队。相关端点先变为 terminal 并失去 retry
ownership，writer 丢弃未写出的业务帧，生命周期调用等待已开始的 socket write 收敛后
才返回。PairReady、30 s Ping、
15 s Pong timeout、binary frame 与 Close 均通过同一个 outbound writer。

RelayData registry 关闭先封闭准入并取消其 lease-I/O lifecycle context，给已排队的
RelayDataClose 一个 2 秒总 drain window，再强制关闭剩余 socket；完整 RelayData
graceful-plus-forced 子预算为 5 秒。Server 在一个 10 秒总预算内先并发收敛
RelayData、Control/Hub 与事件对账，再让 Cache/Storage 在剩余预算内并发关闭；因此
忽略 context 取消的依赖不能无限延长进程退出。

### Relay Protocol V2

新增 `protocol/proto/relay/v2/relay_v2.proto`，Protobuf Binary over WebSocket，替代现有
Control JSON。核心消息至少包含：

```text
Ready
Heartbeat / HeartbeatAck
DiscoveryPublish / DiscoveryAck
ResolvePeerRequest / ResolvePeerResponse
ConnectivityOffer / ConnectivityAnswer
PresenceHintSnapshot / PeerAvailableHint / PeerUnavailableHint
RelayReserveRequest / RelayReserveResponse / IncomingRelayReservation
RealtimeSignal
ProtocolError
```

- 所有 Request 必须携带 `request_id`；所有异步 attempt 必须携带 `attempt_id`。
- **禁止继续依靠全局 Notify 判断应答归属**（删除 v1
  `candidate_signal_notify` 关联模式）。
- `ConnectivityOffer` 不携带 `target_device_id`；目标由同一 Control Connection
  上先前成功的 Resolve gate 绑定。Answer 与 direct probe 不持有该 gate 的锁。
- `RealtimeSignal` 保留 `target_device_id`，但 wire schema 不携带
  `sender_device_id`；接收方只能从既有 `realtime_id` → peer 绑定取得远端身份，未知绑定
  必须 fail closed。

### 错误模型固定

```text
Control：  ControlUnavailable / AuthenticationFailed / PeerOffline /
           PeerNotReady / ResolveTimeout / ProtocolError
Direct：   NoCandidate / DirectTimeout / TransportFailed /
           PeerIdentityMismatch / CryptoHandshakeFailed
Relay：    RelayUnavailable / RelayReservationFailed / RelayConnectFailed
Business： RecoverableTransportLoss / OperationExpired / ResumeRejected
```

禁止全部映射为通用 `RelayError` 或 `IoError`。

### 单实例部署范围

第一阶段：`Relay Control = 单实例`、`Relay Data = 单实例`、`Redis = 外部共享
live state`、`MySQL = 外部持久状态`。不得宣称 Multi-instance supported，直到
完整实现 `Global Control Routing` + `Relay Data Node Selection`。

## Consequences

- Control 与 Data 面在 socket / queue / rate budget 上彻底隔离，大流量不阻塞
  控制面。
- 数据面不承载业务解析，Relay 对 Discovery 语义与业务明文保持零知识。
- Relay Protocol V2 的 `request_id` / `attempt_id` 关联取代全局 Notify，消除
  stale/delayed answer 竞态。

## Verification

按 Main 基线版 §40 测试矩阵的 Relay 组执行：大文件 Relay Data 满载时 Control
heartbeat / Resolve / signaling 不受影响；Control 面禁止 File Chunk / Delivery
Payload / Bulk Payload（静态守卫）；Relay Protocol V2 的 request_id 关联、
attempt_id 关联、stale answer 忽略；同一 Control connection 的 Resolve → Offer →
Reserve 一次性 gate；reservation 生命周期
（expires_at 仅约束 pending admission、local_token 校验、角色配对、WebSocket Ping
PairReady、双方连接 `/v2/relay/{reservation_id}`）。回归测试还必须分别覆盖：active
A1+B1 上 A2 同角色 retry 会关闭 A1+B1，且只有 B2 再次 Connect 后 A2+B2 才收到一次
PairReady；普通 A1 断开则关闭 B1、消费旧 reservation，A2 复用旧 token 必须被拒绝，
双方需取得新 reservation。静态 smoke/marker 只能证明证据路径存在，
不能把行为标记为 covered；行为覆盖必须由 owner test selector 实际执行并记录。
认证回归还必须验证 Control/RelayData 的 timestamp header、四段 transcript、
±300 秒包含边界、nonce 的签名时间失效点，以及旧 transcript 硬拒绝。
准入/生命周期回归还必须验证：同一个 5 秒 deadline 覆盖锁等待到 staged activation；
任一端 PairReady enqueue 失败会原子回滚；payload 不能越过发送端 PairReady 的实际写入；
keepalive marker 不等于 PairReady marker；pending 与 active 的同角色重试分别执行替换和
双端失效；revoke 线性化后排队业务帧不能继续启动写入，已开始的真实 WebSocket 写入会在
生命周期调用返回前收敛；忽略 context 的
reservation/dependency store 不能让 RelayData 或 Server Close 超过总预算。
