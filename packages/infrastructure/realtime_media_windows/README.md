Last updated: 2026-09-08

# realtime_media_windows

`realtime_media_windows` is the Windows-owned adapter for the public
`realtime_media` endpoint lifecycle. It composes the App Shell's native
endpoint lease backend with a Windows platform owner. The native owner now
implements Windows Graphics Capture for display/window sources, a native Media
Foundation H.264 hardware send-ingress worker, and a hardware receive decoder
with D3D11/Flutter Texture ownership.

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

The same owner token carries payload-free `requestKeyframe`, `resetDecoder`,
and bounded `applyAdaptation` commands. Native rate limiting and generation
checks apply before a platform owner touches the encoder or decoder. Windows
applies bitrate targets through the Media Foundation hardware MFT and bounds
frame-rate in the native capture state; a resolution target that differs from
the source is rejected and requires an explicit stop/release/recreate. PLI and
IDR requests stay on the native WebRTC/codec path and never become Dart bytes.

Release ordering is platform detach/close first, then native endpoint lease
release. The package does not own `NetworkRuntime`, signaling, consent, TURN
credentials, or feature state.

## Current phase boundary

This package now includes the runtime owner-token bridge and a native Windows
Graphics Capture lifecycle owner for monitor/window sources, the native Media
Foundation H.264 send ingress, and the receive-side hardware decoder/GPU
surface owner. Capture buffers, encoded access units, decoded textures, and
texture handles remain native; source close, resolution-change restart
boundaries, stop, and release are handled without a Dart frame path. Hardware
availability and Windows E2E acceptance remain separate gates; this package
must still fail closed when a platform capability is unavailable or stale.

## Validation

```sh
flutter analyze --no-pub
flutter test --no-pub
```
