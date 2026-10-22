> 最新更新时间：2026-10-22

# 网络传输 SDK 架构设计

> 文档定位：本文件作为后续 Flutter + Rust 跨平台网络传输 SDK 的总体架构设计基线，用于指导模块拆分、接口定义、协议接入、连接策略、Relay 实现、应用层加密、测试和迭代计划。
>
> 目标平台：Android / iOS / Windows / macOS / Linux（Flutter 前端 + Rust Core SDK）
>
> 核心技术：Flutter、`ssh_mobile_network_native` FFI、Rust、Tokio、Quinn、TCP、UDP、WebSocket、QUIC、WebRTC
>
> 可靠性核心：一次性 ConnectionSession + Delivery/Recovery + Application ACK + Dedup + File Checkpoint/Resume

---

## 1. 项目目标

本 SDK 的目标不是简单封装某一种网络协议，而是构建一个**跨平台、协议可替换、支持直连与中继自动切换、支持实时与可靠数据、支持可选应用层端到端加密的统一网络核心**。

Flutter 层只表达业务意图，例如：

- 连接远端设备；
- 发送文件；
- 启动远程桌面；
- 发送键盘、鼠标事件；
- 同步剪贴板；
- 建立终端会话；
- 启动音视频会话。

Flutter 不直接决定：

- 使用 TCP、UDP、WebSocket、QUIC 还是 WebRTC；
- 当前是否走 P2P；
- 何时切换 Relay；
- 网络断开后如何显式重新 Resolve 并建立新的 ConnectionSession；
- 新 Connection 建立后哪些应用层数据需要恢复、重传、去重或丢弃；
- 文件如何跨新的 ConnectionSession 甚至 App 重启进行断点续传；
- 某类数据使用可靠流还是 Datagram；
- E2EE 如何加密、解密和管理密钥。

这些决策统一由 Rust SDK 完成。

---

## 2. 核心设计原则

### 2.1 Flutter 与网络实现彻底解耦

Flutter 只依赖稳定的业务 API：

```dart
await sdk.connect(peerId);
await sdk.file.send(path);
await sdk.remoteDesktop.start();
await sdk.clipboard.send(text);
await sdk.disconnect();
```

禁止在 Flutter 业务代码中出现：

```dart
quic.connect(...);
tcp.send(...);
webrtc.createPeerConnection(...);
relay.connect(...);
```

协议和路由必须属于 Rust SDK 内部实现细节。

### 2.2 ConnectionSession 与 Transport 同生命周期（v2）

这是当前架构最重要的生命周期原则。

```text
Connection = 一条具体的 Transport Connection
ConnectionSession = 一个且仅一个 Connection 对应的认证业务会话
SessionId = 当前 ConnectionSession 的一次性 wire 身份
Route = 当前 Connection 的 topology × transport 元数据
```

生命周期固定为：

```text
Connection 建立 → Identity Auth → Noise E2EE → ConnectionSession
Transport Lost → ConnectionSession Destroyed
```

每个新的 Transport Connection 都创建新的 `SessionId` 与新的 Noise root；禁止
跨 Transport 继承旧的 SessionId、CryptoContext 或 route migration 连续性。
Delivery 与 Transfer 的业务状态不属于 ConnectionSession，而是由业务 manager
按 `MessageId`/channel、`transfer_id` 与 `confirmed_offset` 跨新连接恢复。

当前实现的 ownership closeout：`PeerSupervisor` 是每个 Peer 唯一的可变连接状态
Owner；`PeerPathManager` 实际持有 Direct/Relay `PhysicalPath` 与 carrier，业务只
借用 `PathLease`；`ConnectionSessionStore` 只保存连接身份、远端 binding、admission
winner 和 security decision，不保存 route/carrier/lifecycle truth。Required E2EE
为每条新连接创建 fresh application root，Disabled 仅允许 Direct identity-only，
Relay Disabled fail closed。Stage A/B/C 依次执行纯 Direct 候选、authoritative
Resolve→Offer Direct window 和受策略/预算约束的 Relay fallback。

V2 closeout also fixes the operation boundaries: Direct Ready, Direct Probe and Relay
Ready may coexist; the first compatible path wins, an equivalent/weaker late path is
rejected, and only a demanded strict capability superset promotes the active Direct
path. Normal retirement drains existing leases, while hard close/security revoke
invalidates them immediately. Delivery acquires one lease per send and releases it
before waiting for an application ACK. Transfer resumes by `(peer_id, transfer_id)`
and confirmed offset on a new ConnectionSession; ReliableStream keeps one lease from
open through close and never transparently migrates. Authenticated passive inbound
is Online without maintenance, and maintained peers use the bounded `1/2/4/8/15/30s`
Direct recovery schedule only after Relay is ready. Native, FFI and Dart event lanes
are bounded at Control `256/4 MiB`, Data `128/8 MiB`, `1 MiB` per event, with at most
eight consecutive Control events. The frozen Relay V2 wire contract is unchanged.

### 2.3 Transport 与业务协议解耦

文件传输协议不应该写成 `QuicFilePacket`、`TcpFilePacket`。

应当是：

```text
FileChunk
   ↓
Protocol Frame
   ↓
Channel / QoS
   ↓
任意 Transport
```

这样未来从 Quinn 切换到 MsQuic，或者增加新的 Transport，不影响业务协议。

### 2.4 应用层 E2EE 独立于 Transport

用户可选择是否开启的加密，是**额外的应用层端到端加密**。

其位置固定为：

```text
业务消息
  ↓
Protocol / Serialization
  ↓
Delivery / Recovery
  ↓
Application Crypto
  ↓
Connection / Transport
```

不能把应用层 E2EE 分散写进 TCP、QUIC、WebRTC 各自实现。

### 2.5 分阶段 Direct 优先，Relay 受控兜底

一次建连 attempt 的权威策略固定为：

```text
Stage A：仅复用健康兼容路径或新鲜 Direct candidate
      ↓（仍需新连接）
Stage B：一次 Resolve → Offer，固定四秒 Direct window
      ↓（Direct 失败且策略/能力/预算均允许）
Stage C：Reserve Relay，Required E2EE 后建立新 ConnectionSession
```

业务 `ensure` 不会隐式开启 maintenance，也不会在连接存续期间透明迁移路径。
只有显式维护的 Peer 才会在网络环境变化后、Relay 已 Ready 的前提下执行有界 Direct
recovery；新 transport 始终创建新的 ConnectionSession、SessionId 与 Noise root。

### 2.6 Relay 只做透明转发

Relay 是：

```text
Data Stateless
Connection Stateful
```

即：

- 不持久化业务 Payload；
- 不解析业务协议；
- 不解密应用层 E2EE；
- 不保存文件、剪贴板、终端、音视频等内容；
- 只维护短生命周期的 ConnectionSession/transport 映射，不拥有业务恢复状态；
- 只允许有界内存 Buffer；
- 通过 Backpressure 防止无限缓存。

### 2.7 New Connection 与 Delivery Recovery 分离（v2）

必须明确：

```text
New Connection
= Resolve 后建立新的 ConnectionSession

Delivery Recovery
= 在新的 ConnectionSession 上恢复未完成的应用层业务交付
```

例如：

```text
QUIC Connection #1 / ConnectionSession #1
      X

ConnectionManager
      ↓
New QUIC Relay Connection #2 / ConnectionSession #2
      ↓
Connection Ready（new SessionId + new Noise root）
      ↓
DeliveryManager
      ├── 恢复未 ACK 的 Control Message
      ├── 去重已处理消息
      ├── 丢弃过期 Mouse/Media 数据
      └── TransferManager 恢复文件 Chunk
```

因此 Delivery/Transfer 的业务状态生命周期独立于 ConnectionSession，并在新连接上按业务 ID 恢复。


---

## 3. 最终总体架构

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│                                Flutter App                                   │
│                                                                              │
│ UI / State / ViewModel                                                       │
│                                                                              │
│ Remote Desktop / File / Terminal / Clipboard / Audio / Video                │
│                                                                              │
│ Network Settings                                                             │
│ ├─ Application E2EE: On / Off                                                │
│ └─ Relay Server: IP/Domain + Port                                             │
└────────────────────────────────┬─────────────────────────────────────────────┘
                                 │
                   ssh_mobile_network_native
                                 │
                                 ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Rust Core SDK                                   │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │ Public API                                                             │  │
