最新更新时间：2026-09-04

# ADR-034：WebRTC 实时屏幕共享媒体边界与生命周期

## 状态

Accepted（Phase 0～Phase 7 架构冻结；本 ADR 批准约束，不表示产品实现已经完成）。

本 ADR 是现有 WebRTC Realtime 子系统的屏幕共享媒体扩展。它扩展
[ADR-016](ADR-016-webrtc-media-qos.md)、[ADR-020](ADR-020-webrtc-runtime.md)、
[ADR-021](ADR-021-native-dart-realtime-api.md)、[ADR-024](ADR-024-webrtc-data-plane.md)、
[ADR-026](ADR-026-realtime-command-completion-correlation.md) 和
[ADR-BUSINESS-RECOVERY-V2](ADR-BUSINESS-RECOVERY-V2.md)；不重写、撤销或悄然改变这些
Accepted 决策。凡本文标为“计划”的内容，必须在对应 Phase 实现并通过该 Phase 的
契约与验收门禁后，才能称为当前行为。

本 ADR 只冻结 `docs/NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md` 中 M8（RTC）的
Screen Share slice；M8 中 Voice、Camera/一般 Video 或其他 RTC 工作不在本文范围，
也不因本文 Accepted 而视为已经交付。它们如需改变既有边界，必须分别提交 ADR 与
验收门禁。

## 背景与当前事实

现有基线已经提供以下能力：

- native-only `network-webrtc` crate 持有 sans-I/O WebRTC PeerConnection，处理
  SDP、ICE/STUN/TURN、DTLS/SRTP、RTP/RTCP、Audio/Video transceiver 和
  DataChannel；`RealtimeIoDriver` 将它与一个 UDP socket 和有界 I/O loop 绑定。
- native `network-core` 有一个 App-owned `RealtimeManager`；现有 protobuf
  command/event ABI 支持 start、stop、state 和 WebRTC signaling。Relay control
  plane 只转发经认证、大小受限的 signaling。当前 runtime start path 只创建
  DataChannel；crate 能加入 Video SDP transceiver 不等于 runtime 已有 encoded-video
  RTP ingress 或 egress。
- Dart 侧 API 隐藏 WebRTC 对象、socket、FFI handle 和 SDP/ICE 细节；App Shell
  adapter 负责把 native 事件映射为 `network_sdk` 的 Realtime contract，并按
  [ADR-026](ADR-026-realtime-command-completion-correlation.md) 区分队列接受、
  native 完成和 session 终态。
- 当前 `network_sdk` 还保留 `RealtimeVideoFrame` / `remoteVideo` 的
  `Uint8List` 历史占位契约，现有 native adapter 没有 producer，测试只注入合成
  bytes。它不是可用的视频媒体路径，screen share 不得消费或扩展它；Phase 2 必须
  在兼容性清单约束下迁移或 retire 该占位契约，并以 opaque endpoint/surface
  contract 替代。
- [ADR-BUSINESS-RECOVERY-V2](ADR-BUSINESS-RECOVERY-V2.md) 已规定 WebRTC 断线时旧
  Realtime/PeerConnection 终止，恢复必须建立新的连接与 session，而不是透明复用旧
  对象。
- 当前 `network-webrtc` 的媒体 QoS 是通用的有界 `MediaFrame` 队列；截至本 ADR
  日期，其默认 video policy 仍是四帧，并非本 ADR 规定的 screen-share 三帧契约。
  当前 Peer 也注册 rtc 默认 codec 集合，并不等于 H.264-only 屏幕共享已经实现。

下列能力在当前基线中尚不存在，属于本 ADR 冻结的后续计划：平台屏幕采集与硬件
H.264 编码、native encoded-media bridge、native 解码与 Flutter Texture、
screen-share 专用三帧队列、业务级 incoming consent，以及生产用短期 TURN credential
签发。Phase 0 只写架构和 ADR，不实现这些产品代码。

## 决策

### 1. 范围与唯一 WebRTC Owner

Phase 0～Phase 7 只冻结两个已认证 Peer 之间的 1:1、一条 Screen Video Track。
屏幕共享是一个独立的 `ScreenShareOperation` Business Operation，底层仍使用现有
`RealtimeSession`；它不是 SSH、SFTP、Delivery、Transfer 或 `RelayDataFrame` 的
新载荷类型。

