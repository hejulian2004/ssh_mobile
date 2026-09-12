Last updated: 2026-09-11

# realtime_media_android

`realtime_media_android` is the Android platform owner for the public
`realtime_media` endpoint lifecycle. Kotlin owns MediaProjection, the typed
foreground service, hardware H.264 MediaCodec instances, and Flutter
SurfaceTexture resources. A small JNI bridge invokes the existing native-only
owner-token ABI; encoded H.264 never enters Dart.

The Dart method channel carries bounded endpoint identity, source metadata,
projection/lifecycle commands, opaque texture IDs, and low-frequency counters.
No runtime pointer, raw/encoded frame, `Uint8List` media API, or Surface handle
is exposed. Hardware encoder/decoder unavailability is reported as a typed
failure; there is no software or alternate-codec fallback.

Generation-bound owner tokens also carry payload-free `requestKeyframe`,
`resetDecoder`, and bounded `applyAdaptation` commands. Kotlin/JNI and the
native runtime validate the token before touching a codec. Android applies
bitrate and frame-rate targets through the hardware MediaCodec; a resolution
change is rejected until an explicit stop/release/recreate path is used. Send
owners request a MediaCodec sync frame and receive owners use the native
WebRTC RTCP path; neither path exposes Dart bytes. Device capability and E2E
remain acceptance gates.

The encoder keeps a 64 KiB maximum SPS/PPS cache. It accepts codec
configuration from both `BUFFER_FLAG_CODEC_CONFIG` output and
`INFO_OUTPUT_FORMAT_CHANGED` `csd-0`/`csd-1`, normalizes and validates those
parameter sets as Annex-B, and drops deltas until a complete CSD+IDR has been
accepted by native `pushH264` (`0`, including accepted-after-dropping). A
frame-dropped result keeps the recovery gate closed. Codec-config is cache
state, not a standalone native media frame; malformed or oversized CSD fails
closed. On the receive side, every validated parameter-set update relocks the
recovery gate, including an IDR that carries the update; the decoder replays
codec-config and rechecks that IDR, then opens delta input only after the
recovery IDR is successfully queued into `MediaCodec`.

The decoder learns CSD only from received Annex-B access units. It retains the
last validated CSD across `flush()`, replays it before a recovery IDR, and
drops deltas before CSD/recovery readiness. At most one pulled frame is held
under MediaCodec input backpressure; a pending frame blocks another native
pull, and reset clears it so pre-reset deltas are never replayed.

## Projection lease and teardown

Each user grant is a one-shot `ProjectionLease`:

```text
granted -> consumed -> released
```

`consumed` permits exactly one `createVirtualDisplay()` call. A normal safe
stop releases the VirtualDisplay, codec, and surface before unregistering the
projection callback and calling `MediaProjection.stop()`. A terminal startup
failure performs the same release when no worker cleanup is deferred. When
`stopCapture` returns `cleanup_deferred`, the consumed lease remains associated
with its owner, including its callback and projection, until a later retry
reaches the safe point. Projection revoke is delivered only to that bound send
owner. Display-size changes remain `capture_source_ended` and require restart
with a new grant; rotation hot-resize is a known device-acceptance gap. The
lease transitions are claimed under one state-machine synchronization boundary
for consume, revoke, release, and release-if-granted; callback unregister and
`MediaProjection.stop()` run only after a successful terminal claim. A
pre-consume failure may release a captured `GRANTED` lease only when it is still
the current lease, while consumed cleanup-deferred owners remain retryable.

The App Shell reuses one App-scope `AndroidRealtimeMediaBackend` across routes.
That backend serializes projection preparation: `acquired` transfers the grant
and slot to the caller, while `invalidated` and failed preparations report that
the backend already cleaned up. Attach success releases the slot immediately;
attach failure retains it until the caller's single abandon completes. This
keeps asynchronous route disposal from affecting a later grant without adding
a grant or transaction ID.

## Current Phase 4 boundary

The package implements the deterministic MediaProjection/MediaCodec/Texture
owner lifecycle and native owner-token bridge. Device-specific permission,
projection-revocation, codec capability, rotation/background, and two-device
E2E evidence remain acceptance gates and are not implied by source or host
compilation alone.

## Validation

```sh
flutter analyze --no-pub
flutter test --no-pub
```

From the application Android project, use the repository's Gradle wrapper for
the Android compile and instrumentation checks when an SDK/device is present.
