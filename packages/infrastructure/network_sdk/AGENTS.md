最新更新时间：2026-09-07

# network_sdk 维护约束

LAN/Network V2 is breaking-only: no old API wrapper/alias, LAN pairing/storage
migration, V1/V2 dual path, old file fallback, or native wire V3. LAN Control V2
and Native Network V2 remain separate domains.

## Scope and dependencies

- Allowed: typed Flutter network contracts, results/errors/events, request
  executor, JSON Bootstrap/auth clients, public exports, fakes, and contract
  tests. Sync App Shell adapters, Feature callers, dependency/ownership docs.
- No Feature/App `/src/`, `ssh_mobile_network_native`, FFI symbols, Socket,
  HTTP client, Secure Storage, DB, Timer, Isolate, App runtime, or second QUIC/
  Relay/WebSocket/file protocol. `SdkRequestExecutor`/TLS/platform policy is
  App-injected.

## API invariants

- `BootstrapClient` has no Bearer. `JsonBootstrapClient` uses injected
  `SdkRequestExecutor` for public probe/enrollment and never imports `dart:io`.
  `AuthenticatedApiClient`/`JsonAuthenticatedApiClient` are control-plane only;
  authenticated JSON retries at
  most once after 401, then invalidates session and never logs Token.
- `NetworkFacade` is the sole Feature network boundary: high-level connect/
  transfer/realtime/relay operations hide Candidate/Resolve/PathManager/Relay
  and add no native tag.
  `registerPeer`, `connectPeer`, `disconnectPeer`, and `removePeer` are separate;
  connect requires prior register; removePeer is explicit trust revoke/unpair,
  never discovery timeout, Relay disconnect, route change, background, or
  deactivate. `SdkPeerConfig.allowDirect/allowRelay` is pre-filtered route
  eligibility and unauthorized routes fail in native selection.
- `CommunicationClass` stays the five existing business categories and maps to
  current native tags. `SessionClient` is the internal business Session/Transfer
  layer; `EventStreamClient` exposes one typed event stream. `sendMessage` remains the
  stable unavailable/invalid-argument boundary; LAN text/clipboard use
  authenticated HTTPS + application E2E, with no temporary plaintext fallback.
- `RealtimeSession` is the Feature signaling/state API (`state`, `revision`,
  native-authoritative `generation`/`mediaToken`, `audioState`, `start()`,
  `stop()`). Opaque screen-media endpoint/surface
  lifecycle belongs to `realtime_media`; no per-frame Dart API or
  SDP/ICE/PeerConnection/socket/native handle/media resource leaks to Features.
  App adapter maps backend events;
  `start/stop` Futures complete only after `NativeCommandResultEvent`; queue
  acceptance never advances state. `RealtimeStateChangedEvent` is the state
  source of truth, and stop waits for native `closed`.
- Existing type aliases stay centralized here only while used outside the current
  boundary; Features must not create/export local `network_models.dart`. New
  transport implementations require an ADR and never a `*SocketClient` type.
- Network V2 ports expose Connection/Identity/Transfer/Realtime/Relay lifecycle;
  `NetworkV2FacadeImpl` orchestrates but does not own injected command ports.
  Facade dispose releases its own state only; App/native owner disposes command
  ports. Feature deactivate cancels subscriptions, never Facade start/stop/dispose.

## Validation（代码变更）

JSON/request/error mapping, refresh, Facade/Realtime transitions, dispose, or
native/wire changes start with failure-first Dart contract tests; cross-boundary
changes add Dart↔Rust/protocol gates. Run package `flutter analyze --no-pub` and
`flutter test --no-pub`; local aggregate CI is user-opt-in.
