最新更新时间：2026-09-07

# 资源 Owner 审计

本表是 Step 33 的最终资源生命周期清单，覆盖 App Scope、Module/Route Scope、
数据库、SSH/网络、异步任务以及 UI Controller。Owner 负责创建和释放；借用方
只能调用公共能力或释放自己的 Lease，不能关闭上级 Owner 的资源。

| Resource | Owner | Scope | Release |
| --- | --- | --- | --- |
| AppLogger | `AppRuntime` → `AppLogService` | App | `dispose` last; cancels UI notification timer; does not close the log DB |
| AppLogDatabase | binder via `AppLogService.setDatabase` (not closed by `AppLogService.dispose`) | App | `detachDatabase` drains writes, then `dispose` closes Drift handle (idempotent) |
| AppSettings | `AppRuntime` | App | `dispose` cancels listeners and pending work |
| App startup initializers | `AppRuntimeInitializationOwner` → `AppRuntime` | App/Startup | register lazily; start after Runtime commit; construction rollback cancels in reverse and closes late diagnostics after bounded wait |
| ConnectionDatabase | `AppRuntime` / Connection Core | App | await repository init, then `close` |
| NetworkRuntime | `AppRuntime` | App | `dispose` after SSH/SFTP stop |
| Native handle | Network native adapter via `NetworkRuntime` | App/Native | stop isolate, then `destroy` handle |
| NetworkCommandGateway | `NetworkRuntime` / borrowed by App Shell adapter | App/borrowed Session | cancel adapter subscriptions; never stop or destroy the Runtime/native handle |
| NetworkRealtimeGateway | `NetworkRuntime` / borrowed by App Shell Realtime adapter | App/borrowed Session | cancel event subscription before Runtime dispose; never stop or destroy the Runtime/native handle |
| RealtimeMediaSession | `RealtimeMediaSessionController` / App Realtime adapter | Realtime session lease | release endpoint leases before the owning Realtime session; controller never stops the App Runtime |
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
- Drift Repository 不关闭数据库；数据库只由表中对应 Module 或 AppRuntime 关闭。
- Route Scope 的异步 Module dispose 必须在 Scope 销毁路径触发；ViewModel、
  Controller、Timer 和 Subscription 不得逃逸到 AppRuntime。
- Terminal-only App 的显式退出先把 Feature tree 替换为空 borrower，再等待 Runtime；
  普通 Widget teardown 复用同一个 Future，不能通过直接 `runApp` 丢弃异步释放。
- Native 资源必须完成 `stop → destroy`，Isolate 必须在 Native handle destroy 前
  停止并等待退出；这是防止 FFI handle 和后台事件泄漏的硬约束。
- Realtime 媒体端点先于对应 PeerConnection 失效；屏幕视频仅在 native ingress/
  egress queue、RTP 和平台采集/渲染 owner 间流动，Dart 只协调不透明端点和生命周期。

新增数据库、网络连接、SSH Session、Timer、Stream、Controller、Isolate 或
Native handle 时，先在本表增加 Owner/Scope/Release，再补生命周期测试。自动检查：

LAN Control V2 的 Trust/Discovery/Route/Relay 分离与 NetworkRuntime 共享规则见
[ADR-032](../adr/ADR-032-lan-control-v2-breaking-refactor.md)；本表只定义资源
Owner，不替代该 ADR 的 pairing、route 或 binary transfer 验收。

```bash
dart run tool/check_resource_owners.dart
dart run test/tool/resource_owner_check_test.dart
```
