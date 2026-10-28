最新更新时间：2026-10-28

# 资源 Owner 审计

本表是 Step 33 的最终资源生命周期清单，覆盖 App Scope、Module/Route Scope、
数据库、SSH/网络、异步任务以及 UI Controller。Owner 负责创建和释放；借用方
只能调用公共能力或释放自己的 Lease，不能关闭上级 Owner 的资源。

| Resource | Owner | Scope | Release |
| --- | --- | --- | --- |
| AppLogger | `AppRuntime` → `AppLogService` | App | `dispose` last; cancels UI notification timer; does not close the log DB |
| AppLogDatabase | binder via `AppLogService.setDatabase` (not closed by `AppLogService.dispose`) | App | `detachDatabase` drains writes, then `dispose` closes Drift handle (idempotent) |
| AppSettings | `AppRuntime` | App | `dispose` cancels listeners and pending work |
| System notification plugin | Full App and Network App `SystemNotificationScope` through one `AppNotificationCenter.shared` | App process | one plugin `initialize` per process; Features publish events and do not close the plugin |
| App startup initializers | `AppRuntimeInitializationOwner` → `AppRuntime` | App/Startup | register lazily; start after Runtime commit; construction rollback cancels in reverse and closes late diagnostics after bounded wait |
| ConnectionDatabase | `AppRuntime` / Connection Core | App | await repository init, then `close` |
| NetworkRuntime | `AppRuntime` | App | `dispose` after SSH/SFTP stop |
| Native handle | Network native adapter via `NetworkRuntime` | App/Native | stop isolate, then `destroy` handle |
| NetworkCommandGateway | `NetworkRuntime` / borrowed by App Shell adapter | App/borrowed Session | cancel adapter subscriptions; never stop or destroy the Runtime/native handle |
| NetworkRealtimeGateway | `NetworkRuntime` / borrowed by App Shell Realtime adapter | App/borrowed Session | cancel event subscription before Runtime dispose; never stop or destroy the Runtime/native handle |
| RealtimeMediaSession | `RealtimeMediaSessionController` / App Realtime adapter | Realtime session lease | release endpoint leases before the owning Realtime session; controller never stops the App Runtime |
| AppScreenShareSessions | `ScreenShareEntryCoordinator` in App Shell | App + one current screen-share operation | presentation attach/detach never stops the operation; retire terminal operations after their last view; App shutdown awaits operation cleanup before AppRuntime disposal |
| AppScreenShareOperation | `AppScreenShareSessions`; borrowed by presentation route/background host | One accepted or outgoing screen share | owns Feature controller, readiness and media/session leases; explicit Stop, authenticated peer stop or fatal platform/transport event cleans media before releasing admission; unconfirmed release stays owned for retry |
| AppScreenShareSessionLease | App Shell entry, transferred atomically to `AppScreenShareOperation` | One sender/responder Realtime operation | stop this `RealtimeSession`, wait normalized terminal state when available, then request exact-object `releaseSession`; pending SDK release remains terminal-authoritative and never stops App Runtime |
| AppScreenShareMediaCoordinator | App `AppScreenShareOperation` | One screen-share media operation | stop production/ingress, release endpoint, decoder/encoder, capture preparation, and opaque surface/Texture lease; page closure does not release it |
| AppScreenShareMediaMonitor | `AppScreenShareMediaCoordinator` | Attached endpoint + operation generation | cancel timer before stop/dispose/release; single-flight stats only; ignore late snapshots from invalidated owners |
| Android media worker extensions | `AndroidMediaOwner` | Borrowed codec + current native owner token | encoder/decoder loops share the owner lock/flags; teardown waits for their safe-point acknowledgement before releasing codec, projection, surface, or texture; the output pump owns no resource |
| Android capture input replacement | Existing `AndroidMediaOwner` encoder worker | Same consumed projection + single VirtualDisplay | detach input before old codec release; only after confirmed release acquire the selected-mode replacement; recheck revoke/stop before resize/attach; resources remain in the same owner until worker acknowledgement |
| Android decoder presentation buffers | Existing decoder worker + Flutter texture consumer | One output index + one submitted texture frame | release superseded pending output without render; resume latest only when visible and prior frame consumed; return pending index before flush/stop acknowledgement; texture callback captures only that attachment's availability flag |
| Android renderer visibility observer | `RealtimeMediaAndroidPlugin` | Engine + currently attached Activity | unregister on Activity detach/configuration change or engine disposal; update presentation eligibility without releasing media owner or holding lifecycle locks across codec calls |
| Android receive foreground readiness | Existing `AndroidMediaOwner` | One pending receive attachment | cancel bounded deadline and complete once; detach/release cancels before waiting for late attachment; late READY cannot start decoder; async creation re-enters the owner's fixed codec mode |
| Android remote playback foreground service and power | `ScreenReceiveForegroundService` | Pending/active/deferred native receive resources | service-local partial wake/Wi-Fi locks and renewal only; no SSH locks or second Flutter/native runtime; stop when no owner requires retention; service epoch limits destruction failures to its own attachments |
| Windows idle-frame timer + cached NV12 snapshot | Native `CaptureState` + its `NativeH264Encoder` | Selected source + native owner generation | timer borrows state weakly and serializes encoding/ingress with capture callbacks; stop cancels it before waiting for callbacks and releasing the codec/cache; source end prevents further output |
| Remote video dimensions notifier | `AppScreenShareMediaCoordinator`; borrowed by route presenter | Receive endpoint | update from valid payload-free stats; clear on endpoint release; dispose with coordinator |
| Direct Realtime signaling PathLease | Native `RealtimeSession` | Exact ConnectionSession + Realtime generation | retain during sharing; sends borrow it; terminal session removal drops it; hard close/revoke remains immediately visible |
| Provisional screen-share binding | Native `RealtimeManager` | Pre-claim Offer + bounded ICE + matched REQUEST | `pending → claiming → claimed/terminal`; native epoch-supervised expiry, reject/CANCEL/close/expiry/rollback destroys Offer and ICE; one shared 32-operation budget; no Dart session or media owner |
| Screen-share arbitration registry | `ScreenShareEntryCoordinator`; borrowed by incoming host and App operation | Per-peer pending intents + one App-wide committed share | committed operations cannot be replaced; App operation releases exact `(remotePeerId, initiatorPeerId, operationId)` after confirmed media/session cleanup; page detach retains admission; coordinator disposes its owned notifier; it owns no media or runtime |
| Screen-share video presentation | `AppScreenShareVideoPage` Widget State | One receiving route | owns local rotation and its window-presentation controller; a ready receiver enters fullscreen once per page, manual exit remains effective; toggles retain the same video subtree; back/Escape request fullscreen restore before route teardown |
| Screen-share native fullscreen snapshot | Route `AppWindowFullscreenController` + App native window adapter | Exact opaque window lease | serialize enter/restore; retain original Windows placement/styles or Android system-bar state; compensate late enter after disposal; stale release is a no-op; native window destruction performs final restore |
| Screen-share native-identity waiter | Incoming host or outgoing entry coordinator | One claim/start attempt | cancel temporary snapshot subscription and timeout when caller disposal resolves its cancellation signal; late results never install a route |
| RealtimeMediaEndpoint | native `RealtimeMediaRegistry`; borrowed by `RealtimeMediaSessionController` | Runtime + realtime generation | invalidate before WebRTC peer close; release is idempotent and old `(runtime, realtime, peer, direction)` generations fail closed |
| Native media ingress queue | `network-webrtc::WebRtcPeer` through `RealtimeIoDriver` | Native PeerConnection generation | stop capture/encoder, drop stale queued H.264, then close the native peer; borrowers never own the queue |
| Native media egress queue | `network-webrtc::WebRtcPeer` through `RealtimeIoDriver` | Native PeerConnection generation | terminal peer loss invalidates decoder output before decoder/surface teardown; never emit frames through the Dart event queue |
| RemoteVideoSurface | platform renderer adapter; surfaced as an opaque `realtime_media` capability | Renderer/session lease | detach from endpoint, release platform texture/surface, then mark the capability released; no Runtime or peer ownership |
| NetworkIdentityBundle | `AppRuntimeFactory` / `NetworkIdentityService` | App | secure-storage-backed identity is reused for the App process; no Feature release or replacement; App shutdown only releases in-memory key material |
| NetworkFacade | `AppRuntime` | App/borrowed Feature | dispose Feature subscriptions and Facade-owned Session state before Realtime/NetworkRuntime; LAN deactivate only detaches its subscriptions |
| SDK control-plane HttpClient | `AppSdkRequestExecutor` | Request | read bounded response, then `close(force: true)` on success or error |
| SshSessionManager | `AppRuntime` | App | `close` Session Pool and runtime |
| SSH Session | `SshSessionManager` / `SshSessionPool` | Lease/Session | Lease `release`; idle session `close` |
| SFTP compatibility service | `AppRuntime` → legacy `SftpService` | App | `dispose` after route Modules stop |
| TerminalDatabase | `AppTerminalModuleScope` → `TerminalModule` | Route Module | Module `dispose` closes DB |
| Terminal-only Runtime | `TerminalOnlyAppState` → `TerminalAppRuntime` | App/Widget | remove Feature borrowers, then await one idempotent cleanup future; continue after individual owner failures |
| SftpDatabase | `AppSftpModuleScope` → `SftpModule` | Route Module | Module `dispose` closes DB |
| AiDatabase | `AppRuntime` → `AiModule` | App Module | Module `dispose` closes DB |
| PlaybookDatabase | `AppRuntime` → `PlaybookModule` | App Module | Service `dispose`, then DB `dispose` |
| RagDatabase | `AppRuntime` → `RagModule` | App Module | Service `dispose`, then DB `dispose` |
| McpDatabase | `AppRuntime` → `McpModule` | App Module | stop HTTP Server, then DB `dispose` |
| LanShareDatabase | `AppRuntime` → `LanShareModule` | App Module | stop receiver, then DB `dispose` |
| MonitoringService | `AppRuntime` → `MonitoringModule` | App Module | stop polling, cancel subscriptions, `dispose` |
| SystemAdminService | `AppSystemAdminModuleScope` → `SystemAdminModule` | Route Module | cancel commands, then `dispose` |
| WebViewService | `AppRuntime` → `ClientWebViewService` | App | `dispose` chat sessions and controllers |
| MCP HTTP Server | `McpModule` → `McpServerController` | App Module | `stop` server and pending approvals |
| LAN Receiver | `LanShareModule` → `LanReceiverCoordinator` | App Module | deactivate receiver, close HTTP/WS/Discovery/Transfer resources and borrowed Facade subscriptions; never stop/destroy App NetworkRuntime/native handle |
| LAN pairing invitation/PIN HTTP clients | `LanTransferService` | Peer attempt | reject duplicate attempts, force-close on termination/unpair/final close, drain outstanding work and invalidate late results; no trust revocation or shared Runtime release on termination |
| Local Android Emulator discovery bridge | App-injected `AppLanEmulatorDiscovery`, activated by Receiver Discovery | LAN advertising generation | cancel polling/per-emulator subscriptions, drain in-flight ADB commands and observations, close each owned UDP socket, then delete only its exact console TCP/UDP redirections; never remove existing ADB forwards or stop emulators/ADB server |
| LAN incoming transfer offer stream | `LanReceiverCoordinator` | App Module | cancel the current Facade subscription on every runtime replacement; close the stable broadcast controller during final Receiver release |
| LAN PeerTrustStore | `LanShareModule` / LAN security boundary | App Module | serialize secure-storage writes, close change stream; explicit unpair deletes one record, deactivate does not clear trust |
| LAN Native Peer Registry | `LanShareModule` → `LanReceiverCoordinator` | App Module/borrowed Facade | restore/register trusted peers and detach endpoint/event subscriptions; only explicit unpair calls `NetworkFacade.removePeer` |
| RAG cache | `RagModule` → `RagService` | App Module | `dispose` cache store and service |
| AI chat runtime | Route Provider → `AiChatRuntimeFactory` | Route | cancel streams and `dispose` controllers |
| ViewModel | owning Route Provider/Scope | Route | Provider/Scope `dispose` |
| Route Controller | owning Widget State/ViewModel | Route/Widget | State `dispose` |
| Timer | owning Module/Service/ViewModel | Owner scope | `cancel` before owner release |
| TelemetryClient timers (periodic flush/retry/policy refresh) | `TelemetryClient` | App | `dispose` cancels all three timers before storage release |
| Foreground-service power locks | `BackgroundServiceLifecycle` | App/Platform | release immediately when native start returns false; stop retries release after failures |
| StreamSubscription | owning Service/Controller | Owner scope | `cancel` / `DisposableBag` |
| StreamController | owning Service/Controller | Owner scope | `close` before owner release |
| Isolate | launching parser/transfer/native owner | Task/Owner scope | stop/kill and await exit |

