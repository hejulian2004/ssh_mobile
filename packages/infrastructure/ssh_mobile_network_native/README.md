> Last updated: 2026-09-07

# SSH Mobile Network Native

This Dart FFI package builds and bundles the repository's Rust
`network-ffi` crate. It exposes a managed `NativeNetworkRuntime` that sends
versioned Protobuf commands and streams raw Protobuf events back to Dart.

Native event polling runs on a helper isolate because the Rust poll call may
block. Runtime disposal first asks that isolate to stop, waits for its exit,
and only then destroys the Rust handle.

`NativeNetworkProtocol` remains the stable static API while its implementation
is split by ownership: command envelope encoding, event-envelope dispatch,
Peer/environment mapping, Delivery/Transfer mapping, Realtime/SSH Stream
mapping, and bounded FFI value validation. These collaborators do not change
wire tags or expose native resources.

The current Network Protocol V2 runtime handles peer registration with pinned Ed25519/X25519
keys, per-peer `PathManager` selection, authenticated Quinn sessions, approved
and verified file receive, cancellation, progress/completion events, the
native WSS Relay data path, and a WebRTC Realtime route over the current ConnectionSession. The
native `RealtimeIoDriver` now owns each WebRTC UDP socket and drives the
sans-I/O ICE, DTLS, SRTP, SCTP/DataChannel, and timeout pump under the Runtime
TaskSupervisor. Dart can submit bounded Realtime commands and consume typed
state/signaling events; Rust still owns all long-lived network state, sockets,
WebRTC peers, and Relay data frames. Unsupported commands and routes return
explicit errors rather than synthetic success.

Each authenticated transport Connection creates exactly one ConnectionSession with a
fresh SessionId and Noise root. Transport loss destroys it; Delivery/Transfer
business state is retained above that boundary and resumes on a later connection.

## Network Protocol V2 contract

- Network Protocol V2 is the only active native SDK/Data contract. Relay
  Bootstrap V1 remains a separate enrollment/version domain.
- `NativeNetworkRuntime` exposes typed operation status values to Dart and
  keeps raw FFI integers private to the package.
- `NativeNetworkRuntime.startRealtimeSession`,
  `stopRealtimeSession`, and `sendRealtimeSignal` expose only stable IDs,
  revisions, enum values, and bounded byte payloads. `events` decodes command
  results and Realtime state/signaling events without exposing Rust pointers,
  Quinn connections, UDP sockets, or WebRTC raw objects. Realtime state and
  snapshot events also carry the native-authoritative session generation;
  signaling revision is never used as its substitute.
- `NativeNetworkRuntime.createRealtimeMediaEndpoint` and
  `releaseRealtimeMediaEndpoint` are additive lifecycle controls for an opaque
  native screen-media endpoint. Create carries the caller's expected Realtime
  generation; native validates it under the Realtime manager lock. Media
  lifecycle results preserve stale-generation/endpoint, direction, duplicate,
  driver, peer, and frame-rejection categories instead of reusing the general
  command ABI's historical `-2` value. The facade exposes only a
  generation-bound ID and a direction; capture buffers, H.264 access units,
  decoder output, RTP, and renderer resources never cross Dart FFI or the event
  stream.
 - The companion native-only C ABI uses a generation-bound opaque owner token
   for start/stop/close, renderer attach/detach, and bounded encoded-H.264
   push/pull between a platform capture or decoder owner and Rust. It is not
   declared in this Dart package, so it cannot become a per-frame Dart path.
- Delivery application acknowledgements use the current ConnectionSession Session
  ID, Channel ID, and Message ID. Recovery epochs remain native Delivery state;
  Dart must not cache or echo an epoch from an earlier event or connection.
- `SessionBoundOrdered` delivery is also native-owned: only the expected
  sequence reaches the application, while later messages stay in bounded
  reorder state until the current application ACK releases the next one.
- All native background work is owned by `RuntimeTaskSupervisor`: the root
  cancellation scope owns runtime tasks, and each ConnectionSession owns a
  cancellable child group for its carrier, channel receivers, and file receivers.
  Delivery retry and Transfer resume workers remain business-manager-owned across
  transport loss; v2 has no ConnectionSession-owned reconnect or direct-upgrade task.
  `stop()` cancels the root, closes Relay/WebRTC/QUIC resources, and waits for
  every registered task before returning.
