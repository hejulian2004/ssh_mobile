Last updated: 2026-09-11

# WebRTC Screen Share TODO

本文是 WebRTC 实时屏幕共享任务的执行清单，记录阶段顺序、验收证据和外部
门禁。代码与测试是行为的权威来源；本清单只记录流程状态，不替代
[`WEBRTC_SCREEN_SHARING_ARCHITECTURE.md`](WEBRTC_SCREEN_SHARING_ARCHITECTURE.md)、
ADR-034 或原始技术架构文档。

## 执行规则

- 每个 Phase 使用独立分支和独立 PR。
- 当前 Phase 未完成验收和 PR 接受前，不把下一个 Phase 标记为已交付；已授权的
  后续契约/测试可以在独立分支并行准备，不能越过平台资源所有权或验收门禁。
- 推送后的 PR/CI 观察在后台进行，不阻塞不依赖其结果的后续契约工作；失败仍须
  记录并修复，不能把超时或缺失证据当作通过。
- 提交、推送和创建 PR 需要明确授权；没有授权时只做本地实现、测试和审计。
- 真实屏幕捕获、编码、解码、渲染、Consent、TURN 生产凭据和 QoS 只能在其
  对应 Phase 开始后实现。
- 每个阶段完成后记录命令、结果、环境限制和未覆盖项；不能把架构或占位契约
  写成已交付产品能力。

## 当前进度

- [x] 阅读 canonical architecture、ADR-034、仓库维护 Skill、Memory Map 和
  原始 Phase 计划。
- [x] 使用指定的 Luna/max 子代理完成一次 Phase 2 只读审计。
- [x] Phase 0 实现证据：架构/ADR/边界文档完成；当前基线随 PR #67 接受。
- [x] Phase 1 实现证据：Rust H.264-only RTP/ICE、三帧队列、localhost E2E、
  relay-only coturn E2E 和终止清理测试完成；当前基线随 PR #67 接受。
- [x] Phase 2 本地实现证据：native media bridge、generation-bound endpoint、
  payload-free Dart lifecycle contract、FFI lifecycle 和 owner/checker 更新完成；
  PR #67 已接受并合并到 `main`。
- [x] Phase 2 连接会话丢失竞态修复：session removal 与 media endpoint
  invalidation 在同一 Realtime 锁作用域内完成，并有回归测试。
- [x] Phase 2 stale-driver 清理保护：旧 I/O teardown 只移除自己拥有的
  `(realtimeId, peerId, driver)` generation，不会误删 replacement session。
- [x] Phase 2 endpoint release 清空 native queue/order；connection-session loss
  在 peer close 前撤销 endpoint，并有回归测试。
- [x] Phase 2 typed native lifecycle failures fail closed：controller、App Shell
  native adapter 和 fake backend 不会在异常后回到 ready；native media ABI 也
  保留 stale generation/endpoint、direction、duplicate、driver 和 frame
  rejection 的独立状态码。
- [x] Phase 2 real Dart→native adapter parity：native state/snapshot 携带独立
  generation，`RealtimeSession.mediaToken` 原样传给 App Shell 的
  `AppRealtimeMediaBackend`/`RealtimeMediaSessionController`；真实 adapter
  status mapping、generation replacement race 和 controller failure-state
  断言已覆盖，不能从 signaling revision 推导 generation。
- [x] Phase 0/1 基线随 PR #67 接受；仓库没有另开的 screen-share PR。
- [x] Phase 2 PR #67 已接受并合并：head
  `3d9a4a575f303a573371ce843867cf002f3b163d`，merge commit
  `352ef4dc9c602f648f0975809ce12553957b2a75`。
- [x] 获得授权后提交、推送并创建 Phase 2 PR（GitHub PR #67）。
- [x] Phase 3 Windows 边界冻结：`realtime_media_windows` 只传递源/端点身份、
  生命周期、opaque surface ID 和无载荷统计；capture buffer、H.264 数据、
  native pointer 与 GPU surface 不进入 Dart。