## 审计结论

- AppRuntime 的释放顺序是 Module → Realtime → SFTP → SSH → Network →
  database/repository → Logger；Realtime adapter 只借用 NetworkRuntime handle，
  必须在其之前释放；每组释放失败仍继续后续组，并重新抛出第一个错误。
- AppRuntimeFactory 是 NetworkIdentityBundle、NetworkRuntime 和共享 NetworkFacade
  的唯一创建/configure owner；Feature 不创建或关闭 App Scope SSH/Network。SSH 通过
  Lease，网络通过 `NetworkRuntime` Capability/Facade，Route Module 只关闭自己的
  数据库、HTTP/Discovery/Transfer Service 和订阅。
- LAN Trust、Discovery endpoint、Route availability 和 Relay enrollment/authorization
  不共享一个生命周期状态。Discovery/route loss 只失效动态 endpoint；只有显式
  unpair 才删除 Trust 并调用 `NetworkFacade.removePeer`。
- `apps/ssh_mobile_network/` 是独立组合根。它拥有自己的 NetworkRuntime、LAN 设置、
  身份和数据保护密钥，并让 `LanShareModule` 拥有该 App 的 `lan_share.db`。
  它不创建 NetworkFacade。退出顺序是路由、LAN Module、NetworkRuntime、Logger。
  Feature 不释放 App 的 NetworkRuntime。