整个产品进程只允许一个 App-owned `NetworkRuntime`/`NetworkFacade`。唯一的
WebRTC PeerConnection Owner 是：

```text
native/network_core/crates/network-webrtc
```

`network-core::RealtimeManager` 负责 session 注册、信令协调和与运行时的连接；每个
Realtime session 的 `WebRtcPeer` 与 UDP socket 继续由同一个
`RealtimeIoDriver` 持有。不得新增 `flutter_webrtc` PeerConnection、第二个 WebRTC
runtime、第二个 ICE/STUN/TURN owner、第二个 signaling server 或另一个 screen
WebRTC crate。

Feature 只负责业务状态、用户授权、用户交互、错误展示以及 `start`/`stop`/
`accept`/`reject`。它不得接触 SDP、ICE、PeerConnection、UDP socket、RTP、codec
实现、TURN credential 或 native pointer。

### 2. Owner 与资源释放

计划新增的 `realtime_media` 是平台媒体 infrastructure，不是 Feature 内的原生
实现。Owner 和 scope 固定如下；实现时如需新资源，必须先在对应 owner contract
中补充表项与释放测试。

| Resource | Owner | Scope | 释放规则 |
| --- | --- | --- | --- |
| `NetworkRuntime` / `NetworkFacade` | `AppRuntime` | App | App shutdown；Feature 只释放自己的订阅/lease |
| `RealtimeManager` | Rust `NetworkRuntime` | App/native | Runtime shutdown 前关闭其 sessions |
| `RealtimeSession` 注册/终态 | Rust `RealtimeManager` | Realtime Session | 先令 signaling/session terminal，再释放 driver 与 media endpoint |
| `WebRtcPeer` / PeerConnection | `network-webrtc`；由该 session 的 `RealtimeIoDriver` 持有 | Realtime Session | `RealtimeManager` 请求 terminal close；driver 取消并 join 后释放 |
| UDP socket / I/O task | `RealtimeIoDriver` | Realtime Session | 取消并 join driver，再释放 socket |
| `ScreenShareOperation` / ViewModel | `feature_screen_share` / Route Scope（计划） | Business/Route | stop 或 route dispose |
| Screen source / capture | `realtime_media` platform adapter（计划） | Screen Share Session | 停止产帧后关闭并释放 |
| H.264 encoder / decoder | `realtime_media` platform adapter（计划） | Screen Share Session | detach 后关闭实例 |
| Flutter Texture / GPU surface | `realtime_media` renderer（计划） | Viewer Session | 停止解码后释放 surface/texture |
| `RealtimeMediaEndpointId` | native media bridge/runtime（计划） | Session generation | detach/close 时撤销；Feature 不拥有底层句柄 |

`RealtimeManager` 是 Realtime session 的注册、终态和 signaling 协调 owner；
`RealtimeIoDriver` 只拥有该 session 的 `WebRtcPeer`、UDP socket、timer/I/O task，
并在取消后 join，不能把这些资源转交给 Feature。native media bridge 负责 endpoint
generation 的绑定与撤销；platform adapter/renderer 分别负责 capture/encoder 与
decoder/surface。Feature 和 Route 不得调用 `NetworkRuntime.dispose()`、关闭
App-owned native handle、直接发送 wire `webrtc_close`，或关闭别人的 session。

正常 Stop 的顺序为：停止产生新帧 → 由 native bridge detach 本地 media source →
platform owner 关闭 capture/encoder → Feature 通过 App Shell 请求停止
`RealtimeSession` → `RealtimeManager` 发送/处理 `webrtc_close`、等待 correlated
native completion 与 `closed`，并让 driver 取消/join → 取消 Realtime subscriptions
→ 由 renderer 释放 decoder/render surface → 释放 Feature Route 资源。App shutdown
仍遵循 AppRuntime 的 owner 顺序。

### 3. 窄范围 native encoded-media data-plane ABI

现有 protobuf command/event ABI 继续承载低频控制面：start、stop、state、signaling
和 control；当前 ABI 尚没有 screen-share business consent 或 media endpoint
逐步状态。Phase 2/5 计划在 source schema 中增加有界的 endpoint/media-state 与
typed consent contract；它们可以报告 surface ready、resolution change、stats 和
error，但任何控制事件都不得承载逐帧媒体。