- [x] Phase 3 native owner capability：现有 runtime 增加 generation-bound opaque
  owner token；Windows platform channel 只传 token 和 bounded source metadata，
  native owner start/stop/close、renderer attach/detach 与 push/pull 仍不进入
  Dart；owner registry 保存完整 identity 并在 runtime destroy 前失效；每次
  native push/pull 也会重新校验 endpoint identity，旧 generation 的 late
  callback fail closed。
- [x] Phase 3.1 native capture lifecycle implementation：Windows Graphics Capture
  已在 `realtime_media_windows` native owner 中实现 monitor/window source 枚举、
  generation-bound start/stop/release、FrameArrived native buffer ownership、
  source close、resolution-change fail-closed restart boundary 和 payload-free
  stats；C++17/W4 编译通过，Windows 实机与完整 Phase 3 PR 验收仍未完成。
- [x] Phase 3.2 native Windows H.264 ingress implementation：Media Foundation
  hardware MFT discovery、native BGRA→NV12 conversion、Annex-B access-unit
  normalization、bounded Phase 2 owner push 和 typed encoder/native failure
  mapping 已接入；仅有本地 translation-unit 编译证据，硬件实机吞吐与端到端
  验收仍未完成。
- [x] Phase 3.3 native Windows H.264 receive/render implementation：hardware
  decoder MFT、native owner pull、D3D11 texture surface 和 Flutter texture
  registrar 已接入；stale owner、decoder terminal failure、texture detach/release
  均 fail closed，Dart 只收到 opaque surface ID 与低频统计。当前仅有本地
  translation-unit 编译证据，硬件双端 E2E 仍未完成。
- [ ] Phase 3 hardware pipeline gate：Media Foundation
  H.264 send/receive 实机能力、GPU/Texture 双端 E2E 尚未完成；当前 plugin
  对缺失 codec/renderer capability 只返回 typed failure，不报告虚假的成功。

- [x] Phase 5 typed consent contract/state-machine implementation：协议源 schema
  增加独立 `REALTIME_SIGNAL_KIND_SCREEN_SHARE_CONSENT` 与
  `ScreenShareConsentV2`；Rust/native/Dart/App codec parity、shared-session
  identity/action-revision replay guard、`feature_screen_share` explicit
  accept/reject/timeout/cancel 状态机和 media-ready gate 已落地。native
  generation 仍只用于本地 media lease，未进入 consent wire。真实双端
  UI/transport acceptance 仍待完成。
- [x] Phase 6 credential foundation：Relay 增加 device-authenticated、短时
  `/v2/turn/credentials` issuer，SDK 增加 bounded parser、in-memory
  `RealtimeTurnCredentialStore` 与 App provider；生产部署、secret scan 和
  relay-only E2E 仍待完成。
- [ ] Phase 6 canonical request-body hash：当前 device proof transcript 仍为
  `METHOD`、`PATH`、`TIMESTAMP`、`NONCE`；TODO: Consider binding BODY_SHA256
  to the proof transcript before production security certification. 纳入 body
  hash 需要单独审批 `.proto/manifest → 生成代码 → Go/Rust/Dart` 协议迁移。
- [x] Phase 7 QoS foundation：`RealtimeMediaStats` 增加 bounded packet/drop/
  recovery/keyframe/jitter/RTT/queue counters，并提供不改变三帧队列的有界
  adaptation policy；generation-bound native keyframe/decoder-reset owner port
  已通过 Rust FFI、Windows 和 Android 平台桥接接线，仍不暴露媒体载荷；
  native owner 已接入硬件 bitrate/framerate、IDR 与 receive-side PLI。
  硬件/设备能力证明、全链路隐私和最终门禁仍待完成。

## PR #73 定向收敛

PR #73 保持 Draft，承载 Phase 3–7 的合并后定向修复，不恢复已关闭的
`#68`–`#72`。本轮只收敛以下跨层契约：Android CSD/recovery gate、one-shot
MediaProjection lease 与 `cleanup_deferred` retry、Consent freshness/确定性
crossed-request 仲裁，以及 finalized monotonic RTP `packets_lost`。不修改
Relay、TURN、Windows、UI、rotation hot-resize 或统计 ABI。

