Last updated: 2026-09-07

# realtime_media maintenance contract

## Scope

- Allowed: opaque endpoint/session lifecycle contracts, platform-adapter interfaces, source selection metadata, renderer capability/status, payload-free statistics, and independent tests.
- Forbidden: Feature/UI business state, network runtime ownership, WebRTC signaling/peer construction, socket ownership, FFI pointer exposure, per-frame Dart media APIs, frame persistence, or a second media runtime.

## Ownership

- `RealtimeMediaSessionController` owns only endpoint leases borrowed from the app-owned native runtime.
- Future platform adapters own capture, encoder/decoder, and renderer resources for their session scope; their release order is detach → close platform resource → release endpoint.
- `RemoteVideoSurface` is an opaque renderer capability. It has no payload or native-address API.
- Every endpoint operation must preserve the `(realtimeId, peerId, generation, direction)` binding. Old generations fail closed.

## Tests and validation

New lifecycle behavior starts with a deterministic failure-first test in `test/`. Do not add test-only hooks to production code. Run:

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
```