本 ADR 批准一条只在 native media bridge、平台媒体实现和
`network-webrtc` 之间使用的窄范围 encoded-media data-plane ABI。其逻辑操作固定为：

1. 为一个明确的 Realtime session generation 创建/绑定一个媒体 endpoint，并返回
   有界的 `RealtimeMediaEndpointId`；
2. native capture/encoder 向该 endpoint 提交经过校验的 encoded H.264 frame，或
   将 native WebRTC egress 绑定到 decoder/render surface；
3. detach/close endpoint，撤销该 generation 的生产者、消费者和待处理媒体；
4. 通过低频事件报告 endpoint 状态、首帧、暂停/恢复、surface、统计和错误。

具体 ABI symbol 和平台 buffer 类型属于 Phase 1/2 的 owning contract，但不得改变
上述边界：

- Dart/Feature 只看到 opaque `RealtimeMediaEndpointId` 和高层 capability；不看到
  pointer、socket、PeerConnection、encoder/decoder pointer 或可解引用的 native
  handle。
- encoded frame 的高频传递是 native-to-native，payload 留在 native 所有者控制的
  内存中；不得通过 Dart `Uint8List`、Dart event stream 或 protobuf event 逐帧复制。
- encoded frame 必须在入队前检查有界长度（Phase 1 计划上限为 4 MiB）、分辨率、
  timestamp 和单调 sequence；不得记录 payload。
- egress 方向为 `network-webrtc` → native bridge → platform decoder → GPU
  surface/Flutter Texture。Dart 只观察 surface 和状态，不接收逐帧 decoded RGBA/YUV
  bytes。

`commandId` completion correlation 与 media/session `generation guard` 是两个独立
机制：前者只把一个 command 的 queue acceptance 与对应 native completion 关联起来；
后者把 state、signal、endpoint 和 frame 提交绑定到 `(realtime_id, generation)`。
每次新建 Realtime session 或 Retry 都产生新的 generation；旧 generation 的事件、
late result、endpoint 输入和 pending frame 一律丢弃。generation 不是
`commandId`、Relay `revision` 或 Discovery `runtime_epoch` 的别名，任何一个都不能
替代 generation guard。

因此，以下路径均明确禁止：

```text
Screen → RGBA/YUV Uint8List → Dart → FFI → Rust
RTP/video → protobuf event stream → Dart
Video frame → Delivery / Transfer / file resume / RelayDataFrame
```

### 4. Codec policy：Phase 0～7 仅 H.264

Phase 0～Phase 7 的 Screen Video Track 固定使用 H.264。codec capability 和 SDP
negotiation 由 native `network-webrtc` 统一负责；Feature 不指定 RTP payload type，
不解析 SDP。

- Offer/Answer 没有共同的 H.264 capability 时，session 以 `UnsupportedCodec` 失败。
- H.264 encoder/decoder 创建失败分别报告 `EncoderUnavailable`、`EncoderFailed`、
  `DecoderUnavailable` 或 `DecoderFailed`；这些错误也不得静默切换 codec。
- VP8、AV1 及其 fallback 不属于 Phase 0～7。未来要放开 codec，必须另行修订 ADR，
  不能在实现中偷偷增加协商分支。

这是一项未来媒体 contract，不声称当前默认 rtc codec 注册已被改成 H.264-only。

屏幕共享的失败必须保留可行动的类别，不得全部压成 `NetworkError`：

| 来源 | Screen Share/SDK 错误 | UI/业务含义 |
| --- | --- | --- |
| capture permission | `PermissionDenied` | 用户拒绝、撤销或系统未授予屏幕授权 |
| capture source | `CaptureSourceEnded` | source 被关闭、移除或不再可用 |
| H.264 encoder | `EncoderUnavailable` / `EncoderFailed` | 本机编码器不存在或启动/运行失败 |
| H.264 decoder | `DecoderUnavailable` / `DecoderFailed` | 本机解码器不存在或启动/运行失败 |
| SDP capability | `UnsupportedCodec` | 双方没有共同的 H.264 capability |
| signaling/negotiation | `RealtimeNegotiationFailed` | SDP、版本、信令或 DTLS 协商失败 |
| ICE/TURN | `IceFailed` / `TurnUnavailable` | 直连、ICE 或 TURN 路径失败 |
| consent/recovery | `PeerRejected` / `OperationExpired` / `ResumeRejected` | 对端拒绝、intent 过期或恢复被拒绝 |
| terminal transport | `PeerDisconnected` / `RecoverableTransportLoss` | 对端终止或进入业务 Retry |

