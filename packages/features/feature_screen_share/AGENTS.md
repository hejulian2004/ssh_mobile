最新更新时间：2026-09-12

# feature_screen_share 维护约束

## Boundary and ownership

- The Feature owns screen-share business state, consent, timeout, UI and its
  subscriptions only. It does not own a Realtime session, native runtime,
  endpoint, capture source, codec, surface or texture.
- Cross-layer access uses the public `ScreenShareConsentPort` and
  `ScreenShareMediaPort` contracts. There is no FFI, WebRTC, SDP, ICE, socket,
  native handle or encoded-frame dependency in this package.
- A media operation is bound to `(realtimeId, generation, operationId)`.
  Stale consent and late platform events are ignored. An incoming request never
  starts capture before explicit acceptance and media readiness.
- Feature disposal cancels timers and subscriptions and asks the borrowed media
  port to stop an active operation; it never stops or disposes App-owned
  NetworkRuntime/Realtime resources.
- `RealtimeIncomingSessionOffer` is metadata-only. Claim, reject, discard,
  session lease transfer, native generation identity, and source-token mapping
  remain App/platform responsibilities. Do not add `realtime_media`, native
  source IDs, SDP, ICE, texture IDs, or pending-offer handles here.
- `compareScreenShareIntents` is the only public collision comparator. Keep its
  UTF-8 `(initiatorPeerId, operationId)` semantics pure and do not duplicate
  arbitration logic in a caller.

## Validation

Run `dart format --output=none --set-exit-if-changed lib test`,
`flutter analyze --no-pub`, and `flutter test --no-pub` from this package.