│  │ connect / disconnect / file / remote / terminal / clipboard / media   │  │
│  └──────────────────────────────────┬─────────────────────────────────────┘  │
│                                     │                                        │
│  ┌──────────────────────────────────▼─────────────────────────────────────┐  │
│  │ Service Layer                                                         │  │
│  │ RemoteDesktop / File / Terminal / Clipboard / Control / Audio / Video │  │
│  └──────────────────────────────────┬─────────────────────────────────────┘  │
│                                     │                                        │
│  ┌──────────────────────────────────▼─────────────────────────────────────┐  │
│  │ Session Layer                                                         │  │
│  │ PeerSupervisor / PeerPathManager / Identity / Authentication            │  │
│  │ Capability Negotiation / Session State                                │  │
│  └──────────────────────────────────┬─────────────────────────────────────┘  │
│                                     │                                        │
│  ┌──────────────────────────────────▼─────────────────────────────────────┐  │
│  │ Protocol Layer                                                        │  │
│  │ Message / Frame / Header / Codec / Serialization / Versioning        │  │
│  └──────────────────────────────────┬─────────────────────────────────────┘  │
│                                     │                                        │
│  ┌──────────────────────────────────▼─────────────────────────────────────┐  │
│  │ Delivery / Recovery Layer                                             │  │
│  │ DeliveryManager: MessageId / ACK / Pending / Retry / Dedup / TTL     │  │
│  │ TransferManager: TransferId / Chunk / Checkpoint / Resume / Hash     │  │
│  └──────────────────────────────────┬─────────────────────────────────────┘  │
│                                     │                                        │
│  ┌──────────────────────────────────▼─────────────────────────────────────┐  │
│  │ Application Security Layer                                            │  │
│  │ CryptoManager                                                         │  │
│  │ None / E2EE / Key Exchange / AEAD / Replay Protection                │  │
│  └──────────────────────────────────┬─────────────────────────────────────┘  │
│                                     │                                        │
│  ┌──────────────────────────────────▼─────────────────────────────────────┐  │
│  │ Channel / QoS Layer                                                   │  │
│  │ Reliable Stream / Datagram / Realtime / Priority / Backpressure      │  │
│  └──────────────────────────────────┬─────────────────────────────────────┘  │
│                                     │                                        │
│  ┌──────────────────────────────────▼─────────────────────────────────────┐  │
│  │ Connection Layer                                                      │  │
│  │ ConnectionManager                                                     │  │
│  │ CandidateManager / RouteSelector / RelayManager                       │  │
│  │ Attempt / Deadline / Health Check / NAT Traversal                    │  │
│  └───────────────┬───────────────────────────────────┬────────────────────┘  │
│                  │                                   │                       │
│                  ▼                                   ▼                       │
│  ┌──────────────────────────────────┐    ┌───────────────────────────────┐   │
│  │ Generic Transport Layer          │    │ Realtime Subsystem            │   │
│  │                                  │    │                               │   │
│  │ TCP        → Tokio TcpStream     │    │ WebRTC                        │   │
│  │ UDP        → Tokio UdpSocket     │    │ ├─ ICE                        │   │
│  │ WebSocket  → WS / WSS over TCP   │    │ ├─ STUN                       │   │
│  │ QUIC       → Quinn               │    │ ├─ TURN                       │   │
│  │              ├─ Stream           │    │ ├─ RTP / SRTP                 │   │
│  │              └─ Datagram         │    │ ├─ DTLS                       │   │
│  │                                  │    │ ├─ DataChannel                │   │
│  │                                  │    │ ├─ Audio                      │   │
│  │                                  │    │ └─ Video                      │   │
│  └─────────────────┬────────────────┘    └─────────────────┬─────────────┘   │
│                    │                                       │                 │
│                    └───────────────────┬───────────────────┘                 │
│                                        ▼                                     │
│                                       OS                                     │
│                           Socket / Network Stack                              │
│                                                                              │
│ Cross-cutting: Metrics / Logging / Tracing / Config / Diagnostics           │
└──────────────────────────────────────────────────────────────────────────────┘

                       ┌────────────────────────────────────┐
                       │ Optional User-defined Relay Server │
                       │                                    │
                       │ Config: IP/Domain + Port           │
                       │                                    │
                       │ Session Registry                   │
                       │ Peer Pairing                       │
                       │ Opaque Forwarder                   │
                       │ Backpressure                       │
                       │ Rate Limit                         │
                       │ Metrics                            │
                       │                                    │
                       │ No payload decryption              │
                       │ No payload persistence             │
                       │ No file/database storage           │
                       └────────────────────────────────────┘
```

---

## 4. 各协议在架构中的定位

### 4.1 TCP

定位：传统可靠字节流、兼容性和 fallback。

适合：

- 传统服务兼容；
- 部分企业网络；
- QUIC 不可用时的降级；
- 长连接控制通道；
- 调试和基础网络能力验证。

Rust 实现：

```text
Tokio TcpStream / TcpListener
```

### 4.2 UDP

定位：底层 Datagram 能力和网络探测基础。

适合：

- Endpoint 探测；
- 自定义网络探测；
- RTT / 丢包测试；
- 特殊低延迟数据；
- 作为 QUIC / WebRTC 等协议底层基础。

Rust 实现：

```text
Tokio UdpSocket
```

裸 UDP 不应承担复杂可靠传输逻辑，避免重复实现 ACK、重传、拥塞控制、顺序恢复等 QUIC 已解决的问题。

### 4.3 WebSocket

定位：HTTP 基础设施兼容通道。

适合：

- 信令；
- 控制面连接；
- 只允许 HTTP/HTTPS 的网络环境；
- TCP fallback；
- Web 基础设施代理环境。

支持：

```text
ws://
wss://
```

注意：WebSocket 是建立在 TCP 之上的消息通道，不应作为高性能文件或实时媒体的首选。

### 4.4 QUIC

定位：SDK 的主要通用数据 Transport。

首选实现：

```text
Quinn
```

能力：

- Reliable Stream；
- Unreliable Datagram；
- 多路复用；
- 流量控制；
- 拥塞控制；
- TLS 1.3；
- 连接迁移能力。

适合：

- 文件传输；
- Terminal；
- Clipboard；
- 控制消息；
- 键盘；
- 一般业务数据；
- 低延迟 Datagram 数据。

### 4.5 WebRTC

定位：实时通信和 NAT 穿透子系统，而不是普通 Transport 的简单平级替代。

能力：

- ICE；
- STUN；
- TURN；
- RTP / SRTP；
- DTLS；
- Audio / Video；
- DataChannel。

适合：

- 远程桌面视频；
- 麦克风；
- 摄像头；
- 实时音视频；
- WebRTC DataChannel；
- NAT 场景下的 P2P 协商。

---

## 5. 业务 Service Layer

建议第一批 Service：

```text
services/
├── remote_desktop.rs
├── file.rs
├── terminal.rs
├── clipboard.rs
├── control.rs
└── media.rs
```

### 5.1 FileService

职责：

- 文件元信息协商；
- 分块；
- 进度；
- Resume；
- 校验；
- 完成确认。

默认 Channel：Reliable / Throughput 优先。

默认 Transport：QUIC Stream。

### 5.2 TerminalService

职责：

- Terminal Session；
- 输入输出；
- Resize；
- Keepalive。

默认：QUIC Stream；TCP 作为兼容 fallback。

### 5.3 ClipboardService

可靠、低流量。

默认：QUIC Stream。

### 5.4 RemoteDesktopService

需要拆成多种逻辑 Channel：

```text
Remote Desktop
├── Video
├── Audio
├── Keyboard
├── Mouse
├── Clipboard
└── Control
```

推荐：

```text
Video      → WebRTC Video
Audio      → WebRTC Audio
Keyboard   → Reliable High Priority
Mouse      → Realtime / Latest Wins
Clipboard  → Reliable
Control    → Reliable Highest Priority
```

---

## 6. Session Layer

### 6.1 ConnectionSession 模型

建议：

```rust
pub struct ConnectionSession {
    pub id: SessionId,
    pub local_peer: PeerId,
    pub remote_peer: PeerId,
    pub state: ConnectionSessionState,
    pub capabilities: NegotiatedCapabilities,
    pub crypto: CryptoContext,
    pub connection: ConnectionHandle,
}
```

### 6.2 ConnectionSession 状态

建议：

```rust
pub enum ConnectionSessionState {
    Idle,
    Negotiating,
    Connecting,
    Connected,
    Closing,
    Closed,
    Failed,
}
```

### 6.3 PeerManager

职责：

- Peer ID；
- Device ID；
- 远端能力；
- 已知 Endpoint；
- Identity 信息；
- Trust State。

---

## 7. Capability Negotiation

客户端版本不同，能力可能不同，因此建立 Session 后必须进行能力协商。

示例：

```rust
pub struct Capabilities {
    pub protocol_version: u16,
    pub transports: Vec<TransportType>,
    pub e2ee_suites: Vec<CryptoSuite>,
    pub video_codecs: Vec<VideoCodec>,
    pub audio_codecs: Vec<AudioCodec>,
    pub quic_datagram: bool,
    pub delivery_ack: bool,
    pub message_dedup: bool,
    pub recovery_handshake: bool,
    pub file_resume: bool,
    pub sparse_file_resume: bool,
}
```

协商遵循：

```text
Local Capabilities
        ∩
Remote Capabilities
        ↓
