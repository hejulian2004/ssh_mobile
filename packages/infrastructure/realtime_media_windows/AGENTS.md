Last updated: 2026-09-08

# realtime_media_windows maintenance contract

## Scope

- Own the Windows platform adapter for the public `realtime_media` lifecycle
  contract.
- Keep Windows Graphics Capture, Media Foundation H.264, decoder state, GPU
  surfaces, and Flutter texture registration native-owned.
- Carry only bounded identity/source metadata, lifecycle commands, opaque
  surface IDs, and payload-free statistics over the platform channel.

## Forbidden changes

- Do not expose raw or encoded frames, native pointers, or GPU buffers to Dart.
- Do not move endpoint/session ownership out of `realtime_media` or the App
  Shell's injected native endpoint backend.
- Do not silently fall back to software codecs, another video codec, or a
  synthetic capture source when Windows hardware capability is unavailable.
- Do not add signaling, consent/UI business state, TURN credentials, or QoS
  policy here; those belong to their later owners.

## Native implementation gate

The Windows plugin now owns Graphics Capture, native Media Foundation H.264
send ingress, and the receive decoder/GPU texture lifecycle. Platform methods
must return a typed failure such as `encoder_unavailable` or
`decoder_unavailable` while a native capability is absent or stale; they must
not report a synthetic successful capture or surface.

## Validation

```sh
flutter analyze --no-pub
flutter test --no-pub
```
