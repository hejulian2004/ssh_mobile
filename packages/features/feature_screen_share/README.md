最新更新时间：2026-09-08

# feature_screen_share

This package provides the business-facing screen-share consent state machine.
It consumes typed `network_sdk` consent metadata and an injected opaque media
port. Native capture, H.264, WebRTC endpoints, GPU surfaces and textures stay
owned by the App/platform adapters.

The package is intentionally usable before a platform owner is available: a
request can remain pending, and all platform failures become a terminal typed
Feature state without a byte or native handle crossing the boundary.
