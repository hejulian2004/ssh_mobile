> Last updated: 2026-09-12

# SDK Overview

The SDK domain owns the versioned network contract and native runtime:

- `packages/infrastructure/network_sdk/`: Feature-facing Dart contracts;
- `packages/infrastructure/network_transport/`: App-scoped runtime facade;
- `packages/infrastructure/ssh_mobile_network_native/`: Dart FFI/native assets;
- `native/network_core/`: Rust peer/path ownership, authenticated transports,
  Delivery/Transfer, crypto, NAT, Relay, WebRTC, and FFI implementation;
- `protocol/`: versioned wire schema.

`ssh_core` remains Client infrastructure. Go Relay is Backend, but wire, route,
and E2EE changes normally span SDK + Backend.

Canonical design references: [Network SDK design](../../docs/网络传输SDK架构设计_最终版.md),
[implementation plan](../../docs/NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md),
[fault matrix](../../docs/NETWORK_FAULT_MATRIX.md), and
[Transport and Routing](features/transport-routing.md).

PR74 also changes the SDK Realtime lifecycle boundary: incoming offers are
metadata-only and use a provisional backend for claim/reject/discard; the SDK
registers the responder session before native claim and removes only the exact
registered object on rollback. `RealtimeSession.currentSnapshot` and
`snapshots` are normalized state/full-snapshot projections, not a raw native
full-snapshot stream.
