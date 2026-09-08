Last updated: 2026-09-08

# realtime_media_windows

`realtime_media_windows` is the Windows-owned adapter for the public
`realtime_media` endpoint lifecycle. It composes the App Shell's native
endpoint lease backend with a Windows platform owner. The native owner now
implements Windows Graphics Capture for display/window sources; later gates
add Media Foundation H.264 hardware encode/decode and GPU/Flutter Texture
rendering.

The Dart side deliberately carries no frame bytes, encoded data, native
addresses, or GPU buffers. Its method channel contains only bounded endpoint
identity, source metadata, opaque surface IDs, lifecycle operations, and
low-frequency payload-free statistics. A missing or unsupported native plugin
is a typed failure; it is never treated as a successful software fallback.

The App Shell registers the endpoint with the existing NetworkRuntime through
an opaque, generation-bound native owner token. Windows code may retain that
token for its native capture/codec worker, but it never receives a Dart runtime
pointer; native owner start/stop/renderer attach/detach and the high-frequency
H.264 push/pull port remain entirely native.

Release ordering is platform detach/close first, then native endpoint lease
release. The package does not own `NetworkRuntime`, signaling, consent, TURN
credentials, or feature state.

## Current phase boundary

This package now includes the runtime owner-token bridge and a native Windows
Graphics Capture lifecycle owner for monitor/window sources. Capture buffers
remain native and source close, resolution changes, stop, and release are
handled without a Dart frame path. Hardware Media Foundation H.264,
decoder/GPU surface, Flutter Texture, and Windows E2E acceptance remain
separate gates; this package must still fail closed for those capabilities
until their owners are implemented and verified.

## Validation

```sh
flutter analyze --no-pub
flutter test --no-pub
```
