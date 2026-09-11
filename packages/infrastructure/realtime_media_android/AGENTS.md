Last updated: 2026-09-11

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

## Lifecycle contract

Projection permission and the typed foreground service must be active before
capture starts. A `ProjectionLease` is single-use: `granted → consumed →
released`, and one consumed `MediaProjection` may create only one
VirtualDisplay. Native owner start validates the generation; capture stops
before encoder/decoder and SurfaceTexture release; owner close remains separate
from endpoint release. Normal projection teardown unregisters the callback
before calling `MediaProjection.stop()`.

If an encoder worker cannot reach its safe point within the existing timeout,
the owner returns `cleanup_deferred` and retains the consumed lease, callback,
projection, codec, and VirtualDisplay for a later release retry. It must not
stop the projection while that worker is still active. Permission denial,
projection revoke, surface loss, stale owner, repeated stop, and late callbacks
fail closed and are retry-safe; projection revoke is routed only to the bound
send owner. Display-size changes remain `capture_source_ended`, not a hot
resize path.

## Validation

```sh
flutter analyze --no-pub
flutter test --no-pub
```

The Android Gradle build and instrumentation tests are additional Phase 4
gates and require an Android SDK/device or emulator.