- Drift Repository 不关闭数据库；数据库只由表中对应 Module 或 AppRuntime 关闭。
- Route Scope 的异步 Module dispose 必须在 Scope 销毁路径触发；ViewModel、
  Controller、Timer 和 Subscription 不得逃逸到 AppRuntime。
- Terminal-only App 的显式退出先把 Feature tree 替换为空 borrower，再等待 Runtime；
  普通 Widget teardown 复用同一个 Future，不能通过直接 `runApp` 丢弃异步释放。
- Native 资源必须完成 `stop → destroy`，Isolate 必须在 Native handle destroy 前
  停止并等待退出；这是防止 FFI handle 和后台事件泄漏的硬约束。
- Realtime 媒体端点先于对应 PeerConnection 失效；屏幕视频仅在 native ingress/
  egress queue、RTP 和平台采集/渲染 owner 间流动，Dart 只协调不透明端点和生命周期。
- PR74 route teardown is role-aware: sender stops production before capture/send
  endpoint release, then stops/releases the session lease; receiver stops ingress,
  stops/releases the session lease, then detaches decoder and surface/Texture.
  Route disposal continues remaining cleanup after an individual failure and does
  not promise retry after the route owner has been destroyed.

新增数据库、网络连接、SSH Session、Timer、Stream、Controller、Isolate 或
Native handle 时，先在本表增加 Owner/Scope/Release，再补生命周期测试。自动检查：

LAN Control V2 的 Trust/Discovery/Route/Relay 分离与 NetworkRuntime 共享规则见
[ADR-032](../adr/ADR-032-lan-control-v2-breaking-refactor.md)；本表只定义资源
Owner，不替代该 ADR 的 pairing、route 或 binary transfer 验收。

```bash
dart run tool/check_resource_owners.dart
dart run test/tool/resource_owner_check_test.dart
```

## Development diagnostic resources

App Runtime owns local LogSink instances and drains them after borrowers stop. Full App drains local-only sinks before disposing its logger; AppLoggerImpl closes its owned sinks. Native runtime owns and joins its diagnostic writer thread after runtime tasks stop. The development worker owns its child Process objects, stdout subscriptions and Android collector; stop releases only these resources. Query commands own no application runtime or database.