- [x] Android encoder 从 codec-config buffer 和 output-format `csd-0/csd-1`
  建立有界 64 KiB SPS/PPS cache；首个完整 CSD+IDR 只有在 native
  `pushH264 == 0` 后才解除 delta gate。
- [x] Android decoder 保留 validated CSD，flush 后 replay；最多保留一个
  pending frame，CSD/recovery 未就绪的 delta 直接丢弃，尺寸变化仍为
  `capture_source_ended`。
- [x] ProjectionLease 使用 `granted → consumed → released`；worker
  `cleanup_deferred` 时保留 consumed lease/owner callback，安全 retry 后才
  teardown projection；`consume/revoke/release/releaseIfGranted` 共用同一状态
  transition lock。
- [x] App-scope Android backend 串行化跨 route projection preparation；只有
  `acquired` 把 grant/slot 交给 coordinator，`invalidated`/异常由 backend
  自行清理，caller 只对自己持有的 preparation abandon 一次。
- [x] Consent freshness 使用 30 秒 future skew/120 秒 TTL；crossed request
  按 UTF-8 `(peer_id, operation_id)` 仲裁，不发送 collision REJECT/CANCEL，
  并隔离旧 operation 的异步消息。
- [x] native RTP loss 在 128 包 reorder window 外才 finalize；同一 endpoint
  generation 内 monotonic，timing/connection-loss/track-close reset 不回退，
  Dart decrease 只产生零 delta 并 rebaseline。
- [x] PR #73 exact-head CI gate 已纳入 Android host unit、Android/Windows、
  App-Dart、Rust 和 protocol jobs；最终通过 SHA/run 以 PR body 绑定证据为准，
  skipped 不计为绿。
- [ ] 真机 codec/rotation/dual-device/production TURN acceptance 证据仍待完成。

当前状态：Phase 0、Phase 1、Phase 2 的实现、exact-head CI 证据和 PR #67
接受记录已齐；Phase 3/4 的 native platform owner、Phase 5 consent/Feature、
Phase 6 TURN issuer foundation 与 Phase 7 stats/adaptation/recovery bridge
foundation 已分别落地，但对应硬件、设备、生产安全和最终 E2E gate 尚未接受。
Windows/Android 双端验证、production TURN、拥塞恢复策略与完整 Phase 5–7
仍不得描述为已交付产品能力。

## PR #67 评审修正清单

以下项目对应评审提出的 generation、RTP、ABI、codec、release 和 evidence
边界；`[x]` 代表已具备本地代码/测试证据，外部 CI 结果另在命令清单中绑定记录。

- [x] generation 由 `RealtimeManager` 维护并通过 C ABI expected generation；
  generation 7 延迟创建、generation 8 替换的 stale-create race 有回归测试。
- [x] RTP sequence gap、乱序、重复、坏 fragment 和混合 track 在媒体 owner 内
  reset/recovery，并请求 keyframe；不会用 `?` 终止整个 Realtime I/O owner。
- [x] enqueue/input 边界同步验证 Annex-B、payload、timestamp（固定 90 kHz）和
  dimensions；packetizer 不再承担首次输入校验。
- [x] native media ABI 为 stale generation/endpoint、direction、duplicate、
  driver unavailable、peer mismatch 和 frame rejected 保留独立状态码；
  general command ABI 的历史 `-2` 映射保持不变。
- [x] 默认 DataChannel-only Realtime 不隐式添加 screen-video m-line；H.264
  codec 只通过显式 screen transceiver 配置，generic codec registration 保留。
- [x] endpoint release 在 queue/order 清理失败时保留 lease，成功清理后才移除；
  forced driver-cleanup failure 有 retry regression test。
- [x] Dart release 在 native queue/order cleanup 失败时保留 endpoint lease；
  endpoint 与 controller 都会进入可重试的 failed 状态，后续 release/stop
  成功后才 finalize，并有 endpoint/controller 两组回归测试。