Relay wire 的 `PEER_OFFLINE`/`PEER_NOT_READY` 映射为 peer unavailable 的
`PeerDisconnected` 结果，`CONTROL_UNAVAILABLE`/`RELAY_UNAVAILABLE`/
`RESOLVE_TIMEOUT` 映射为 `RealtimeNegotiationFailed`，而
`RESERVATION_FAILED`/`RESERVATION_EXPIRED` 映射为 `TurnUnavailable`。未知或
未认证的 wire error 必须 fail closed；不得用通用 `RelayError`/`IoError` 覆盖上述
业务类别。

### 5. Incoming consent 与 capture gate

现有 authenticated Relay signaling 仍使用 `webrtc_offer`、`webrtc_answer`、
`webrtc_ice_candidate`、`webrtc_ice_restart` 和 `webrtc_close`。Phase 5 计划在现有
authenticated `/v2/control` 内增加一个有界的 `RealtimeConsentV1` typed control
payload。它不是 `RelayDataFrame`、不是媒体 payload，也不新增或改写 ADR-020 所
冻结的五种 `RealtimeSignal` kind；现有 Relay `RealtimeSignal` 仍只有
`realtime_id`、`target_device_id`、`kind`、`revision`、`payload`，wire 上没有
`sender_peer_id`。新 payload 的 source schema 和 generated contract 必须在
Phase 5 一起更新。其最小字段与限制固定为：

```text
version = 1                         # payload schema version, not Relay v2
action = REQUEST | ACCEPT | REJECT | CANCEL
purpose = SCREEN_SHARE               # typed enum, not free-form text
intent_id                            # non-empty, <= 128 bytes
sender_peer_id                       # non-empty, <= 128 bytes
realtime_id                          # non-empty, <= 128 bytes
media = SCREEN_VIDEO                 # typed enum
requires_acceptance = true
issued_at_ms
expires_at_ms                        # issued <= expires <= issued + 120 s
action_revision >= 1                 # monotonic within (intent_id, sender_peer_id)
```

整个 typed payload 上限为 4 KiB（小于现有 `RealtimeSignal` 的 256 KiB 上限）。
`sender_peer_id` 在整个 intent 生命周期中都表示拥有屏幕内容、发起 REQUEST 的
peer；ACCEPT/REJECT/CANCEL 只 echo 该值，动作的实际传输方由 authenticated control
connection 的 peer binding 得出，不另造 `peer_id`/`sender_device_id` 别名。Relay
不信任或改写 payload 中的 sender 字段。

Provisional/replay/expiry 规则也属于 wire contract：接收端只保留最多 32 条 live
provisional intent（同一 `(sender_peer_id, intent_id)` 至多一条），保存 typed
metadata 与受保护的 pending-offer handle，不把请求交给 Feature 以外的 raw SDP；
`expires_at_ms` 到期即删除且不可续期。每个 authenticated peer 的 replay cache
最多 256 个 key，key 为 `(sender_peer_id, target_device_id, realtime_id, intent_id,
action, action_revision)`，保留 5 分钟；cache 不可用时拒绝动作。重复、乱序、过期、
未知 version/purpose/media、超限 payload 或 action_revision 不连续都 fail closed。

接收端必须同时验证：外层 authenticated source/target 与本机和预期 peer 相符；
`sender_peer_id` 与已认证的内容发送方及 pending operation 相符；`realtime_id`
绑定同一 peer、同一当前 session generation；REQUEST 才能创建 provisional，
ACCEPT/REJECT 只能作用于尚未过期且尚未 terminal 的匹配 REQUEST。这里的 auth
binding 来自已认证的 Relay control connection 与 session/peer binding，payload
不携带 bearer token、私钥或可复用 credential。`version`、`action_revision`、
intent replay cache 与本地 generation guard 各自独立，不能互相替代。

