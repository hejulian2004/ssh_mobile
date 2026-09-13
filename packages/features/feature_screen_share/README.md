最新更新时间：2026-09-12

# feature_screen_share

This package provides the business-facing screen-share consent state machine.
It consumes typed `network_sdk` consent metadata and an injected opaque media
port. Native capture, H.264, WebRTC endpoints, GPU surfaces and textures stay
owned by the App/platform adapters.

The package is intentionally usable before a platform owner is available: a
request can remain pending, and all platform failures become a terminal typed
Feature state without a byte or native handle crossing the boundary.

## PR74 product flow

The App Shell enters this Feature from a trusted LAN peer action or the global
incoming-request host. The Feature receives typed consent metadata, pure
`ScreenShareSourceOption` metadata when source selection is needed, and an
opaque `ScreenShareMediaPort`. It does not create or claim a `RealtimeSession`;
the App Shell owns session/route lifecycle and native provisional-offer claim.

The sender sends `REQUEST` before transport `Connected`, and starts capture only
after remote `ACCEPT`, native readiness, and the current generation all match.
The receiver seeds the exact original `REQUEST` once after a successful native
claim, sends `ACCEPT` immediately, and starts viewing only after the same media
gate. `compareScreenShareIntents` is the public pure comparator used by App
arbitration; the Feature controller still owns consent construction, revisions,
freshness, and business state.