- Application payload crypto is ConnectionSession-owned; every new transport
  Connection gets a fresh SessionId and Noise root. Network Protocol V2
  messages do not carry a per-message crypto mode: the native owner always
  applies E2EE. Delivery retains logical plaintext and re-encrypts each retry;
  the same `CryptoContext` covers QUIC/Relay data within one ConnectionSession,
  while Relay sees only ciphertext.
- NAT traversal uses the same native UDP socket for candidate gathering and
  Quinn. Candidate Offer/Answer carries generation, attempt ID, and a bounded
  connect window; both peers may run simultaneous authenticated QUIC Initial
  attempts, and Relay remains the fallback. Raw UDP probe packets are not a
  second production protocol. Optional native STUN discovery accepts a
  comma-separated `SSH_MOBILE_STUN_SERVERS=host:port,host:port` list and
  validates transaction IDs plus IPv4/IPv6 XOR-MAPPED-ADDRESS responses.
- WebRTC TURN is configured natively through `SSH_MOBILE_TURN_SERVERS` (or
  `SSH_MOBILE_TURN_URL`) plus `SSH_MOBILE_TURN_USERNAME` and
  `SSH_MOBILE_TURN_CREDENTIAL`; setting `SSH_MOBILE_TURN_RELAY_ONLY=true`
  disables direct ICE candidates for relay-only validation. TURN credentials
  stay in the runtime object and are never emitted as events or logs.
- Runtime disposal is ordered as `Running -> Stopping -> Stopped -> Destroyed`;
  stopping is idempotent and no command is accepted after stopping begins.
- Native events use separate bounded Result, Control, and Data lanes. Terminal
  `CommandResultV2` delivery applies async backpressure to the command worker,
  while lifecycle/progress overflow remains governed by the existing bounded
  policy; completed command IDs are retained in a rolling duplicate-detection
  window rather than consuming a runtime-lifetime quota.
- `NativeNetworkRuntime.boundLocalPort` is a read-only diagnostic for controlled
  integration tests. It reports the port atomically bound by native QUIC after
  configuration and returns `null` before configuration or after stopping; it
  does not expose a socket, Quinn handle, or client business API.
- Relay enrollment, credentials, and configuration stay in Dart; the native
  Rust runtime owns the authenticated WSS data path and its end-to-end
  encrypted frames.
- LAN WebShare is HTTPS-only. A browser without a secure context or required
  WebCrypto support is rejected instead of silently downgraded.

## Supported build targets

- Windows: x64 and arm64
- Android: arm64, x64, and armv7
- iOS: arm64 device, arm64 simulator, and x64 simulator
- macOS: arm64 and x64
- Linux: arm64 and x64

The build hook invokes Cargo with `--locked`. Cargo and the requested Rust
target must be installed. Android builds also require an installed NDK
discoverable through the standard Android SDK or NDK environment variables.

## Validation

From this package directory:

```sh
dart analyze
dart test
```

From `native/network_core`:

```sh
cargo fmt --all -- --check
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
# With coturn listening on 127.0.0.1:3478:
cargo test -p network-webrtc --locked -- --ignored relay_only_drivers_exchange_data_channel_payloads
```

## Package contract

- 职责：提供 Rust `network-ffi` 的 Dart FFI facade、native asset hook 和 Network Protocol V2 绑定。
- 不负责：Feature 业务、App Shell 生命周期、数据库或第二套 Dart 网络协议实现。
- Public API：`package:ssh_mobile_network_native/ssh_mobile_network_native.dart`。
- 依赖：Dart FFI、`code_assets`、`hooks` 和 Rust `native/network_core` 构建产物。
- 数据库：不拥有数据库，也不持久化配对凭据、Token 或业务历史。
- 生命周期与资源 Owner：调用方拥有 `NativeNetworkRuntime`；必须先停止 helper
  isolate，再销毁 Rust handle，并保持 stop/destroy 幂等。
- 测试命令：`dart analyze`、`dart test`、Cargo format/test/clippy 检查。