Negotiated Capabilities
```

协议升级必须优先考虑向后兼容。

---

## 8. Protocol Layer

### 8.1 统一消息模型

例如：

```rust
pub enum Message {
    Ping(Ping),
    Pong(Pong),
    MouseMove(MouseMove),
    Keyboard(KeyboardEvent),
    Clipboard(ClipboardMessage),
    FileMeta(FileMeta),
    FileChunk(FileChunk),
    FileAck(FileAck),
    TerminalData(TerminalData),
    Control(ControlMessage),
}
```

### 8.2 Packet 格式

推荐：

```text
┌────────────────────────────────────┐
│ Magic / Version                    │
│ Flags                              │
│ Session ID                         │
│ Channel ID                         │
│ Sequence                           │
│ Payload Length                     │
├────────────────────────────────────┤
│ Payload / Ciphertext               │
└────────────────────────────────────┘
```

应用层 E2EE 开启时：

```text
Header = 明文，但作为 AEAD AAD 参与认证
Payload = Ciphertext
```

这样路由层可以读取必要元数据，但无法篡改 Header 后通过认证。

### 8.3 Versioning

任何 Protocol Frame 必须带版本。

不要依赖客户端 App 版本推断协议格式。

---


## 9. Delivery / Recovery Layer

这一层是 SDK 处理**应用层断网恢复**的核心。旧 ConnectionSession 销毁后，Delivery 与 Transfer 如何在新的 ConnectionSession 上继续，属于业务 manager 的职责。

### 9.1 Transport 重传与应用层恢复的边界

```text
TCP / QUIC 内部重传
= 同一条 Connection 存活期间处理网络丢包

Delivery / Recovery
= ConnectionSession 已失效后，在新的 ConnectionSession 上按业务身份恢复状态
```

例如：

```text
Business state（MessageId / TransferId）
│
├── Message #101  ACKed
├── Message #102  SentUnacked
├── Message #103  Queued
└── File F001     62%

QUIC Connection #A
        X

ConnectionManager
        ↓
New QUIC Relay Connection #B / ConnectionSession #B
        ↓
Connection Ready（new SessionId + new Noise root）
        ↓
Delivery Recovery
        ├── 保持 #101 完成状态
        ├── 恢复 #102
        ├── 发送 #103
        └── File F001 Resume
```

### 9.2 模块划分

```text
Delivery / Recovery
│
├── DeliveryManager
│   ├── Message ID
│   ├── Application ACK
│   ├── Pending Queue
│   ├── Retry Policy
│   ├── Retry Budget
│   ├── Deduplication
│   ├── Ordering
│   ├── TTL / Expiry
│   └── Recovery Handshake
│
└── TransferManager
    ├── Transfer ID
    ├── Chunk ID
    ├── Received Range / Bitmap
    ├── Persistent Checkpoint
    ├── Resume Handshake
    ├── Hash Verification
    └── Atomic Finalize
```

`ConnectionManager` 只负责建立当前 ConnectionSession；`DeliveryManager` / `TransferManager` 负责跨 ConnectionSession 按业务 ID 继续完成业务。

### 9.3 DeliveryPolicy

建议：

```rust
pub enum DeliveryPolicy {
    /// 不持久、不重放。适用于音视频帧等实时数据。
    BestEffort,

    /// 只保留最新状态。适用于鼠标位置、部分状态同步。
    LatestState,

    /// 应用 ACK 前保持 Pending。
    Acked,

    /// ACK + 去重，允许跨 Connection 重试。
    AckedDeduplicated,

    /// 有序、Session 绑定，并带有限 TTL。
    SessionBoundOrdered,

    /// 大对象分块断点恢复。
    ResumableTransfer,
}
```

### 9.4 Pending Message

```rust
pub struct PendingMessage {
    pub message_id: MessageId,
    pub channel_id: ChannelId,
    pub sequence: u64,
    pub payload: Bytes,
    pub policy: DeliveryPolicy,
    pub state: DeliveryState,
    pub attempts: u32,
    pub created_at: Instant,
    pub expires_at: Option<Instant>,
}
```

状态：

```rust
pub enum DeliveryState {
    Queued,
    Sending,
    SentUnacked,
    Acked,
    Expired,
    Cancelled,
    Failed,
}
```

### 9.5 Application ACK

必须明确：

```text
TCP ACK / QUIC ACK
≠
Application ACK
```

应用 ACK 表示远端业务层已经接受或处理该消息。

```text
Device A                           Device B

Message #101
─────────────────────────────────→
                                   decode
                                   validate
                                   apply
                                   mark processed

ACK #101
←─────────────────────────────────

A 删除 Pending #101
```

如果 ACK 丢失：

```text
B 已处理 #101
ACK 在途中断网
A 仍认为 #101 = SentUnacked
```

重连后 A 会再次发送 #101，因此接收端必须去重。

### 9.6 去重与有效一次行为

接收端：

```text
收到 Message #101
        ↓
Dedup Window
        ↓
是否处理过？
   ┌────┴────┐
  Yes       No
   │         │
不重复执行   执行业务
   │         │
   └────┬────┘
        ↓
重新/首次发送 ACK
```

不要对外承诺理论上的绝对 Exactly Once。推荐语义：

```text
At-Least-Once Delivery
+
Message Deduplication
+
Idempotent Handler
=
Effective-Once Behavior
```

对于删除文件、创建任务等不可安全重复操作，业务命令必须携带幂等键。

### 9.7 Dedup Window

不能无限保存历史 MessageId。

```rust
pub struct DedupWindow {
    pub max_entries: usize,
    pub ttl: Duration,
}
```

建议按：

```text
Peer/Business Channel（不绑定当前 SessionId）
```

维护。

### 9.8 Ordering 与 Sequence

Ordered Channel 必须使用独立 Sequence：

```text
100
101
102
103
```

新的 ConnectionSession 使用新的 SessionId/root，但业务 Sequence 空间不能重置。

接收端维护：

```text
expected_sequence
```

恢复时根据远端状态决定：

- 已完成；
- 缺失；
- 重发；
- 丢弃过期消息。

### 9.9 TTL 与过期数据

实时交互数据必须有 TTL。

例如键盘输入如果断网 10 秒，通常不应该在恢复后把 10 秒前所有按键全部补发。

```text
Message created
      ↓
Disconnect
      ↓
New ConnectionSession
      ↓
now > expires_at ?
   ├── Yes → Expired / Drop
   └── No  → Eligible for Retry
```

### 9.10 各类业务默认 Delivery 语义

| 业务 | DeliveryPolicy | 断网后的行为 |
|---|---|---|
| Control | AckedDeduplicated | 未 ACK 则重试，接收端去重 |
| Keyboard | SessionBoundOrdered | 短 TTL；过期不重放 |
| Mouse Move | LatestState / BestEffort | 旧事件丢弃，只同步最新状态 |
| Clipboard | LatestState / Acked | 只同步最新内容或最新版本 |
| File | ResumableTransfer | Chunk/Range 断点续传 |
| Terminal | SessionBoundOrdered | 远端 PTY 存活时恢复，否则报告丢失 |
| Video | BestEffort | 不重放旧帧，恢复后请求关键帧 |
| Audio | BestEffort | 不重放旧帧 |

### 9.11 Business Recovery on a New ConnectionSession

新 Connection Ready 后直接得到新的 ConnectionSession；后续只恢复需要连续性的业务状态。

建议：

```text
Resolve → New Connection
      ↓
New ConnectionSession = Connected
      ↓
Business Recovery
      ↓
交换业务恢复快照：
- MessageId / Delivery state
- Channel sequence / last ACK
- TransferId / confirmed_offset
- 不携带旧 SessionId 或旧 Connection ciphertext
      ↓
按业务 ID 恢复 Pending / Transfer
      ↓
Business Recovery Complete
      ↓
ConnectionSession = Connected
```

### 9.12 Recovery Epoch

Recovery Epoch 属于 Delivery business state，不放在 ConnectionSession 中：

```text
recovery_epoch
```

每个 business recovery cycle 可递增，用于：

- 区分旧 Connection 延迟到达的数据；
- Crypto Epoch 管理；
- 诊断；
- 防止旧 ACK 污染新恢复周期。

### 9.13 Pending Queue 缓存什么

建议缓存：

```text
逻辑 Message / 序列化后的明文 Payload
```

不要长期缓存：

```text
旧 E2EE Ciphertext
```

因为新 Connection 可能伴随：

- Key Rotation；
- 新 Nonce State；
- 新 Crypto Epoch。

重试流程：

```text
Pending Payload
      ↓
当前 CryptoContext
      ↓
重新 encrypt
      ↓
新 Connection
```

### 9.14 Delivery Queue 必须有界

禁止网络主路径使用无限队列。

至少设置：

```text
per_channel_max_messages
per_channel_max_bytes
per_session_max_pending_bytes
global_max_pending_bytes
```

达到上限时根据 Policy：

```text
Reliable     → Backpressure
LatestState  → Replace Old
BestEffort   → Drop
```

### 9.15 Retry Budget

不要无限 retry。

```rust
pub struct RetryBudget {
    pub max_attempts: Option<u32>,
    pub deadline: Option<Instant>,
    pub max_total_retry_bytes: Option<u64>,
}
```

同时使用：

- Exponential Backoff；
- Jitter；
- Cancellation；
- Session Close 检查。

### 9.16 Delivery 与 Connection 的依赖方向

正确：

```text
DeliveryManager
      ↓
ConnectionHandle abstraction
```

禁止：

```text
DeliveryManager
      ↓
