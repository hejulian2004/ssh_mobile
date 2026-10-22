Last updated: 2026-10-15

# realtime_media_android maintenance contract

## Scope

- Own Android MediaProjection, foreground-service, MediaCodec, SurfaceTexture,
  and Flutter texture lifecycle for the public `realtime_media` contract.
- Use the existing generation-bound native owner token and Phase 2 H.264
  push/pull port. Keep capture, codec, encoded access units, decoded pixels,
  and surfaces in the Android/native owner.
- Carry only bounded identity/source metadata, lifecycle commands, opaque
  surface IDs, and payload-free statistics over the Flutter channel.

## Forbidden changes

- Do not expose raw frames, encoded bytes, native pointers, or Surface objects
  to Dart, protobuf events, application Relay, or Feature packages.
- Do not create another NetworkRuntime, RealtimeManager, PeerConnection, or
  endpoint registry. Phase 2 endpoint/generation/release semantics are fixed.
- Do not silently fall back to software codecs, VP8/AV1, or an unbounded queue.
- Do not add consent, TURN credentials, business state, or QoS policy here.

Hardware codecs remain the default. Explicit CPU mode selects only software
H.264 MediaCodec instances within the synchronous owner operation. Nested and
concurrent requests must not leak a mode to another owner. Unknown modes fail
closed. CPU mode preserves system recording consent and the same native ABI.

## Lifecycle contract

Projection permission and the typed foreground service must be active before
`getMediaProjection()` and capture start. Service readiness follows system
consent and remains bound to the pending request. Disposal invalidates a late
ready callback; an unconsumed grant retains the service until consumption or
abandonment. A `ProjectionLease` is single-use: `granted → consumed →
released`, and one consumed `MediaProjection` may create only one
VirtualDisplay. Native owner start validates the generation; capture stops
before encoder/decoder and SurfaceTexture release; owner close remains separate
from endpoint release. Normal projection teardown unregisters the callback
before calling `MediaProjection.stop()`. The lease state machine uses one
synchronized transition boundary for `consume`, `revoke`, `release`, and
`releaseIfGranted`; platform teardown runs only after a terminal state claim.
`releaseIfGranted` can release only an unconsumed `GRANTED` lease, never a
consumed owner that is in `cleanup_deferred`.

If an encoder worker cannot reach its safe point within the existing timeout,
the owner returns `cleanup_deferred` and retains the consumed lease, callback,
projection, codec, and VirtualDisplay for a later release retry. It must not
stop the projection while that worker is still active. Permission denial,
projection revoke, surface loss, stale owner, repeated stop, and late callbacks
fail closed and are retry-safe; projection revoke is routed only to the bound
send owner. A pre-consume start failure releases the captured `GRANTED` lease
only if it is still the current lease. The App-scope Android backend serializes
permission preparation across route coordinators; caller-owned preparation is
abandoned exactly once, while backend-invalidated preparation is not abandoned
again by the caller.

Captured-content size changes retain the consumed projection and its single
VirtualDisplay. Only the existing encoder worker may detach the display's
input, release the old codec/surface, configure the frozen codec mode, resize
the display, and attach its replacement input. Check stop/revoke between these
steps; never acquire a replacement after unconfirmed old-codec release. Keep
the owner's sequence and monotonic timestamp timeline, reset CSD/IDR recovery,
and preserve bitrate/framerate policy. An unsupported new size is a typed
terminal encoder failure, never a new grant, shared source, or mode fallback.
API 34+ callbacks stay bound to their projection lease, coalesce the latest
positive dimensions, and are ignored after revoke/release. Older full-display
capture observes current display dimensions on the same worker.

Activity visibility affects presentation only, not the native receive/decoder
owner. Decoder output keeps at most one pending buffer and one submitted
texture frame awaiting Flutter's consumed callback. Drop older pending output
without rendering; resume the latest buffer without requiring another input.
Discard pending indices before codec flush and before worker stop acknowledgement.
Activity/configuration detach unregisters only the visibility observer, and no
Activity lock may be held across a codec operation. Receiver foreground-service
and power retention still require their own owner and device acceptance.

The encoder's bounded CSD cache accepts both MediaCodec codec-config output and
output-format `csd-0`/`csd-1`. The sender's recovery gate stays closed until a
complete CSD+IDR is accepted by native `pushH264`; the decoder relocks on every
parameter-set update and opens its delta path only after a recovery IDR has
actually been queued into MediaCodec. A pending decoder frame is bounded to one
and is cleared on reset.

## Validation

```sh
flutter analyze --no-pub
flutter test --no-pub
```

The Android host-unit gate is:

```sh
./gradlew :realtime_media_android:testDebugUnitTest --no-daemon --console=plain
```

The Android Gradle build and instrumentation tests are additional Phase 4
gates and require an Android SDK/device or emulator.
