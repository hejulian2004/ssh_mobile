Last updated: 2026-10-23

# realtime_media_android

`realtime_media_android` is the Android platform owner for the public
`realtime_media` endpoint lifecycle. Kotlin owns MediaProjection, the typed
foreground service, selected H.264 MediaCodec instances, and Flutter
SurfaceTexture resources. A small JNI bridge invokes the existing native-only
owner-token ABI; encoded H.264 never enters Dart.

The Dart method channel carries bounded endpoint identity, source metadata,
projection/lifecycle commands, opaque texture IDs, low-frequency counters, and
normalized guidance-path snapshots. The guidance window uses
`SYSTEM_ALERT_WINDOW`, does not receive touches, and is removed with the
capture foreground service. Denying that permission does not stop capture.
No runtime pointer, raw/encoded frame, `Uint8List` media API, or Surface handle
is exposed. Automatic mode is the default: hardware candidates precede software
H.264. Explicit CPU mode selects software
H.264 using a scoped factory choice; it preserves system recording consent,
owner cleanup, and the native frame path. Unknown modes and unavailable selected
codecs fail with typed errors; automatic fallback stays within H.264 and never
changes consent or endpoint identity.
Screen-share permission requests select the default display on API 34+ using
`MediaProjectionConfig.createConfigForDefaultDisplay()`, retaining Android's
consent dialog; earlier APIs use their display-capture intent. Navigating away
from the Flutter sharing page does not release the grant or native service.
Configuration tries hardware then software H.264 candidates in automatic mode;
explicit hardware or CPU mode restricts candidates to that implementation. Each
failed attempt is released before trying the next;
unconfirmed cleanup aborts acquisition. A configured codec transfers to the
existing media owner; exhausting unsupported formats fails capture/decoder startup.

Generation-bound owner tokens also carry payload-free `requestKeyframe`,
`resetDecoder`, and bounded `applyAdaptation` commands. Kotlin/JNI and the
native runtime validate the token before touching a codec. Android applies
bitrate and frame-rate targets through the selected MediaCodec; a QoS-requested
resolution change is rejected until explicit stop/release/recreate. Captured
content rotation instead uses the same projection/display resize path below. Send
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

`DecoderOutputPump` polls asynchronous codec output independently of new input,
including while a static screen supplies only one access unit. Format/buffer
notifications do not hide ready output, each drain is bounded, and a stopped
owner cannot submit or release another output frame. Its independent JVM tests
cover delayed single-frame output and cancellation.

`DecoderPresentationGate` bounds presentation separately from decoding. Hidden
Activities keep decoding and retain only the latest output buffer. Visible
Activities submit another texture frame only after Flutter consumes the prior
one, preventing a paused texture consumer from filling the Surface queue.
Returning to the foreground can display the retained frame without new input.
Flush/stop return pending codec indices before invalidating the codec. The
engine-scoped visibility observer follows only its attached Activity and does
not hold an Activity lock while calling MediaCodec.

Remote video playback uses a separate native `mediaPlayback` foreground service
and service-local partial wake/Wi-Fi locks. It borrows the existing native
endpoint/runtime and does not create a Flutter background engine or release
SSH-owned locks. Readiness must complete before decoder attachment; cancellation,
startup refusal, or its deadline fail the pending request exactly once. Decoder
creation re-enters the owner's frozen CPU/hardware mode after this async boundary.
Service-instance epochs isolate delayed destruction callbacks. Stop/release
cancels pending readiness and retains the service only while receive resources
still need acknowledged cleanup. The service owns lock renewal and releases its
locks on destruction; it is not restarted automatically after process death.
Device policy still controls foreground-service availability and system privacy
revocation. The service type follows Android's
[background media playback contract](https://developer.android.com/develop/background-work/services/fgs/service-types#media).

Decoded size statistics use the current output format's validated crop rectangle,
so portrait/landscape transitions can reduce either dimension. They do not retain
the largest width and height seen across different orientations.

The module-internal encoder, decoder, and teardown extensions borrow the same
`AndroidMediaOwner` lock, worker flags, codec/surface references, and native
token; they do not create another resource owner. MediaCodec/JNI/thread teardown
wrappers require device acceptance rather than JVM line-coverage claims. The
pure pump, H.264 gates, pending-frame buffer, and projection lease are covered
by host unit tests, as are presentation backpressure, capture-input replacement
ordering/cancellation, timestamp continuity, output crop validation, and foreground
readiness cancellation/deadline races. The Activity observer, codec/display resize,
playback service, ResultReceiver adapter and power-lock wrappers require Android
device acceptance; their platform calls are excluded from JVM line-coverage
claims rather than simulated with Android stub methods.

## Projection lease and teardown

After system consent, the plugin waits for the typed foreground service's ready
callback before obtaining `MediaProjection`. Android requires this ordering;
requesting the projection before `startForeground()` can reject a granted
session. Pending callbacks remain bound to their request and cannot create a
lease after plugin disposal. An unconsumed grant keeps the service alive until
capture starts or the grant is abandoned; release stops it when no capture
owner still needs it.

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
owner. Captured-content size changes are coalesced within this same lease.
API 34+ uses `onCapturedContentResize`; earlier full-display capture observes
the display size. The existing encoder worker detaches the VirtualDisplay input,
releases the previous codec/surface, configures a replacement in the same frozen
CPU/hardware mode, resizes that VirtualDisplay, and attaches the new input.
It never calls `createVirtualDisplay` a second time. Stop/revoke interrupts this
transaction at safe boundaries and leaves acquired resources with the same owner
for acknowledged teardown. A release failure prevents replacement acquisition.
The replacement emits fresh CSD/recovery IDR; the owner's sequence and timestamp
timeline continue, including when a new codec restarts its presentation clock.
Unsupported dimensions fail explicitly. Actual continuous rotated video still
requires device acceptance. The
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

`test/android/DecoderSingleFrameProbe.java` is a device diagnostic for the
Android software H.264 decoder. Compile it against `android.jar`, package with
D8, and run through `app_process` with the fixed Annex-B fixture exported by
the Windows encoder probe. It compares sparse input, repeated synthetic input,
and end-of-stream flushing using bounded byte-buffer output polling. This
checks codec buffering, not Flutter surface rendering; end-of-stream is only
a diagnostic control and is never injected into a live sharing session.

`test/android/EncoderCapabilityProbe.java` checks only AVC encoder capability
metadata through `MediaCodecList`. Compile with `android.jar`, package with D8
and run with `app_process`; it reports hardware/software availability without
capturing a screen or reading application data. Capability absence is an
actionable selected-mode failure, not permission to silently fall back.