Quinn directly
```

这样才能在：

```text
QUIC → TCP → WebSocket → Relay
```

之间恢复业务而不重写 Delivery 逻辑。

---

## 10. Application Security Layer

### 10.1 定位

这是用户可选的**额外应用层 E2EE**。

注意：

- QUIC 自身仍然有 TLS 1.3；
- WebRTC 自身仍然有 DTLS/SRTP；
- 用户关闭“应用层 E2EE”不等于 QUIC/WebRTC 明文传输。

### 10.2 抽象

```rust
pub trait CryptoProvider: Send + Sync {
    fn protect(&mut self, header: &[u8], payload: &[u8]) -> Result<Vec<u8>>;
    fn unprotect(&mut self, header: &[u8], payload: &[u8]) -> Result<Vec<u8>>;
}
```

实现：

```text
NoCrypto
E2eCrypto
```

### 10.3 推荐密码学组件

不要自己发明密码算法。

推荐：

```text
Identity / Signature  → Ed25519
Key Exchange          → X25519
KDF                   → HKDF-SHA256
AEAD                  → ChaCha20-Poly1305 或 AES-256-GCM
```

也可以评估成熟的 Noise Protocol Framework。

### 10.4 必须考虑

- Nonce 唯一性；
- Sequence Number；
- Replay Protection；
- Key Rotation；
- ConnectionSession / Noise root 生命周期；
- 对端身份认证；
- 每个新 Transport Connection 使用新的 SessionId 与 Noise root，禁止继承旧 CryptoContext。

---

## 11. Channel / QoS Layer

这一层用于把“业务语义”转换成“传输语义”。

建议 Channel：

```rust
pub enum ChannelKind {
    Control,
    Interactive,
    File,
    Terminal,
    Clipboard,
    Media,
}
```

建议 QoS 属性：

```rust
pub struct ChannelPolicy {
    pub reliable: bool,
    pub ordered: bool,
    pub priority: Priority,
    pub delivery: DeliveryPolicy,
    pub discard_old: bool,
    pub max_queue: usize,
    pub ttl: Option<Duration>,
}
```

典型策略：

| Channel | 可靠 | 顺序 | 优先级 | 拥塞策略 |
|---|---:|---:|---:|---|
| Control | 是 | 是 | 最高 | Backpressure |
| Keyboard | 是 | 是 | 最高 | Backpressure |
| Mouse Move | 否 | 否/可选 | 高 | 丢旧包 |
| Clipboard | 是 | 是 | 中 | Backpressure |
| File | 是 | 是 | 低 | Backpressure |
| Media | 否/媒体协议控制 | 否 | 高 | 实时优先 |

目标：业务层只发 `Channel`，不直接依赖 Quinn Stream / Datagram。

---

## 12. Connection Layer

### 12.1 ConnectionManager

职责：

- 创建实际连接；
- 维护当前 Connection；
- 连接失败处理；
- 为当前 Connection 选择 Route；
- Resolve 后创建新的 Connection；
- 创建与销毁 ConnectionSession；
- 向 ConnectionSession manager 汇报状态；
- Connection Ready 后触发 Delivery Recovery。

不负责：

- Application ACK；
- Message 去重；
- File Resume；
- 业务级重放策略。

### 12.2 Connection 状态机

```rust
pub enum ConnectionState {
    Idle,
    Discovering,
    ConnectingDirect,
    ConnectingRelay,
    ConnectedDirect,
    ConnectedRelay,
    DirectFailed,
    Disconnected,
}
```

状态变化：

```text
Idle
 ↓
Discovering
 ↓
ConnectingDirect
 ├────成功────→ ConnectedDirect
 │
 └────未成功──→ ConnectingRelay
                  ├──成功──→ ConnectedRelay
                  └──失败──→ Disconnected
```

网络中断：

```text
Connected*
   ↓
ConnectionSession Destroyed
   ↓
下一次显式 connect → Resolve → New ConnectionSession
```

---

### 12.3 v2 Discovery 与 Direct race 不变量

`ConnectivityAttempt` 保存完整的 128-bit `RuntimeEpoch`；只有相同 epoch 的 `revision` 才能比较新旧，不同 epoch 直接替换远端 snapshot。Direct window 内，coordination channel 尚未关闭时到达的 Answer candidate 仍必须加入 race，不能因当前 candidate 队列暂时为空而提前进入 Relay。

Candidate race 使用 `(candidate_id, endpoint, generation)` 作为 attempt identity。权威 snapshot 删除尚未启动的 candidate 时从 pending queue 移除；同 ID 更新 endpoint 或 generation 时重新尝试。对支持 generic WebSocket 的路由，同一 candidate 的 TCP 与 WebSocket 并发竞争，共享 Direct deadline，不能把 WebSocket 变成 TCP 失败后的串行 fallback。

---

## 13. CandidateManager

Candidate 是“可能可用的连接方案”。

例如：

```rust
pub struct RouteCandidate {
    pub transport: TransportType,
    pub route_type: RouteType,
    pub endpoint: Endpoint,
    pub priority: i32,
    pub metrics: Option<RouteMetrics>,
}
```

可能候选：

```text
QUIC IPv6 Direct
QUIC IPv4 Direct
TCP Direct
WebSocket Direct
WebRTC P2P
QUIC Relay
TCP Relay
WebSocket Relay
TURN Relay
```

---

## 14. RouteSelector

RouteSelector 不应该简单判断：

```text
Direct > Relay
```

而应支持评分。

建议指标：

```text
RTT
Packet Loss
Bandwidth
Jitter
Handshake Cost
Transport Capability
Direct / Relay Cost
Connection Stability
```

示例：

```rust
pub struct RouteMetrics {
    pub rtt_ms: f32,
    pub loss: f32,
    pub bandwidth_mbps: f32,
    pub jitter_ms: f32,
}
```

原则：

```text
优先低延迟、稳定、满足业务能力的路线。
Direct 默认有偏好，但不是绝对优先。
```

例如 Direct RTT 350ms + 8% 丢包，而 Relay RTT 80ms，则 Relay 可以成为更优路线。

---

## 15. Direct → Relay 自动切换策略

> **2026-08-15 修订（对齐 Main 基线版，权威为准）**：本节原文的 300~800ms
> Happy Eyeballs 并行竞速**不再作为权威**。以 Main 基线版
> 《SSH_Mobile 传输网络架构重构设计 Main 基线版》§15 与
> [ADR-008](adr/ADR-008-direct-relay-race.md) 修订为准：**顺序 Direct First**——
> 先执行不依赖控制面的 Stage A fresh/configured Direct/reuse；Stage A 失败后
> 完成一次 authoritative `Resolve → Offer`，再进入固定 **4s** Direct 窗口；4s 内
> Direct Ready 用 Direct，超时（`DIRECT_FAILED`）后才启动 Relay Data。**Relay
> 不再和 Direct 并行抢跑**，也不存在 Relay→Direct 后台迁移（v2 见
> [ADR-CONNECTION-LIFECYCLE-V2](adr/ADR-CONNECTION-LIFECYCLE-V2.md)）。以下原文
> 保留为历史设计描述，不代表当前实施语义。

不要采用：

```text
Direct 等 5~10 秒
失败后
Relay
```

建议采用类似 Happy Eyeballs 的竞速策略：

```text
t = 0 ms
├── QUIC Direct IPv6
├── QUIC Direct IPv4
└── 其他 Direct Candidate

约 300~800 ms
└── Relay Candidate 启动

谁先达到“可用”状态，先使用谁。
```

后续如果更优 Direct 建立：

```text
Relay Active
   ↓
Direct Ready
   ↓
Metrics Compare
   ↓
必要时 Route Migration
```

切换时 Session 不变。

---

## 16. Relay 配置设计

### 16.1 用户侧配置

第一版用户只配置：

```text
Relay Host = IP / Domain
Relay Port = u16
```

Flutter：

```dart
RelayConfig(
  host: "relay.example.com",
  port: 4433,
)
```

Rust：

```rust
pub struct RelayConfig {
    pub host: String,
    pub port: u16,
}
```

底层建议从第一天就支持：

```rust
pub struct NetworkConfig {
    pub relays: Vec<RelayConfig>,
    pub connection: ConnectionPolicy,
    pub delivery: DeliveryConfig,
    pub qos: QosConfig,
}
```

即使 UI 第一版只展示一个 Relay。

### 16.2 用户不负责配置的内容

以下全部由 SDK 自动完成：

- Session ID；
- Peer ID；
- 配对；
- 协议版本；
- Transport 选择；
- 超时；
- 重试；
- 健康检查；
- RTT；
- E2EE；
- Relay 切换；
- Direct First 后的新连接建立；
- Backpressure。

---

## 17. Relay Server 架构

Relay Server 是独立可部署二进制。

```text
┌────────────────────────────────────┐
│ Relay Server                       │
│                                    │
│ Listener                           │
│ Session Registry                   │
│ Peer Pairing                       │
│ Authentication / Proof             │
│ Opaque Forwarder                   │
│ Backpressure                       │
│ Rate Limit                         │
│ Metrics                            │
│                                    │
│ NO Database for payload            │
│ NO File Storage                    │
│ NO Packet History                  │
│ NO Application Payload Parsing     │
│ NO Application E2EE Decryption     │
└────────────────────────────────────┘
```

### 17.1 Relay 的状态边界

允许：

```text
session_id → peer A connection
session_id → peer B connection
peer_id
connection_id
expiry
bytes rx/tx
RTT
rate limit state
```

禁止持久化：

```text
文件
剪贴板
Terminal 数据
键鼠内容
音视频帧
业务 Payload
历史 Packet
```

### 17.2 RelaySession

```rust
pub struct RelaySession {
    pub session_id: SessionId,
    pub peer_a: ConnectionHandle,
    pub peer_b: ConnectionHandle,
    pub expires_at: Instant,
    pub stats: RelayStats,
}
```

不允许出现：

```rust
messages: Vec<Message>
packets: Vec<Packet>
file_cache: ...
```

### 17.3 转发逻辑

```text
recv
 ↓
