最新更新时间：2026-09-07

# ssh_mobile_network_native 维护约束

## Scope and public boundary

- Allowed: Dart FFI facade, native asset hooks/platform build, Rust bindings,
  protocol bytes/state enums, and tests. Changes sync `network_transport`, build
  docs, and Dart/Rust tests. Public API is
  `package:ssh_mobile_network_native/ssh_mobile_network_native.dart` and hides
  Rust handles, sockets, WebRTC objects, and internal tags.
- `NativeNetworkProtocol` remains a static facade; encoding, event-envelope
  dispatch, Peer/Delivery/Transfer/Realtime/Stream mapping, and bounded FFI
  validation are separate stateless collaborators. New wire families go to their
  decoder, not back into the facade. No Feature/App/UI/global Service or copied
  LAN/SSH/SFTP implementation.

## Delivery, Session, and crypto

- Delivery application ACK binds current ConnectionSession Session ID, Channel,
  and Message ID. Recovery Epoch stays Rust Delivery state and never becomes
  Dart identity or echoed field. InFlight and Processed messages differ; only
  Processed may ACK. `SessionBoundOrdered` keeps expected sequence, one in-flight
  message, and bounded reorder buffer in native Delivery; Dart event order cannot
  compensate. Pending Delivery stores logical plaintext only, never route
  ciphertext; Delivery/Transfer managers resume business state on a new session.
- Every transport Connection creates a fresh SessionId/Noise root; loss destroys
  its ConnectionSession. One session's QUIC/Relay/file chunks share one
  CryptoContext; a new connection re-encrypts with a new root. `SendMessage`/
  `DataMessage` have no per-message crypto mode; native ConnectionSession always
  applies E2EE. Relay forwards opaque bytes and never reads plaintext, content
  keys, or nonce.

## Native tasks and network ownership

- All Rust background work is registered with `RuntimeTaskSupervisor`; no unowned
  `tokio::spawn`. A bounded local `JoinSet` is allowed only when its surrounding
  owner registers and joins it. ConnectionSession carrier/channel/file receivers use its child
  group; Delivery retry and Transfer resume workers remain business-manager-owned
  across loss. There is no ConnectionSession-owned reconnect/direct-upgrade task.
  Runtime stop cancels root, closes Relay/WebRTC/QUIC owners, awaits all tasks,
  then releases runtime.
- NAT candidate exchange is native-owned: one shared UDP socket passes through
  STUN gathering to Quinn; authenticated QUIC is the bounded production check.
  Do not add raw UDP probe protocol or competing `recv_from` loop. Offer/Answer
  preserves generation, attempt ID, connect window, stale-answer rejection, and
  Relay fallback.
- WebRTC data plane is native-only. `network-webrtc::RealtimeIoDriver` owns UDP,
  sans-I/O `WebRtcPeer`, and polling under `RuntimeTaskSupervisor`; Dart/Feature
  never opens another socket or calls `poll_write`, `poll_read`, or
  `handle_timeout`. Host candidates precede SDP; trickled STUN/TURN candidates
  use authenticated signaling; `relay_only` is reserved for TURN fallback/
  privacy validation. Local E2E and coturn relay-only tests remain network-quality
  gates.
- Screen-media Dart FFI is lifecycle-only: Dart may create/release an opaque
  endpoint ID bound to the active runtime/realtime generation, but no encoded
  frame, decoder output, renderer handle, or capture buffer may cross this
  facade. The separate native-only C ABI may push/pull encoded H.264 between
  platform owners and Rust by that opaque ID; it is never declared to Dart.
- No database or persisted secret; upper secure storage/Feature Module owns
  pairing credentials, Tokens, and history. `NativeNetworkRuntime` enforces
  `Running → Stopping → Stopped → Destroyed`, idempotent stop, and rejects
  commands after stopping begins.

## Validation（代码变更）

Peer/Session/Path/Lease, Direct/Relay, recovery, Delivery/Transfer/Stream, E2EE,
nonce/counter/key lifecycle, cancellation/timeout/race, FFI mapping, or wire
changes start with failure-first tests plus Dart↔Rust/contract acceptance.

```bash
dart analyze
dart test
cargo fmt --all -- --check
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
# with coturn on 127.0.0.1:3478:
cargo test -p network-webrtc --locked -- --ignored relay_only_drivers_exchange_data_channel_payloads
```

Local aggregate CI is user-opt-in; package/native focused checks remain required
when the code boundary changes.