这属于 protocol source-of-truth 的后续扩展，必须先更新 schema 和 generated
contract；不得现在通过修改 generated output 或绕过 ADR-020/021 来实现。

Incoming 流程固定为：

```text
IncomingRequest
    ↓
Feature 展示请求与 [接受]/[拒绝]
    ↓
User Accept → 仅匹配 intent/realtime/sender/generation 才允许 Answer
User Reject → 发送 typed REJECT/关闭，并且不建立 accepted media session
```

收到 Offer 不得自动 `create_answer`、自动展示远端屏幕或自动激活本机 capture。
重复、过期或不匹配的 Accept/Reject 必须 fail closed。发送方也必须先有用户显式
点击、source/OS permission 结果和有效的业务 operation；远端未接受或 WebRTC 未
达到 native ready 之前，可以准备元数据/请求，但不得持续捕获、编码或排队真实屏幕
内容。实际 capture/encode 的唯一 gate 是：

```text
sender explicit action + remote acceptance + WebRTC ready
```

共享期间 Feature/UI 必须持续显示“正在共享屏幕”或等效的清晰状态；平台允许时
同时使用系统 capture indicator/Android foreground notification。

### 6. Session lifecycle 与 recovery

`ScreenShareOperation` 状态与 `RealtimeSessionState` 分离。App adapter 将 native
state、media readiness、consent 和 command completion 映射为业务状态；不能把二者
简单做成同一个 enum。

正常生命周期为：

```text
用户发起 → 选择 source/permission → 创建 ScreenShareOperation
→ 创建 RealtimeSession/Offer → Relay signaling
→ 接收方明确 Accept → Answer/ICE/DTLS-SRTP ready
→ 开始真实 capture/encode → native H.264 video track
→ native decode/render → 用户 Stop 或 session terminal
```

WebRTC transport loss 时，旧 generation 的全部状态必须终止：

```text
old PeerConnection = terminal/closed
old RealtimeSession = closed
old ICE/DTLS/SRTP state = discarded
old media queue = discarded
```

“重新连接”只能执行：

```text
Resolve → New RealtimeSession → New PeerConnection
       → New signaling → New ICE → New DTLS/SRTP
```

不得复用旧 `PeerConnection`、旧 `SessionId`、旧 endpoint、旧媒体队列或旧 generation
的命令结果。ADR-026 的 command correlation 与本 ADR 定义的独立 generation guard
共同丢弃旧结果；前者不替代后者。断线后的 screen video 不做历史帧重放；业务可以向
用户提供 Retry，但 Retry 必须创建上述全新链路。

### 7. 有界媒体队列、关键帧与 QoS

当前通用 `network-webrtc` `MediaFrame` video policy 仍是 **4 frames**，供既有通用
Realtime 媒体使用；本 ADR 不把它改成 3，也不把 screen-share 的 profile 反向套用
到其他媒体。Phase 0～Phase 7 的 screen-video transport queue 是独立的、固定为
**3 frames** 的未来 contract。capture、encode、decode、render staging queue 仍由
各自 owner contract 声明独立的有限上限；不得使用无界 `VecDeque`、无界 async
channel 或无限 `StreamController`，也不得把网络恶化转化为 RAM 中的历史视频缓存。

拥塞或过期时按以下顺序处理：

1. 入队前丢弃 stale frame；
2. 超过 3 帧时优先丢弃 oldest non-keyframe；
3. 保留恢复所需的 keyframe；若只能保留 keyframe，则丢弃新的 delta frame，不能
   为了容纳 delta 而删除唯一恢复点；
4. 连接关闭、generation 替换或 stop 时清空 pending video。

首轨建立、decoder reset、resolution/source change、ICE restart、丢包导致无法恢复
或 viewer reconnect 时，native media/QoS owner 请求新的 keyframe。媒体允许丢帧，不
允许等待网络恢复后重播历史视频；Screen video 永远不进入 Delivery backpressure、
Transfer 或 file resume。