validate connection/session
 ↓
lookup target peer
 ↓
send
 ↓
释放临时 buffer
```

---

## 18. Relay Backpressure

Relay 不存储业务数据，因此必须严格实现有界缓冲和背压。

错误设计：

```text
A: 500 Mbps
Relay
B: 20 Mbps

Relay RAM 无限增长
```

正确设计：

```text
B send buffer 满
   ↓
Relay 停止/减慢读取 A
   ↓
QUIC/TCP Flow Control
   ↓
A 自动降速
```

内部所有 Channel 必须有界：

```rust
mpsc::channel(N)
```

禁止默认使用无限队列承载业务数据。

对于实时 Datagram：

```text
队列满 → 丢旧包或丢当前包
```

对于可靠 Stream：

```text
队列满 → Backpressure
```

---

## 19. Relay 协议建议

Relay Control 与 Data 分离。

例如 QUIC Relay：

```text
QUIC Connection
├── Control Stream
│   ├── Hello
│   ├── Register
│   ├── Ready
│   ├── Ping
│   ├── Pong
│   └── Close
│
├── Reliable Data Streams
│   └── opaque E2EE bytes
│
└── Datagram
    └── opaque E2EE bytes
```

控制消息示例：

```rust
pub enum RelayMessage {
    Hello { version: u16 },
    Register {
        session_id: SessionId,
        peer_id: PeerId,
        proof: Vec<u8>,
    },
    Ready,
    Ping,
    Pong,
    Close,
}
```

Relay 不需要理解上层 File/Terminal/RemoteDesktop 协议。

---

## 20. WebRTC 与 Relay 的关系

普通应用数据 Relay：

```text
QUIC / TCP / WebSocket
       ↓
自定义 Relay Server
```

WebRTC Media Relay：

```text
WebRTC
 ↓
ICE
 ├── Direct
 └── TURN
```

不要把 WebRTC 媒体强行经过自定义 QUIC Relay，除非未来明确要实现媒体转发服务。

因此数据面可理解为：

```text
Data Plane
├── QUIC Direct
├── QUIC Relay
├── TCP / WS fallback
└── ...

Realtime Media Plane
└── WebRTC
    ├── Direct ICE
    └── TURN Relay
```

---

## 21. Transport 抽象

不能过度追求让所有协议完全共用一个 Trait，但通用数据 Transport 可以有统一抽象。

建议：

```rust
#[async_trait]
pub trait Transport: Send + Sync {
    async fn connect(&self, endpoint: Endpoint) -> Result<ConnectionHandle>;
    fn transport_type(&self) -> TransportType;
}
```

Connection：

```rust
#[async_trait]
pub trait Connection: Send + Sync {
    async fn send_reliable(&self, channel: ChannelId, data: Bytes) -> Result<()>;
    async fn send_datagram(&self, channel: ChannelId, data: Bytes) -> Result<()>;
    async fn close(&self) -> Result<()>;
    fn metrics(&self) -> ConnectionMetrics;
    fn route(&self) -> Route;
}
```

注意：

- TCP 不天然支持 Datagram，可返回 Unsupported；
- WebSocket 不天然支持 QUIC 式多 Stream；
- UDP 不天然支持 Reliable；
- 不要为了“统一接口”而制造错误语义。

更推荐 Capability-based API。

---

## 22. WebRTC 不强行塞入 Generic Transport Trait

WebRTC 同时包含：

- ICE；
- STUN/TURN；
- Audio；
- Video；
- DataChannel；
- RTP/SRTP。

因此应保留独立：

```text
transport/
├── tcp
├── udp
├── websocket
└── quic

realtime/
└── webrtc
```

ConnectionManager 可以统一管理它们，但模块边界不要抹平。

---

## 23. 推荐 Rust 工程目录

```text
network-sdk/
├── Cargo.toml
└── src/
    ├── lib.rs
    │
    ├── sdk/
    │   ├── mod.rs
    │   └── api.rs
    │
    ├── services/
    │   ├── remote_desktop.rs
    │   ├── file.rs
    │   ├── terminal.rs
    │   ├── clipboard.rs
    │   ├── control.rs
    │   └── media.rs
    │
    ├── session/
    │   ├── mod.rs
    │   ├── manager.rs
    │   ├── session.rs
    │   ├── peer.rs
    │   ├── identity.rs
    │   ├── capability.rs
    │   └── state.rs
    │
    ├── protocol/
    │   ├── mod.rs
    │   ├── message.rs
    │   ├── packet.rs
    │   ├── header.rs
    │   ├── codec.rs
    │   ├── version.rs
    │   ├── control.rs
    │   ├── file.rs
    │   └── terminal.rs
    │
    ├── delivery/
    │   ├── mod.rs
    │   ├── manager.rs
    │   ├── policy.rs
    │   ├── pending.rs
    │   ├── ack.rs
    │   ├── sequence.rs
    │   ├── dedup.rs
    │   ├── retry.rs
    │   ├── recovery.rs
    │   └── store.rs
    │
    ├── transfer/
    │   ├── mod.rs
    │   ├── manager.rs
    │   ├── transfer.rs
    │   ├── chunk.rs
    │   ├── range.rs
    │   ├── checkpoint.rs
    │   ├── resume.rs
    │   ├── hash.rs
    │   └── store.rs
    │
    ├── crypto/
    │   ├── mod.rs
    │   ├── manager.rs
    │   ├── provider.rs
    │   ├── none.rs
    │   ├── aead.rs
    │   ├── handshake.rs
    │   ├── identity.rs
    │   ├── key.rs
    │   ├── nonce.rs
    │   └── replay.rs
    │
    ├── channel/
    │   ├── mod.rs
    │   ├── channel.rs
    │   ├── policy.rs
    │   ├── priority.rs
    │   └── backpressure.rs
    │
    ├── connection/
    │   ├── mod.rs
    │   ├── manager.rs
    │   ├── connection.rs
    │   ├── candidate.rs
    │   ├── route.rs
    │   ├── selector.rs
    │   ├── reconnect.rs
    │   ├── migration.rs
    │   └── health.rs
    │
    ├── transport/
    │   ├── mod.rs
    │   ├── traits.rs
    │   ├── tcp/
    │   │   ├── mod.rs
    │   │   └── connection.rs
    │   ├── udp/
    │   │   ├── mod.rs
    │   │   └── socket.rs
    │   ├── websocket/
    │   │   ├── mod.rs
    │   │   └── connection.rs
    │   └── quic/
    │       ├── mod.rs
    │       ├── endpoint.rs
    │       ├── connection.rs
    │       ├── stream.rs
    │       └── datagram.rs
    │
    ├── realtime/
    │   └── webrtc/
    │       ├── mod.rs
    │       ├── peer_connection.rs
    │       ├── ice.rs
    │       ├── signaling.rs
    │       ├── media.rs
    │       ├── audio.rs
    │       ├── video.rs
    │       └── data_channel.rs
    │
    ├── relay/
    │   ├── mod.rs
    │   ├── config.rs
    │   ├── manager.rs
    │   ├── client.rs
    │   ├── protocol.rs
    │   └── health.rs
    │
    ├── metrics/
    │   ├── mod.rs
    │   ├── rtt.rs
    │   ├── bandwidth.rs
    │   ├── loss.rs
    │   ├── jitter.rs
    │   └── stats.rs
    │
    ├── config/
    │   └── network.rs
    │
    ├── diagnostics/
    │   ├── logging.rs
    │   └── tracing.rs
    │
    └── ffi/
        ├── mod.rs
        ├── api.rs
        ├── events.rs
        └── types.rs
```

Relay Server 建议独立 Workspace package：

```text
relay-server/
├── Cargo.toml
└── src/
    ├── main.rs
    ├── server.rs
    ├── listener.rs
    ├── session.rs
    ├── registry.rs
    ├── auth.rs
    ├── protocol.rs
    ├── forwarder.rs
    ├── backpressure.rs
    ├── rate_limit.rs
    └── metrics.rs
```

---

## 24. Flutter 侧目录建议

```text
lib/
├── features/
│   ├── remote_desktop/
│   ├── file_transfer/
│   ├── terminal/
│   ├── clipboard/
│   └── settings/
│
├── network/
│   ├── sdk.dart
│   ├── models.dart
│   ├── state.dart
│   └── events.dart
│
└── generated/
    └── rust_bridge/