- [x] pending start 在 stop 竞态中取得的 native endpoint 先进入同一 ownership
  registry；late-start cleanup 失败会保留 endpoint，后续 stop 可重试同一个 ID，
  并有失败竞态回归测试。
- [x] 真实 C ABI success path 已通过：live test Realtime driver 的 create →
  push（含 malformed Annex-B rejection）→ pull → release，另覆盖 duplicate 和
  stale-generation status；`network_sdk` public API 已独立 analyzer/test 验证；
  ignored coturn video test 已显式运行并通过。

## 阶段清单

### Phase 0 — Architecture Freeze

- [x] 明确唯一 native WebRTC owner、H.264-only、三帧视频队列和 recovery 规则。
- [x] 明确高频媒体不进入 protobuf event stream，Dart 只持有 opaque endpoint。
- [x] 完成 ADR-034、架构检查和文档一致性检查。
- [x] 当前基线的 PR 接受证据记录在 PR #67。

### Phase 1 — Native H.264/RTP Path

- [x] native sender 输入 encoded H.264，receiver 输出 encoded H.264。
- [x] RTP 经过现有 `RealtimeIoDriver`，没有第二个 PeerConnection 或 runtime。
- [x] 固定三帧队列、关键帧保护、过期/超大帧拒绝和 disconnect 清理。
- [x] localhost video E2E 通过。
- [x] relay-only coturn video E2E 通过。
- [x] 当前基线的 PR 接受证据记录在 PR #67。

### Phase 2 — Native Media Bridge + Dart Contract

- [x] 建立 `packages/infrastructure/realtime_media` workspace member。
- [x] 建立 native create/release/push/pull H.264 data-plane ABI；Dart 只声明
  opaque endpoint 的低频生命周期函数。
- [x] public Dart API 没有 `Stream<Uint8List>`、raw frame 或逐帧 push API。
- [x] endpoint 绑定 runtime generation、realtime ID、peer ID、direction。
- [x] stop/release/dispose 幂等，停止期间的迟到 start 会回收其 native lease。
- [x] runtime stop、realtime close 和 connection-session loss 都会失效旧 endpoint。
- [x] endpoint release 会清空对应 native H.264 queue 与 ordering state，替换 lease
  不会读取旧帧或继承旧 sequence。
- [x] connection-session loss 在关闭 peer 前先撤销 endpoint，terminal close 窗口不会
  再向旧 native queue 入帧。
- [x] typed native lifecycle failure 会让对应 controller/endpoint 进入 failed，
  不允许异常后继续提交媒体操作。
- [x] fake backend lifecycle tests、native bridge tests、owner/dependency/architecture
  checks 通过。
- [x] PR #67 已接受并合并；Phase 2 证据见下方 exact-head CI 记录。

### Phase 3 — Windows Capture / Codec / Render（进行中）

- [x] 建立独立 `realtime_media_windows` workspace package、App Shell 注入和
  可替换的 Windows platform owner 接口；缺失 native plugin 时 fail closed。
- [x] 增加 runtime-owned native owner token port；owner close 与 endpoint release
  保持分离，generation/stale endpoint 校验仍由既有 native registry 负责。
- [x] Windows monitor/window capture lifecycle owner（平台实机/E2E 验收待完成）。
- [x] Hardware H.264 send ingress implementation（硬件实机/端到端验收待完成）。
- [x] Hardware H.264 receive/decode owner（硬件实机/端到端验收待完成）。
- [x] D3D11 GPU surface 与 Flutter Texture registrar 链路（实机/E2E 验收待完成）。
- [ ] raw frames 不经过 Dart；完成 Windows 专属 analyze/test 和手工 E2E 记录。

