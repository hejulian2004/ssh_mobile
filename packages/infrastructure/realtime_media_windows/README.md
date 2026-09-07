Last updated: 2026-09-07

# realtime_media_windows

`realtime_media_windows` is the Windows-owned adapter for the public
`realtime_media` endpoint lifecycle. It composes the App Shell's native
endpoint lease backend with a Windows platform owner. The eventual native
owner will implement Windows Graphics Capture for display/window sources,
Media Foundation H.264 hardware encode/decode, and GPU/Flutter Texture
rendering.

The Dart side deliberately carries no frame bytes, encoded data, native
addresses, or GPU buffers. Its method channel contains only bounded endpoint
identity, source metadata, opaque surface IDs, lifecycle operations, and
low-frequency payload-free statistics. A missing or unsupported native plugin
is a typed failure; it is never treated as a successful software fallback.

Release ordering is platform detach/close first, then native endpoint lease
release. The package does not own `NetworkRuntime`, signaling, consent, TURN
credentials, or feature state.

## Current phase boundary

This package establishes the Phase 3 Dart/native boundary and deterministic
contract tests. Production Windows Capture/Media Foundation/texture code is a
separate native implementation gate and remains incomplete until Windows E2E
evidence is available.

## Validation

```sh
flutter analyze --no-pub
flutter test --no-pub
```