```

Flutter 侧不能复制一份 Rust 的连接状态机。

Rust 是网络状态的 Source of Truth，Flutter 只订阅状态事件。

### 24.1 Flutter 通用客户端接口层

Flutter 层可以提供面向业务的通用 Client Facade，用于区分访问策略和
生命周期，但不应按 QUIC、TCP、WebSocket 等具体 Transport 暴露客户端。
推荐的边界如下：

```text
Flutter Feature / ViewModel
            ↓
Flutter Client Facade
├── BootstrapClient          无 Bearer 鉴权的公开/引导请求
├── AuthenticatedApiClient   带鉴权的控制面请求
├── EventStreamClient        Rust SDK 统一事件流
└── SessionClient            设备业务会话和业务操作
            ↓
      App Shell Adapters
      ├── SdkRequestExecutor → Control Plane HTTP
      └── NetworkCommandGateway → Runtime-owned Network Protocol V2 Native SDK
```

客户端职责建议：

- `BootstrapClient`：处理公开探测、版本/能力查询、登录或注册引导、Relay
  enrollment 等不依赖已建立 Bearer Session 的请求。请求中的密码、密钥或
  enrollment secret 仍属于敏感数据，不能写入日志或普通持久化存储。
- `AuthenticatedApiClient`：处理控制面 API 的 Bearer Token 注入、Token
  刷新、鉴权失败映射、请求取消和超时。Token 由安全存储和专用
  `AuthSessionProvider` 管理，不能暴露给业务 Widget。
- `EventStreamClient`：暴露 Rust SDK 的 `SdkEvent` 流，并负责订阅、取消、
  生命周期和有界事件处理。它不是 Flutter 侧的裸 WebSocket/QUIC 客户端。
- `SessionClient`：提供 `connect(peer)`、`disconnect(session)`、文件、终端、
  剪贴板和远控等业务 API。Peer 身份认证、Resolve、Transport 选择和
  ConnectionSession 生命周期由 Rust SDK 完成；Delivery/Transfer 按业务 ID 恢复。

示例接口可以保持粗粒度：

```dart
abstract interface class BootstrapClient {
  Future<BootstrapMetadata> probe(Uri endpoint);
  Future<DeviceEnrollment> enroll(Uri endpoint, EnrollmentRequest request);
}

abstract interface class AuthenticatedApiClient {
  Future<UserProfile> getProfile();
  Future<RelayConfig> saveRelayConfig(RelayConfig config);
}

abstract interface class SessionClient {
  Stream<SdkEvent> get events;
  Future<SessionInfo> connect(PeerId peerId);
  Future<void> disconnect(SessionId sessionId);
  Future<TransferInfo> sendFile(SessionId sessionId, String path);
}
```

鉴权策略、连接生命周期和底层 Transport 是三个正交维度，不建议组合出
`AuthenticatedSocketClient`、`UnauthenticatedSocketClient`、
`RelaySocketClient` 等大量类型。只有控制面确实需要 Flutter 直接维护的
HTTP/WebSocket 长连接时，才增加对应的 App Shell Adapter；网络数据面的
Socket 始终由 Rust Core SDK 持有，Flutter 只消费统一状态和事件。

当前开发实现已经将 `SdkRequestExecutor`、`JsonBootstrapClient` 和
`JsonAuthenticatedApiClient` 放入 `packages/infrastructure/network_sdk/`；App
Shell 负责提供真正的 HTTP/TLS 执行器，LAN Feature 只接收注入的
`BootstrapClient`。网络数据面使用 Network Protocol V2 `NetworkCommandGateway`，不在 Flutter
层新增第二套 Socket 或协议实现。

---

## 25. FFI 边界设计

FFI API 应保持粗粒度。

推荐：

```text
connect(peer)
disconnect(session)
send_file(session, path)
start_remote_desktop(session)
stop_remote_desktop(session)
send_clipboard(session, data)
open_terminal(session)
set_network_config(config)
```

避免：

```text
ffi_quic_open_stream()
ffi_udp_send_packet()
ffi_tcp_write()
```

底层 Transport API 不应暴露给 Flutter。

Rust → Flutter 建议统一事件流：

```rust
pub enum SdkEvent {
    SessionStateChanged(...),
    RouteChanged(...),
    NetworkQualityChanged(...),
    FileProgress(...),
    RemoteDesktopState(...),
    Error(...),
}
```

---

### 25.1 ReliableStream 的 FFI 业务身份

FFI 与 App 事件不能只携带 `(peer_id, stream_id)`。逻辑流使用稳定的 `StreamHandle = (opener_device_id, stream_id)`，并把该 handle 同时放入 `StreamOpened`（由 `SshStreamOpen` + accepted `CommandResult` 表达）、`StreamDataReceived`、`StreamClosed` 以及 Send/Close command。Native 内部仍可使用 `StreamKey { opener, stream_id }`，但 App 路由必须按完整 handle 查找，允许双方同时打开相同数字 `stream_id`。

## 26. Metrics 与 Observability

Metrics 不是后期附加功能，应从第一版设计。

至少记录：

```text
RTT
Jitter
Packet Loss
Bandwidth Estimate
Bytes Sent / Received
Current Transport
Current Route
Direct / Relay
ConnectionSession Created Count
Handshake Duration
Recovery Duration
Pending Message Count
Pending Bytes
Message Retry Count
Dedup Hit Count
Transfer Resume Count
Transfer Retransmitted Bytes
Queue Depth
Dropped Realtime Packets
```

Flutter UI 可以展示：

```text
连接方式：QUIC Relay
RTT：82ms
Loss：0.3%
带宽：45 Mbps
```

日志严格禁止默认打印：

- Payload；
- 文件内容；
- 剪贴板内容；
- Terminal 命令内容；
- E2EE Key。

---

## 27. 错误模型

不要把所有错误变成字符串。

建议：

```rust
pub enum NetworkError {
    ResolveFailed,
    ConnectTimeout,
    ConnectionRefused,
    TransportUnavailable,
    ProtocolMismatch,
    AuthenticationFailed,
    CryptoFailed,
    RelayUnavailable,
    PeerUnavailable,
    RouteExhausted,
    ConnectionLost,
    UnsupportedCapability,
    Internal,
}
```

错误应标记：

```text
Retryable
NonRetryable
UserActionRequired
```

例如：

```text
ConnectTimeout → Retryable
RelayConfigInvalid → UserActionRequired
ProtocolMismatch → NonRetryable
```

---

## 28. 配置模型

建议统一：

```rust
pub struct NetworkConfig {
    pub application_e2ee: bool,
    pub relays: Vec<RelayConfig>,
    pub preferred_transports: Vec<TransportType>,
    pub allow_tcp_fallback: bool,
    pub allow_websocket_fallback: bool,
    pub connection_policy: ConnectionPolicy,
}
```

第一版 UI 不需要暴露全部字段。

高级配置可以以后逐步开放。

---

## 29. 推荐默认协议策略

### 通用业务数据

```text
优先：QUIC
fallback：TCP / WebSocket
```

### 文件

```text
QUIC Stream
↓
TCP fallback
↓
WebSocket fallback（必要时）
```

### 控制消息

```text
Delivery：AckedDeduplicated
应用层：MessageId + ACK + Dedup
QUIC Reliable Stream
↓
TCP / WSS
```

### 鼠标实时移动

```text
Delivery：LatestState / BestEffort
断网恢复：不重放旧 MouseMove
QUIC Datagram
或
WebRTC DataChannel
```

### 音视频

```text
Delivery：BestEffort
断网恢复：丢弃旧帧，重新建立媒体时间线/请求关键帧
WebRTC
```

### 信令

```text
WebSocket / WSS
```

### Relay

推荐优先：

```text
QUIC Relay
```

并保留：

```text
TCP Relay
WebSocket Relay
```

作为复杂网络环境 fallback。

---

## 30. 一次完整连接流程

```text
Flutter
  │
  │ sdk.connect(peer)
  ▼
SessionManager
  │
  ├── 创建 Session
  ├── 获取 Peer 信息
  ├── Capability Negotiation
  └── 初始化 CryptoContext
  │
  ▼
ConnectionManager
  │
  ▼
CandidateManager
  │
  ├── QUIC Direct IPv6
  ├── QUIC Direct IPv4
  ├── TCP Direct
  ├── WebSocket
  ├── WebRTC Candidate
  └── Configured Relay Candidates
  │
  ▼
RouteSelector
  │
  ├── 立即尝试 Direct
  │
  └── 延迟数百 ms 启动 Relay
  │
  ▼
First Usable Route
  │
  ▼
Connection Established
  │
  ▼
ConnectionSession Connected（new SessionId + new Noise root）
  │
  ▼
Flutter 收到 Connected Event
```

Transport loss 后：

```text
ConnectionSession Destroyed
      ↓
业务状态保留在 DeliveryManager / TransferManager
      ↓
下一次显式 connect → Resolve
      ↓
New ConnectionSession
      ↓
Delivery/Transfer 按 MessageId、transfer_id 恢复
```

---

## 31. 数据发送 Pipeline

普通业务数据：

```text
Flutter Business Action
      ↓
Service Layer
      ↓
Message
      ↓
Protocol Serialize
      ↓
Packet/Header
      ↓
Application Crypto
      ↓
Channel / QoS
      ↓
ConnectionManager
      ↓
Current Route
      ↓