本轮 Phase 3 boundary/capture 验证（2026-09-08）：`network-ffi` 23 tests passed；
`network-core` realtime-media focused tests 7 passed；`realtime_media` 与
`realtime_media_windows` focused tests 32 passed；`network_transport` focused
tests 16 passed；`ssh_mobile_network_native` native-asset tests 22 passed。
Dart analyzer 无 error，Rust format、module/resource/architecture checks 和
Windows plugin 七个 C++17/W4 translation units compile 均通过。Flutter wrapper
test/analyzer 在当前离线
环境无法完成 native-asset/pub advisory 阶段，因此不作为 Phase 3 acceptance
evidence。Windows Graphics Capture、Media Foundation hardware ingress/decode 的
实机吞吐、GPU Texture 和 Windows 双端 E2E 仍未通过，PR #68 继续保持 draft。

### Phase 4 — Android Capture / Codec / Render

- [x] Android platform owner boundary：`realtime_media_android` 只传递源/端点
  身份、projection/lifecycle 命令、opaque surface ID 和无载荷统计；
  MediaProjection、foreground service、MediaCodec、SurfaceTexture 与 JNI
  owner-token bridge 保持 native/Kotlin-owned。
- [x] MediaProjection/foreground-service、hardware-only MediaCodec H.264
  encode/decode、Annex-B normalization 和 Phase 2 owner push/pull 已实现；
  硬件不可用时返回 typed failure，不静默软件或 Dart bytes fallback。
- [x] CSD 来源、64 KiB parameter-set cache、首个 native-accepted CSD+IDR
  recovery gate、decoder flush replay 和 bounded pending-frame backpressure
  已加入 owner/helper tests；codec-config 不作为独立媒体帧发送。
- [x] MediaProjection 使用 single-use ProjectionLease；正常 stop 才释放
  callback/projection，`cleanup_deferred` 保留 consumed lease 供 retry；
  display size 变化继续按 `capture_source_ended`/restart-required 处理。
- [ ] Android 权限拒绝、projection revoke、旋转/后台、Surface 销毁、重复
  start/stop 与 generation replacement 的设备/instrumentation/E2E 验收。

### Phase 5 — Consent / Feature Integration

- [x] 独立 `feature_screen_share` 与 typed/versioned consent contract；协议源、
  Rust/native/Dart/App codec 和唯一 signal kind 已同步。
- [x] IncomingRequest → explicit accept/reject → typed operation state machine；
  REQUEST 不自动应答或启动媒体。
- [x] sender 只在远端 ACCEPT 且匹配 generation media-ready 后进入 capture gate；
  Feature 只持有业务状态与 metadata subscriptions。
- [x] reject/cancel/timeout/duplicate/stale-generation/recoverable media failure
  的单元回归已加入。
- [x] Consent freshness 使用 structural value + injected temporal check；两种
  crossed-request delivery order 均按 UTF-8 tuple 收敛到唯一 winner/loser，
  不发送 collision REJECT/CANCEL，旧 operation action 不污染新状态。
- [ ] 真实 App Shell UI、Realtime transport 与 Windows/Android consent E2E 验收。

### Phase 6 — TURN Credential Delivery

- [x] Relay `/v2/turn/credentials` issuer 使用现有 device-authenticated Bearer
  session，服务端只保留 shared secret，TTL 有界。
- [x] SDK/App 提供 bounded credential parser、一次 401 refresh、generation-bound
  in-memory store 和脱敏 `toString`；不把 credential 暴露给 Feature。
- [ ] 生产部署移除静态客户端 TURN 密码，完成日志/telemetry/database/crash
  脱敏、secret-scan、expiry/refresh 和 relay-only production-shaped E2E。

### Phase 7 — QoS / Privacy / Final Gate

- [x] `RealtimeMediaStats` 增加 bounded sender/receiver/drop/recovery/keyframe/
  jitter/RTT/queue 指标；默认低频快照，不创建 per-frame Dart stream。
- [x] 增加保持三帧 queue invariant 的 bounded bitrate/framerate/resolution
  adaptation policy；命令现在沿 generation-bound owner 传到 Windows/Android
  native owner，硬件编码器应用 bitrate/framerate，分辨率变化要求显式
  stop/release/recreate；Dart 低频轮询可使用 3 秒拥塞降级、25% 有界步进、
  严重拥塞 720p10 和 10 秒健康恢复一档的 stateful controller。