Phase 7 计划的首版 screen profile 为 1080p、15 FPS、约 3 Mbps（最大分辨率 1920×1080）。
连续约 3 秒的 loss ≥5%、RTT ≥250 ms、encoder backlog 或 queue pressure 先降为
1080p10，再降低 bitrate；严重 loss ≥10% 或 RTT ≥400 ms 时降为 720p10。连续 10 秒
loss <2%、RTT <150 ms 且 queue healthy 时每次只恢复一级，以 hysteresis 避免抖动。
统计更新不得阻塞 media hot path，且只包含计数/分桶数据，不包含媒体 payload。

### 8. Signaling、ICE、TURN 与 Relay 角色

Relay Backend 的职责限定为 authenticated identity/presence、Realtime signaling
转发和 Phase 6 的 TURN credential issuance；Relay 不接收、解析、解密、转码、存储
或转发 RTP/video payload。`RelayDataFrame`、Delivery 和 Transfer 都不承载屏幕视频。

WebRTC 仍按 Direct ICE 优先、TURN fallback、必要时 `relay_only` 的现有模型运行：

```text
Relay Backend = auth + signaling
coturn        = standard ICE media relay（仅转发加密 DTLS-SRTP）
```

当前开发运行时可继续使用 ADR-024 所述 native runtime TURN configuration；这不代表
生产 credential policy 已完成。Phase 6 计划复用现有设备认证，按 Realtime session
签发 short-lived/ephemeral credential（建议约 10 分钟）：只在 runtime/session 内存
中使用，过期不复用，不写 DB、日志、telemetry 或 Feature contract，Feature 永远不
直接看到 credential。Caddy 不承担 UDP media relay。

### 9. Rendering、平台与隐私边界

接收方向固定为：

```text
WebRTC RTP/SRTP → native depacketize → native H.264 decoder
→ GPU surface → Flutter Texture/equivalent platform surface
```

Flutter Widget 只观察 surface ready、resolution、pause/resume、stats 和 error；不得
每帧 `setState` 搬运 bytes，也不得持有 native pointer。

Phase 0～7 的平台计划范围为：

- Windows：Windows Graphics Capture（必要时由 owning platform contract 评审 DXGI
  fallback）+ Media Foundation/H.264 hardware encoder；
- Android：MediaProjection + foreground service + MediaCodec H.264 encoder/decoder，
  permission revoke 必须立即停止；
- macOS、iOS/ReplayKit 和 Flutter Web 不在 Phase 0～7 的实现门禁内。它们未来若要
  支持，必须分别评审平台生命周期或 Browser `getDisplayMedia`/`RTCPeerConnection`
  adapter，不得改变 native runtime Owner 设计。

屏幕共享是高敏感能力。禁止持久化或记录 screen pixels、截图、raw/encoded frame、
SDP 原文、TURN credential、完整 ICE candidate、remote IP、window title 或 capture
source title。Diagnostics 必须对可能包含地址的 candidate 做 redaction；Telemetry
只能记录 operation 结果、duration、resolution/fps/bitrate bucket、frame counters、
RTT/jitter/loss bucket、ICE path、codec 和 error category，不得包含任何屏幕内容。
媒体保留 WebRTC DTLS-SRTP 端到端加密语义，Relay Backend 不拥有解密密钥。

## 当前行为与未来计划对照

| 范围 | 当前（截至 2026-09-04） | 本 ADR 后的 Phase 0～7 计划 |
| --- | --- | --- |
| Runtime/Owner | 一个 App Runtime；native `network-webrtc`、`RealtimeManager`、`RealtimeIoDriver` 已有 | 继续唯一 Owner；不增加 runtime/PeerConnection |
| Control ABI | protobuf start/stop/state/signaling；Dart 不接 raw handle；没有 screen-share consent | 保持控制面；Phase 2/5 增加经 schema 批准的 media-state/typed consent contract |
| Media ABI | 通用有界 `MediaFrame`/QoS；无 screen-share bridge | 新增窄 native encoded-media ABI；Dart 仅 opaque endpoint ID |
| Codec | rtc 默认 codec 注册；无 H.264-only screen contract | H.264-only；协商失败 `UnsupportedCodec`，无 VP8/AV1 fallback |
| Consent/capture | 没有 screen-share business consent/capture gate | incoming Accept 在 Answer 前；remote accepted + WebRTC ready 后才真实采集 |
| Queue | 通用 video policy 当前为 4 帧；没有 screen-share transport queue | screen-share transport profile 固定 3 帧；generic 4 帧保持不变，stale/oldest non-keyframe drop |
| Rendering/platform | 没有产品级 native screen decoder/Texture 链路 | Windows/Android native capture/codec/render；Flutter 只看高层 surface |
| Relay/TURN | Relay signaling-only；runtime TURN config 已有 | 继续 signaling-only；Phase 6 增加认证、短期 TURN credential |
| Recovery | 断线关闭旧 Realtime/PeerConnection | Retry 仅创建 new Session/Peer/ICE/DTLS/SRTP，绝不复用旧 generation |