TCP / UDP / WebSocket / QUIC / WebRTC DataChannel
```

接收方向完全反向。

---

## 32. 文件传输示例

```text
send_file(path)
    ↓
FileService
    ↓
FileMeta
    ↓
FileChunk #1/#2/#3...
    ↓
Protocol Codec
    ↓
Application E2EE
    ↓
File Channel
    ↓
Reliable / Low Priority / High Throughput
    ↓
QUIC Stream
    ↓
Direct 或 Relay
```

Transport loss 时：

```text
File Transfer State 保持在 TransferManager
ConnectionSession 销毁
Resolve 后建立新 ConnectionSession
根据 transfer_id 与 confirmed_offset Resume
```

因此文件协议必须支持：

```text
Transfer ID
Chunk ID / Offset
Received Range / Bitmap
Checkpoint
ResumeRequest / ResumeState
Hash Verification
Atomic Finalize
```

断点状态属于客户端 `TransferManager`，不属于 Relay。

如果要求 App 被杀或设备重启后仍能继续，Checkpoint 需要本地持久化。

接收端建议先写：

```text
filename.part
```

完成 Hash 校验后再原子 rename 到最终文件。

---

## 33. Remote Desktop 示例

```text
RemoteDesktop Session
│
├── Video Channel
│    └── WebRTC Video
│
├── Audio Channel
│    └── WebRTC Audio
│
├── Keyboard Channel
│    └── Reliable Highest Priority
│
├── Mouse Channel
│    └── Realtime / discard old
│
├── Clipboard Channel
│    └── Reliable
│
└── Control Channel
     └── Reliable Highest Priority
```

不要让大文件传输挤压鼠标和键盘控制。

QoS 层必须保证 Interactive Traffic 优先于 Bulk Traffic。

---

## 34. 安全要求

必须实现：

- Peer Identity；
- Session Authentication；
- Relay Session 防冒用；
- Replay Protection；
- 协议长度检查；
- Payload 上限；
- Bounded Queue；
- Rate Limit；
- Handshake Timeout；
- Connection Limit；
- Fuzz Test Protocol Codec。

严禁：

- 自创密码算法；
- E2EE Key 写日志；
- Relay 保存业务 Payload；
- 通过无限队列解决拥塞；
- Flutter 直接持有底层裸 Connection 指针；
- 远端可控长度字段不做边界检查。

---

## 35. 测试体系

### 35.1 Unit Test

覆盖：

```text
Protocol Codec
Packet Header
Crypto Provider
Replay Window
Route Score
State Machine
Channel Policy
Relay Protocol
```

### 35.2 Integration Test

至少模拟：

```text
Direct QUIC success
Direct failure → Relay success
Relay failure
QUIC → TCP fallback
QUIC → WebSocket fallback
Connection drop → Resolve → new ConnectionSession
Connection Ready → Delivery Recovery
ACK lost → resend + dedup
Pending message across fresh ConnectionSessions
TTL expired message is not replayed
Direct/Relay fallback without route migration
File resume
App kill → persistent file resume
E2EE on/off
Protocol version mismatch
```

### 35.3 Network Fault Test

必须测试：

```text
高 RTT
高丢包
抖动
限速
断网
Wi-Fi → Cellular
NAT
IPv4 only
IPv6 only
UDP blocked
TCP only
HTTP proxy environment
```

Linux 可使用 `tc netem` 进行网络故障注入。

### 35.4 Relay Load Test

关注：

```text
并发连接数
并发 Session
吞吐量
内存/连接
Backpressure
慢接收端
Datagram 丢弃策略
CPU
FD 数量
```

---

## 36. 性能设计原则

1. Payload 尽量使用 `Bytes` / zero-copy friendly buffer；
2. FFI 避免高频小消息反复跨语言复制；
3. Mouse 等高频事件可批处理或 latest-only；
4. 文件传输必须流式处理，不读取整个文件进内存；
5. Relay 所有转发 Queue 必须 bounded；
6. QUIC Stream 数量需要限制；
7. Metrics 采样不能成为热路径瓶颈；
8. 日志必须支持生产环境降级；
9. 视频帧不要经过 Flutter → Rust 高频复制链路，尽量走原生媒体管线。

---

## 37. 第一阶段禁止过度设计

虽然完整设计需要覆盖：

```text
TCP
UDP
WebSocket
QUIC
WebRTC
Relay
E2EE
显式重建 ConnectionSession
```

但不要一次性全部实现。

架构要完整，开发要增量。

---

## 38. 推荐开发路线

### Phase 0：工程骨架

实现：

- Rust workspace；
- `ssh_mobile_network_native` FFI；
- Config；
- Error model；
- Event Bridge；
- Logging / Tracing。

验收：Flutter 可以稳定启动 Rust Core，并接收网络事件。

### Phase 1：QUIC 主链路

实现：

- Quinn Endpoint；
- Connection；
- Stream；
- Datagram；
- basic metrics。

验收：两个客户端可稳定双向通信。

### Phase 2：ConnectionSession / Protocol / Connection 抽象

实现：

- ConnectionSessionStore；
- ConnectionSession = exactly one Transport Connection；
- MessageEnvelope；
- Protocol Codec；
- Capability Negotiation；
- ConnectionManager；
- State Machine。

验收：销毁并重建 Connection 会创建新的 ConnectionSession、SessionId 与 Noise
root，但 Delivery/Transfer 业务状态仍可按业务 ID 恢复。

### Phase 3：Delivery / Recovery Core

实现：

- MessageId；
- Sequence；
- Application ACK；
- Pending Queue；
- DeliveryPolicy；
- Dedup Window；
- TTL；
- Retry Budget；
- Business Recovery Handshake。

验收：

```text
发送 ACK_REQUIRED 消息\n强制断网\n建立新 Connection（新 ConnectionSession、SessionId、Noise root）\n按 MessageId/channel 恢复未 ACK 消息\n接收端不会重复执行业务
```

### Phase 4：File Transfer + Persistent Resume

实现：

- TransferId；
- Chunk；
- Range / Bitmap；
- Checkpoint；
- Resume；
- Hash；
- .part 文件；
- Atomic Finalize；
- App restart recovery。

验收：大文件在 Direct/Relay fallback、断网或 App 重启后，均可在新的
ConnectionSession 上按 transfer_id 与 confirmed_offset 继续，最终 Hash 一致。

### Phase 5：Relay

实现：

- 用户 Host + Port；
- Relay Client；
- Relay Server；
- Session Pairing；
- Opaque Forward；
- Bounded Buffer；
- Backpressure；
- Rate Limit；
- Direct First 后显式 Relay fallback（创建新的 ConnectionSession）。

验收：Relay 不解析、不持久化业务 Payload。

### Phase 6：TCP / UDP / WebSocket fallback

实现：

- TCP；
- UDP Probe；
- WebSocket / WSS；
- Candidate integration。

验收：QUIC 被阻断时可选择兼容路径并创建新的 ConnectionSession。

### Phase 7：Application E2EE

实现：

- Identity；
- Handshake；
- CryptoProvider；
- Key lifecycle；
- AEAD；
- Replay Protection；
- Key Rotation。

验收：Relay 无法读取业务内容；Recovery 后 Pending 数据使用新
ConnectionSession 的 Noise root/CryptoContext 重新加密。

### Phase 8：RouteSelector + Metrics + Explicit Reconnect

实现：

- Route Score；
- RTT / Loss / Jitter / Bandwidth；
- background probing；
- 新 Connection 建立时的 Direct/Relay route selection；
- multi-relay。

验收：每次新 Connection 都创建新的 ConnectionSession、SessionId 与 Noise
root；Delivery/Transfer 的 MessageId、TransferId 和业务状态跨连接保持。

### Phase 9：WebRTC

实现：

- Signaling；
- ICE；
- STUN；
- TURN；
- DataChannel；
- Audio；
- Video。

验收：NAT 环境中可完成实时媒体连接。

### Phase 10：完整远控 QoS

实现：

- Channel priority；
- Mouse Latest-Wins；
- Keyboard Short-TTL Ordered；
- File low-priority throughput；
- Media realtime policy；
- Dynamic route intent。

验收：文件大流量不会明显阻塞控制和交互事件。

---

## 39. 架构决策记录（ADR）建议

后续重要选型不要只改代码，应创建 ADR，例如：

```text
docs/adr/
├── 0001-use-rust-core-sdk.md
├── 0002-use-quinn-for-quic.md
├── 0003-session-connection-separation.md
├── 0004-relay-is-opaque-forwarder.md
├── 0005-application-e2ee-layer.md
└── 0006-webrtc-as-realtime-subsystem.md
```

每个 ADR 记录：

```text
Context
Decision
Alternatives
Consequences
```

---

## 40. 开发时的模块依赖规则

推荐依赖方向：

```text
Flutter
  ↓
FFI
  ↓
SDK API
  ↓
Services
  ↓
Session
  ↓
Protocol / Crypto / Channel
  ↓
Connection
  ↓
Transport / Realtime / Relay
  ↓