- [x] generation-bound native keyframe request/decoder reset bridge 已通过
  Rust FFI、Windows/Android owner 和平台 channel 接线，并由 native owner 做
  一秒限频；发送端已接入硬件 IDR 请求，接收端由 native peer 在同一 WebRTC
  路径发出 PLI，请求仍保持在 native queue/peer owner 内。
- [x] RTP `packets_lost` 改为 128 包 reorder-window finalized monotonic total；
  late reorder、wraparound、duplicate、timing/connection/track reset 和大跳跃
  的 bounded accounting 回归已加入，Dart decrease 只 rebaseline。
- [ ] 完成真实硬件编码器/RTCP 设备验收、拥塞恢复策略与完整平台 E2E。
- [ ] stop/revoke/permission/privacy 回归及全链路 recovery。
- [ ] Rust、Dart、Go、平台测试与覆盖率门禁全部通过。
- [ ] 更新 architecture status，确认没有把未验收能力描述为已交付。

## 已验证命令

- [x] `dart run tool/check_module_dependencies.dart`
- [x] `dart run tool/check_resource_owners.dart`
- [x] `dart run tool/architecture_check.dart`
- [x] 本轮 `network-core` 全量 lib 测试：579 passed；`network-webrtc` 普通测试：
  46 passed、2 ignored；`network-ffi`：22 passed（含 live C-ABI success path）。
- [x] Rust workspace clippy（`--workspace --all-targets --locked -D warnings`）通过。
- [x] `realtime_media` analyzer/test：analyzer 无问题、24 项通过；
  `ssh_mobile_network_native` analyzer 无问题、28 项通过；`network_sdk`
  analyzer 无问题、88 项通过。
- [x] ignored coturn relay-only video test：显式运行并通过（1 passed）。
- [x] live C-ABI endpoint test：create/send/receive/pull/release 全链路通过，
  并验证 malformed Annex-B、duplicate endpoint、stale generation 和 released ID。
