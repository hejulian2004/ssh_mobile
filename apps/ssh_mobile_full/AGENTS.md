最新更新时间：2026-10-11

# ssh_mobile_full 维护约束

## App Scope contract

- `AppRuntimeFactory` is the sole composition root for App identity,
  `NetworkRuntime`, native command gateway, and shared `NetworkFacade`; one
  App process performs at most one successful `ConfigureRuntime`, on first
  network use. Cold event/diagnostic subscriptions must not initialize keys
  or native handles. LAN, SSH, SFTP,
  Realtime, and Relay borrow these resources.
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
