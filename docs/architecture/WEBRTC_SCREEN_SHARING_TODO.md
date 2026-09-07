Last updated: 2026-09-07

# WebRTC Screen Share TODO

本文是 WebRTC 实时屏幕共享任务的执行清单，记录阶段顺序、验收证据和外部
门禁。代码与测试是行为的权威来源；本清单只记录流程状态，不替代
[`WEBRTC_SCREEN_SHARING_ARCHITECTURE.md`](WEBRTC_SCREEN_SHARING_ARCHITECTURE.md)、
ADR-034 或原始技术架构文档。

## 执行规则

- 每个 Phase 使用独立分支和独立 PR。
- 当前 Phase 未完成验收和 PR 接受前，不实现下一个 Phase。
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
- [ ] Phase 3 hardware pipeline gate：Windows Graphics Capture、Media Foundation
  H.264 worker、GPU decoder/Texture 和 Windows 双端 E2E 尚未完成；当前 plugin
  对缺失 capability 只返回 typed failure，不报告虚假的成功。

当前状态：Phase 0、Phase 1、Phase 2 的实现、exact-head CI 证据和 PR #67
接受记录已齐；Phase 3 当前已进入 Windows boundary implementation。Phase 3
的 capture/codec/render 与 Phase 4–7 仍不得描述为已交付能力。

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
- [ ] Windows monitor/window capture。
- [ ] Hardware H.264 encode/decode。
- [ ] GPU surface 与 Flutter Texture 链路。
- [ ] raw frames 不经过 Dart；完成 Windows 专属 analyze/test 和手工 E2E 记录。

本轮 Phase 3 boundary 验证（2026-09-07）：`network-ffi` 23 tests passed；
`network-core` realtime-media focused tests 7 passed；`realtime_media` 与
`realtime_media_windows` focused tests 32 passed；`network_transport` focused
tests 16 passed；`ssh_mobile_network_native` native-asset tests 22 passed。
Dart analyzer 无 error，Rust format/clippy、module/resource/architecture checks
和 Windows plugin C++17 syntax compile 均通过。Flutter wrapper test 在当前离线
环境无法完成 native-asset/pub advisory 阶段，因此不作为 Phase 3 acceptance
evidence。Windows Graphics Capture、Media Foundation worker、GPU decoder/
Texture 和 Windows 双端 E2E 仍未通过，PR #68 继续保持 draft。

### Phase 4 — Android Capture / Codec / Render

- [ ] MediaProjection 与 foreground service 合规。
- [ ] Android MediaCodec H.264 encode/decode。
- [ ] Flutter Texture、权限撤销 fail-closed 和 Android E2E 记录。

### Phase 5 — Consent / Feature Integration

- [ ] 独立 `feature_screen_share` 与 typed consent contract。
- [ ] IncomingRequest → explicit accept/reject → answer。
- [ ] sender 只在远端接受且 WebRTC ready 后捕获/编码。
- [ ] reject/cancel/timeout/duplicate/recovery 测试。

### Phase 6 — TURN Credential Delivery

- [ ] 移除生产静态 TURN 密码。
- [ ] 接入短时 credential、现有 device auth、日志/数据库脱敏。
- [ ] relay-only production-shaped E2E 与 secret-scan 证据。

### Phase 7 — QoS / Privacy / Final Gate

- [ ] keyframe request、发送/接收/丢帧统计和 adaptation。
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

## 下一步

1. 保留当前工作树和用户提供的中文架构原文，不混入无关文件。
2. 保留已完成的 real Dart→native adapter parity 和 PR #67 接受证据，不再扩展
   Phase 2 scope。
3. 在当前独立 Phase 3 分支继续实现 Windows capture/codec/render，并按 Windows
   owner、工具链和手工 E2E 入口记录验收证据；当前 boundary package 不等于
   平台能力已交付。
