最新更新时间：2026-10-23

# ssh_mobile_full 维护约束

## App Scope contract

- `AppRuntimeFactory` is the sole composition root for App identity,
  `NetworkRuntime`, native command gateway, and shared `NetworkFacade`; one
  App process performs at most one successful `ConfigureRuntime`, on first
  network use. Cold event/diagnostic subscriptions must not initialize keys
  or native handles. SSH, SFTP, Realtime, and Relay borrow these resources.
  LAN runtime is injected as `LanShareNetworkRuntimePort`: `ensureRuntime`
  maps to `NetworkCapability.runtime`, and `ensureWebSocketRelay` maps to
  `NetworkCapability.webSocketRelay`. `feature_lan_share` does not depend on
  `network_transport`.
- `NetworkIdentityBundle` (Ed25519/X25519 key pairs) belongs to App/infrastructure;
  Features never create, persist, or replace it. `AppRuntime.dispose()` stops
  Feature/Module use and facade/realtime subscriptions before stopping/destroying
  NetworkRuntime/native handle; Feature deactivate/reactivate never reconfigures it.
- LAN Control V2 and Native Network V2 are separate breaking-only domains. Do
  not restore old LAN pairing/upload fallback or change native wire V2 for LAN.

## Scope, dependencies, and API

- Allowed: App Shell/`AppRuntime`, route aggregation, Port adapters, retained
  compatibility bridges, App `network_sdk`/`SdkRequestExecutor` request,
  Bootstrap/auth assembly, App tests, startup configuration, and platform
  integration.
- Never import a Feature `/src/`, copy Feature/Core/Infrastructure code, add a
  second global Service/locator or Network/SSH owner, expose control-plane
  `HttpClient` to Features, merge control HTTP with the native data plane, or
  store secrets in SharedPreferences/DB/logs.
- Stable APIs use Feature public exports, App Ports, or route metadata. Changing
  `AppRuntime` dependencies updates Full/Terminal callers, tests, and dependency
  checker allowlists.

## Storage and lifecycle

App Shell owns only `app_logs`; Feature/Core Modules own business DBs. A DB-open
failure propagates and never falls back to memory or `AppDatabase`. AppRuntime is
owner of Network, SSH, Logger, Modules, and adapters and exposes explicit
`dispose/close/cancel/release`; Route Scope releases only its ViewModel resources.
Debug assertions verify observable Timer/Subscription/Lease/native-handle release.

`ScreenShareEntryCoordinator` owns one `AppScreenShareSessions` for the App
Shell. It owns operation controllers, readiness subscriptions, media and session
leases independently of presentation routes. Closing a screen-share page only
detaches its view and restores its window presentation; it never sends CANCEL
or releases a running operation. Annotation state stays on that operation.
Page pop does not clear marks; stop, generation change, and transport loss do. Explicit local Stop, authenticated peer stop,
transport/source failure or App shutdown performs operation cleanup. Keep global
admission until media release is confirmed; failed cleanup stays owned and can
be retried. The background host may reopen the same operation or stop it, never
create another session. App shutdown closes screen shares before AppRuntime.
Screen-share routes disable transition snapshotting: native video textures
remain live across navigation and must not be flattened into route images.

The receiving route's window-presentation controller owns one native fullscreen
snapshot lease, separate from media/session ownership. Serialize enter/restore;
an accepted ready receiver requests fullscreen once per page attachment. Manual
exit stays effective for that page; a sender never requests automatic fullscreen.
Route disposal compensates a late enter with the same lease. Windows restores
the original placement/styles, Android restores the prior system-bar visibility
and behavior. Stale lease release cannot affect a newer owner. Retain a failed
restore for retry, surface a bounded error, and never guess a default window
state or create/restart a media endpoint to change presentation.

`BackgroundServiceManager` owns UI-isolate notifications/permissions/power lock/
platform service. Background entry points create `_BackgroundSshRuntime`, which
alone owns background session registry, SSH/tmux, keepalive, and subscriptions.
Foreground `SshService` owns sessions/commands/history; `_SshBackgroundEventBridge`
owns plugin events and `_SshSessionProjection` owns immutable UI projections.
Attempt owners use per-session generations; close awaits connect/reconnect,
background isolate, subscriptions, runtime, history queue, Session Pool, and
native stream connector. Network V2 codec remains a narrow facade with real wire
tags and independent command/typed decoders; no pseudo-Realtime tag adapter.

## Validation for code changes

Run package format/analyze/test from the owning contract; local aggregate CI is
opt-in per the canonical Skill. Network refactors also run:

```bash
dart run tool/architecture_check.dart
flutter test test/services/network/network_protocol_v2_codec_test.dart
```

The paired `lan-network-v2-targeted` CI job covers App adapter, Feature trust/
route/runtime ownership, and SDK contracts. AppRuntime owner changes verify
exactly-once configure/activate/deactivate/reactivate/dispose and continued
sharing by SSH/SFTP/Realtime/Relay.