- [x] GitHub Actions：release-retry corrective exact head
  `10878406f7732d785e3a0d1aa0147574e91605cb` 的 run
  [34100231240](https://github.com/hejulian2004/ssh_mobile/actions/runs/34100231240)
  已完成，全部 jobs success（含 architecture、native/sdk Dart quality、平台
   build、app tests 和 90% coverage gate）。
- [x] GitHub Actions：PR #67 final exact head
  `3d9a4a575f303a573371ce843867cf002f3b163d` 的 run
  [34107278164](https://github.com/hejulian2004/ssh_mobile/actions/runs/34107278164)
  已完成，全部 jobs success；PR #67 已于 merge commit
  `352ef4dc9c602f648f0975809ce12553957b2a75` 合并。
- [x] native binding 的 Flutter FFI 测试从其 package 根目录运行，以便解析
  package native asset；从仓库根目录调用会缺少该 asset。
- [x] surface generation 不匹配时的 detach/release/fail-closed 回归测试通过。
- [x] 本轮 `network-core` clippy（all targets、`-D warnings`）通过。
- [x] `git diff --check`
- [x] 本轮 Phase 5–7 foundation focused validation（2026-09-08）：
  `cargo fmt --all -- --check`、`cargo check -p network-core -p network-protocol
  -p network-relay --locked`、`cargo test -p network-protocol --locked`（14
  passed）、`cargo test -p network-core realtime::tests --locked`（41 passed）、
  `go test ./internal/relay -run 'TurnCredentials|TurnPassword' -count=1`（passed）。
  相关 `network_sdk`、`realtime_media`、Windows/Android adapter、transport、
  native binding 和 Feature 的 targeted Dart analyzer 均无问题；App Shell 新增
  codec/adapter 文件 targeted analyzer 无问题。完整 Flutter workspace test、平台
  设备/E2E、production TURN、native keyframe 和 secret-scan 仍是后续 gate，未因
  foundation 检查而标记通过。
- [x] 新增 connection-session loss endpoint invalidation 回归测试通过。
- [x] endpoint release queue/order reset 回归测试与 network-webrtc queue clear 单测
  通过。
- [x] endpoint release 的 receive reassembler sequence reset 回归测试通过，替换
  lease 不继承旧接收序列。
- [x] typed start/attach failure lifecycle 回归测试通过，失败状态不会被 finally
  误置为 ready。
- [x] production Dart→native generation path：Rust protobuf state/snapshot →
  native Dart decoder → `RealtimeSession.mediaToken` → App Shell media gateway
  → native endpoint create(expected generation)；旧 token 在 native replacement
  后得到 `staleGeneration`，controller fail closed。
- [x] screen-media production boundary forbidden-pattern audit 通过：没有第二套
  PeerConnection、Dart 帧流、RelayDataFrame 或无界 native queue。
- [x] Phase 7 native recovery bridge focused validation（2026-09-08）：
  `cargo test -p network-webrtc --locked`（50 passed、2 ignored）、
  `cargo test -p network-core realtime_media --locked`（9 passed）、
  `cargo test -p network-ffi --locked`（23 passed）和对应 clippy/check 通过；
  `realtime_media`、Windows/Android adapter analyzer 通过。Dart/Flutter
  package test 在当前离线 native-asset/pub 环境仍无法完成，平台硬件和双端
  E2E 也未作为本轮证据。
- [x] Phase 7 native adaptation/keyframe actuation wiring（2026-09-08）：
  `cargo check -p network-core -p network-webrtc -p network-ffi --locked`、
  `cargo test -p network-webrtc --locked`（50 passed、2 ignored）、
  `cargo test -p network-core realtime_media --locked`（9 passed）和三个
  realtime_media Dart package analyzer 均通过；Windows Media Foundation、
  Android MediaCodec、native PLI/IDR 和设备 E2E 仍待平台门禁。
- [x] Phase 7 bounded congestion/recovery policy（2026-09-08）：
  `RealtimeMediaAdaptationController` 以可注入时间完成 3 秒降级、25% bitrate
  步进、loss/RTT 严重拥塞 720p10 和 10 秒健康单档恢复；适配命令仍不改变
  native 三帧队列，平台硬件/设备 E2E 仍待验收。
- [x] Phase 7 native stats bridge（2026-09-08）：`owner_read_stats` 以固定宽度
  C ABI 返回 queue depth/capacity、enqueue/dequeue/drop、packet sent/received/
  lost、recovered-frame、jitter 和 keyframe 计数，Windows/Android owner 将其
  合并进低频 `RealtimeMediaStats`；RTT 继续等待 rtc 的权威 RTCP/ICE 来源，
  不从媒体到达时间伪造；Rust FFI/live endpoint、RTP loss/recovery 和 Dart
  adapter tests/analyzer 通过，平台编译/设备 E2E 仍待验收。
- [ ] 本轮新增的 realtime_media、Windows/Android method-channel stats tests：
  当前 Windows 主机的离线 workspace/native-asset 阶段无法启动 Dart test
  runner，未将其计入通过证据；CI 仍以 exact-head workflow 为准。

## 下一步

1. 保留当前工作树和用户提供的中文架构原文，不混入无关文件。
2. 保留已完成的 real Dart→native adapter parity 和 PR #67 接受证据，不再扩展
   Phase 2 scope。
3. 在独立 Phase 3 分支完成 Windows 硬件能力、Texture 双端 E2E 和验收；当前
   native owner implementation 不等于平台能力已交付。
4. 在 Phase 4 分支完成 Android 设备权限/Projection/MediaCodec/Surface 验收，
   然后验收 Phase 5 的真实 consent UI/transport。
5. 将 Phase 6 issuer 接入生产 device-auth/TURN 配置，完成 secret-scan 与
   relay-only E2E；再将 Phase 7 native keyframe/recovery、隐私和最终门禁接线。
6. 推送后的 PR/CI 运行保持后台观察并绑定 exact head；任何失败、超时或环境
   缺口都记录为未通过，不能把基础契约勾选扩展成产品交付声明。