OS
```

禁止反向依赖，例如：

```text
transport/quic → services/file        ❌
relay/server → remote_desktop         ❌
protocol → Flutter                    ❌
crypto → Quinn                        ❌
```

底层模块不能知道具体业务。

---

## 41. Definition of Done：一个 Transport 接入完成的标准

新增 Transport 时至少完成：

- 接口实现；
- Connect / Close；
- 能力声明；
- 错误映射；
- Metrics；
- Timeout；
- Cancel Safety；
- Backpressure；
- Integration Test；
- RouteSelector 注册；
- Fallback Test；
- 日志无敏感 Payload；
- 文档更新。

---

## 42. Definition of Done：Delivery / Recovery 完成标准

必须全部满足：

- MessageId 在 Delivery business scope/channel 内唯一；
- Ordered Channel 有独立 Sequence；
- 支持 Application ACK；
- ACK 丢失后可安全重发；
- 接收端具备 Dedup Window；
- 需要幂等的命令有业务幂等键；
- Pending Queue 有消息数和字节数上限；
- TTL 到期消息不会断网后重放；
- Transport loss 销毁 ConnectionSession，随后在新 ConnectionSession 上执行 Business Recovery；
- 每个新 Connection 都创建新的 SessionId 与 Noise root；
- Delivery State 不依赖某一条具体 Connection；
- 新 ConnectionSession 不会重置业务 MessageId / Sequence；
- 能测试 ACK lost、duplicate、reorder、disconnect；
- Metrics 可观察 Pending、Retry、Dedup、Recovery Duration。

---

## 43. Definition of Done：File Resume 完成标准

必须全部满足：

- TransferId 独立于 ConnectionSession；
- 支持 Chunk ID / Offset；
- 支持 Received Range 或 Bitmap；
- 支持 ResumeRequest / ResumeState；
- 只重传缺失 Chunk；
- Checkpoint 可持久化；
- App 被杀后可以恢复 Transfer；
- 能检测源文件变化；
- 接收端使用 `.part` 临时文件；
- 完成后进行 Hash 校验；
- 最终文件采用原子 finalize；
- Relay 不保存任何 Resume State；
- 支持 Direct/Relay fallback 或 transport loss 后，在新的 ConnectionSession 上
  继续同一 Transfer。

---

## 44. Definition of Done：Relay 功能完成标准

Relay 功能只有满足以下条件才算完成：

- 用户只需 Host + Port；
- SDK 自动连接；
- SDK 自动注册 Session；
- SDK 自动配对；
- Direct 不可用自动切 Relay；
- Relay 不解析业务 Payload；
- Relay 不持久化业务数据；
- Queue 有界；
- 慢端有 Backpressure；
- Session 结束立即清理；
- Relay 掉线可重连；
- 有基本限流；
- 有 Metrics；
- 有负载测试。

---

## 45. 最终技术定位

整个系统可概括为：

```text
Flutter
= UI + 状态展示 + 用户业务操作

Rust Core SDK
= 跨平台网络核心

Service
= 用户想做什么

Session
= 用户正在和谁进行一次业务会话

Protocol
= 数据如何表示

Application Crypto
= 是否进行额外 E2EE

Channel / QoS
= 数据需要什么传输语义

Connection
= 当前真实网络连接

CandidateManager
= 有哪些可能的连接方式

RouteSelector
= 当前应该走哪条路

QUIC
= 通用数据主力协议

TCP
= 传统兼容 / fallback

UDP
= Datagram / 底层探测能力

WebSocket
= HTTP 环境 / 信令 / fallback

WebRTC
= P2P + NAT Traversal + Realtime Media

Relay
= 用户可自托管、无业务数据持久化的透明转发节点
```

最终目标不是让上层知道所有协议，而是做到：

```text
Flutter：
“我要连接设备 B，并发送文件。”

Rust SDK：
“当前 QUIC Direct 不通，按 Direct First 规则在窗口后启动 Relay；
 新 transport 建立新的 ConnectionSession、SessionId 和 Noise root；
 文件使用 Reliable File Channel；E2EE 已开启；
 连接断开后 Delivery/Transfer 按业务 ID 在新 ConnectionSession 上恢复。”
```

这才是该网络传输 SDK 的核心价值。

---

## 46. 最终架构结论

本项目后续开发应始终遵循以下十二条硬性原则：

1. **Flutter 不直接操作具体网络协议。**
2. **ConnectionSession 与 Transport 1:1 同生命周期；每个新 Transport 都使用新的 SessionId 与 Noise root。**
3. **业务 Protocol 与 Transport 解耦。**
4. **Transport 重传与应用层 Delivery Recovery 是两套机制。**
5. **Transport loss 销毁 ConnectionSession；Delivery/Recovery 负责在新 ConnectionSession 上恢复未完成业务。**
6. **Application ACK、MessageId、Dedup 是跨 Connection 可靠交付的基础。**
7. **文件使用 TransferId + Chunk/Range + Checkpoint + Resume，不使用简单 Message Retry。**
8. **应用层 E2EE 独立于 TCP/UDP/WebSocket/QUIC/WebRTC；每个新 ConnectionSession 使用新的 Noise root，重试数据重新加密。**
9. **QUIC 作为通用数据主力，WebRTC 作为实时通信子系统，TCP/WebSocket 为兼容和 fallback，UDP 为底层 Datagram 能力。**
10. **Direct 优先但不绝对；RouteSelector 在每次新 Connection 建立时根据能力和业务意图选择路线，连接存续期间不做 route migration。**
11. **Relay 只做临时透明转发，不持久化、不解密业务数据，也不保存 Resume 状态。**
12. **所有 Queue 有界；所有业务显式定义 DeliveryPolicy，禁止“所有失败数据一律重传”。**

后续所有代码设计、模块评审和协议接入，都应以本文件为架构基线；若出现与本文冲突的重大设计变更，应通过 ADR 明确记录原因和影响。


---

## 附录 A：应用层断网恢复检查清单

开发任何新业务 Channel 时，必须回答：

1. 该数据是否允许丢失？
2. 是否要求有序？
3. 是否需要 Application ACK？
4. ACK 丢失后是否允许重发？
5. 重发是否会造成副作用？
6. 是否需要 MessageId 去重？
7. 是否需要业务幂等键？
8. 数据多久后过期？
9. Connection 重建后是重放、恢复、同步最新状态还是直接丢弃？
10. 是否需要跨 App 重启持久化？
11. 最大 Pending 消息数和字节数是多少？
12. 新 ConnectionSession 后 MessageId / Sequence / TransferId 是否按业务语义保持？

没有回答完这些问题，不允许把新业务标记为“支持断网恢复”。

---

## 附录 B：推荐业务策略速查表

| 场景 | DeliveryPolicy | ACK | 去重 | TTL | 持久化 | 推荐通道 |
|---|---|---:|---:|---:|---:|---|
| 文件 | ResumableTransfer | Chunk/Range | Transfer 级 | 长 | 是 | QUIC Stream |
| 控制命令 | AckedDeduplicated | 是 | 是 | 中 | 视业务 | QUIC Stream |
| 剪贴板 | LatestState/Acked | 可选/是 | 版本号 | 中 | 否 | QUIC Stream |
| 键盘 | SessionBoundOrdered | 可选/是 | Sequence | 短 | 否 | QUIC Stream/DataChannel |
| 鼠标移动 | LatestState | 否 | 否 | 极短 | 否 | QUIC Datagram/DataChannel |
| Terminal | SessionBoundOrdered | 流级/应用级 | Sequence | Session | 视实现 | QUIC Stream/TCP |
| 视频 | BestEffort | 否 | 否 | 极短 | 否 | WebRTC |
| 音频 | BestEffort | 否 | 否 | 极短 | 否 | WebRTC |
| Signaling | AckedDeduplicated | 是 | 是 | 中 | 否 | WebSocket/WSS |

---

## 附录 C：最终核心数据路径

### C.1 普通可靠业务

```text
Flutter
  ↓
Service
  ↓
Session
  ↓
Protocol
  ↓
DeliveryManager
  ↓
Application Crypto
  ↓
Channel / QoS
  ↓
ConnectionManager
  ↓
RouteSelector
  ↓
QUIC / TCP / WebSocket / WebRTC DataChannel
```

### C.2 文件

```text
Flutter
  ↓
FileService
  ↓
TransferManager
  ↓
Chunk / Range / Checkpoint
  ↓
Application Crypto
  ↓
Reliable Channel
  ↓
QUIC Stream（优先）
  ↓
Direct / Relay
```

### C.3 实时媒体

```text
Flutter
  ↓
RemoteDesktop / MediaService
  ↓
Realtime WebRTC Subsystem
  ↓
ICE / STUN / TURN
  ↓
RTP / SRTP
  ↓
Audio / Video
```

### C.4 断网恢复

```text
Transport Lost
      ↓
ConnectionSession = Destroyed
      ↓
Resolve / ConnectivityAttemptCoordinator
      ↓
Direct First → Relay fallback
      ↓
New Connection Ready（new SessionId + new Noise root）
      ↓
New ConnectionSession = Connected
      ↓
DeliveryManager + TransferManager
      ├── Ack/Dedup Recovery
      ├── Pending Retry
      ├── TTL Drop
      ├── Latest-State Sync
      └── File Resume
      ↓
Business Recovery Complete
      ↓
ConnectionSession remains Connected
```
