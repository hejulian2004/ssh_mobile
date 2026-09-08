Last updated: 2026-09-08

# realtime_media

`realtime_media` owns the Dart lifecycle contract for an opaque native screen-media endpoint. It is infrastructure: it does not own `NetworkRuntime`, a WebRTC peer, signaling, a network socket, capture, encoding, decoding, or renderer implementation.

The public API contains only endpoint/session identity, lifecycle, capture-source selection metadata, a renderer capability, and payload-free statistics. Statistics are requested as a low-frequency `readStats` snapshot, never a media stream; the bounded QoS counters and adaptation decision are metadata only. Raw or encoded frames never cross this package's Dart API. Native platform adapters introduced by later phases own capture/codec/surface resources and use the native bridge directly.

The optional `RealtimeMediaKeyframeBackend` capability exposes generation-bound
`requestKeyframe` and `resetDecoder` commands without carrying frame payloads.
It is a recovery port only: platform owners and the native WebRTC peer retain
the request, and native owners may turn it into bounded codec/RTCP recovery.

The optional `RealtimeMediaAdaptationBackend` capability carries one bounded
bitrate/framerate/resolution decision to the native owner. The native owner
applies bitrate and frame-rate changes without changing the fixed three-frame
queue; a resolution change is an explicit stop/release/recreate operation.
No frame payload or per-frame statistic is part of this capability.

## Ownership and release

`RealtimeMediaSessionController` owns its endpoint leases. It releases an endpoint in this order: detach the native source/surface binding, release the native endpoint lease, then mark the renderer capability released. `stop()` is the terminal, idempotent controller-level release after native cleanup succeeds; `dispose()` is its idempotent lifecycle alias and is safe before `start()`. The first terminal call closes the controller to new work immediately, waits for any in-flight native acquisition to be reclaimed, and shares its cleanup result with concurrent `stop()` or `dispose()` calls. Releasing an endpoint or controller is idempotent; controller release continues cleaning later leases after an earlier failure. A retryable native cleanup failure retains the endpoint lease, leaves the controller failed, and clears the in-flight release so a later `release()` or `stop()` retries it. A native endpoint acquired after stopping begins is registered before cleanup, so a failed late-start release remains retryable through the same ownership registry. Stale or already-stopped native leases are terminal and can be finalized. A lease is bound to realtime ID, peer ID, generation, and direction, so it cannot be reused by a new session generation. In-flight source/surface attach and detach operations re-check the lease before committing state; a late attach is detached/released and cannot resurrect a stopped endpoint. A malformed surface generation is released and fails closed.

Feature code may request an operation through its injected business port and release only its own operation/subscriptions. It never disposes the app-owned network runtime or native handle.

The App Shell native adapter receives a `RealtimeSessionToken` from
`network_sdk` and forwards its native-authoritative generation unchanged to
the endpoint ABI. Signaling revisions are not accepted as a substitute.

The Windows phase composes this contract through the separate
`realtime_media_windows` infrastructure package. That package's
`WindowsRealtimeMediaBackend` uses a native `WindowsRealtimeMediaPlatform`
whose method-channel implementation carries only source/endpoint identity,
lifecycle commands, an opaque renderer ID, and payload-free statistics;
capture buffers, H.264 data, decoder state, and texture resources remain
native-owned.

## Validation

```sh
flutter analyze --no-pub
flutter test --no-pub
```