表中“计划”不应在代码、README、测试或 release note 中写成“已支持”，直到相应
Phase 的实现与验收完成。

## 被拒绝的方案

- 在 Feature 中使用 `flutter_webrtc` 或创建第二个 PeerConnection：会分裂
  NetworkRuntime、ICE、socket、生命周期和安全 Owner。
- 让每帧 RGBA/YUV/H.264 bytes 经过 Dart：会引入高频复制、GC、无界 event backlog 和
  UI jank，也违反 Dart/FFI boundary。
- 由 Go Relay 转发 RTP、视频或屏幕帧：把 signaling/auth Relay 变成媒体代理，并
  扩大隐私、带宽和持久化风险。
- H.264 不可用时静默改用 VP8/AV1：使协商、平台验收和用户可见错误不可预测；固定
  返回 `UnsupportedCodec`。
- 收到 Offer 后自动 Answer/capture，或断线后复用旧 PeerConnection：违反显式 consent
  和 Business Recovery V2 的 terminal-generation 语义。
- 通过无限队列或等待网络恢复重播历史视频：牺牲实时延迟并造成内存增长；本 ADR
  选择三帧有界队列和丢弃 stale/non-keyframe。

## 验证与实施门禁

Phase 0 是纯文档例外，不添加行为测试；应人工确认本文与 Architecture companion
文档一致、未声称未来代码已存在、且 Accepted ADR 未被修改，并运行：

```bash
git diff --check
```

Phase 1～7 的实现必须按执行计划采用 Red → Green → Refactor，并分别验证 native
encoded H.264 loopback、三帧 screen profile/关键帧/断线丢帧、native decoder/render
surface、Windows/Android capture、incoming consent、Relay signaling-only、短期 TURN、
QoS/telemetry/privacy 和新 generation recovery。Phase 3/4 在真实设备 E2E 前必须先
通过 deterministic synthetic/fake capture、permission、projection、codec、surface
和 release-order 验收；synthetic 通过不等于平台产品已支持。Phase 7 的计划性能门禁
为正常网络首帧 < 5 s、1080p15 稳定输出、连续 30 min 内存与各队列不增长、Dart
main isolate 不复制 raw frame、Stop 后 < 1 s 停止采集/发送，并证明拥塞不会造成
无限延迟。涉及 protocol 时，source-of-truth 和 generated artifacts 必须一起更新；
涉及 Owner、模块依赖或公开 Dart contract 时，必须通过仓库现有的 architecture、
module-dependency、resource-owner、Rust/Dart/Go 及平台门禁。未执行的门禁不得报告
为 PASS。

## 关联决策

- [ADR-016：Native WebRTC Realtime Subsystem and Media QoS](ADR-016-webrtc-media-qos.md)
- [ADR-020：WebRTC Runtime Signaling Integration](ADR-020-webrtc-runtime.md)
- [ADR-021：Native Dart Realtime API Boundary](ADR-021-native-dart-realtime-api.md)
- [ADR-024：WebRTC Realtime Data Plane I/O Driver](ADR-024-webrtc-data-plane.md)
- [ADR-026：Realtime Command Completion Correlation](ADR-026-realtime-command-completion-correlation.md)
- [ADR-BUSINESS-RECOVERY-V2：业务恢复上移到传输之上](ADR-BUSINESS-RECOVERY-V2.md)
- companion architecture：`docs/architecture/WEBRTC_SCREEN_SHARING_ARCHITECTURE.md`
