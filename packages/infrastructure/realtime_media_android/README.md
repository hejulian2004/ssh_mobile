Last updated: 2026-09-08

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
