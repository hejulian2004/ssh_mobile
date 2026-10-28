最新更新时间：2026-10-23

# network_transport 维护约束

- Scope: App Scope network runtime, lazy Capabilities, transport endpoint/
  connection contracts, and native adapter. Do not implement TCP/UDP/QUIC/
  WebRTC protocols, Feature UI, SSH sessions, or LAN business rules.
- Production depends only on `app_core` and `ssh_mobile_network_native`. Features
  use `network_transport.dart`; never `/src/`. Only AppRuntime/Composition Root
  creates `NetworkRuntimeImpl`/`NativeNetworkAdapter`; no static cross-App
  singleton. Runtime owns native handle and `diagnostics` may report only its
  own handle/registered capabilities/
  connections; `boundLocalPort` is read-only projection, not ownership transfer.
- `openCommandGateway()`/`openRealtimeGateway()` return gateways that borrow the
  Runtime handle; they copy/close neither it nor business protocol. Realtime only
  maps typed native commands/events. `NetworkRealtimeApplicationGateway` is an
  optional byte send for one realtime generation; payloads stay opaque.
  `start/stop` return `NativeCommandTicket`,
  separating queue
  acceptance from `NativeCommandResultEvent`; App adapter owns result correlation,
  timeout, pending map, and subscriptions.

## Lifecycle and Wave 1

- Capability first use lazily creates a handle; concurrent calls share one Future,
  failure clears in-flight state for retry. `NetworkCapability.runtime` means
  command-worker handle only, independent of QUIC/WSS/Realtime capabilities.
- Wave 1 still uses `ConfigureRuntime`, which always initializes direct QUIC/TCP;
  QUIC-free WSS-only data plane is deferred to Wave 2 and does not exist. Opening
  command gateway ensures only runtime, not QUIC.
- Dispose waits for pending creation, performs `create → start → stop → destroy`,
  then rejects new capability requests; Finalizer never replaces explicit close.
  AppRuntime/native owner releases the handle; borrowers cancel their own
  subscriptions. Realtime stops before Runtime dispose.
- Contract: allowed Runtime/Facade/Capability/native adapter/transport contracts
  and tests; no DB, pairing credentials, business history, second protocol, or
  Feature owner. API/Owner changes sync `network_transport.dart`, AppRuntime,
  Feature adapters, tests, and Architecture.

## 验证（代码变更）

`flutter analyze --no-pub`、`flutter test --no-pub`；native hook changes also run
Rust checks. Local aggregate CI 仅按用户明确要求运行。
