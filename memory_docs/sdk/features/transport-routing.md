> Last updated: 2026-09-12

# Transport and Routing

`PeerSupervisor` owns mutable peer connectivity; `PeerPathManager` owns Direct/
Relay carriers. Features request typed business capabilities, never sockets,
routes, or protocol implementations. Operations borrow and release a
`PathLease`.

| Carrier | Topology | Role |
| --- | --- | --- |
| QUIC | Direct | authenticated reliable/stream carrier |
| TCP | Direct | authenticated reliable-message carrier |
| WebSocket | Direct | authenticated reliable-message carrier |
| WSS `/v2/control` | Relay | auth, heartbeat, discovery, resolve, signaling, reservation |
| WSS `/v2/relay/{id}` | Relay | reservation-scoped opaque encrypted data (`RelayDataFrame`) |
| UDP | Direct | unreliable datagrams only |
| WebRTC | Direct/ICE Relay | native Realtime Session route |

## Invariants

- Topology and transport are separate metadata. Trust/route authorization is
  separate from Discovery/Relay enrollment: Direct requires persisted
  `localDirect`; Relay requires peer relay authorization, local enrollment/config,
  remote capability, and native route availability. Relay disconnect never revokes
  trust or authorization.
- Carriers authenticate before `ConnectionSession` admission/publication. Delivery,
  Transfer, and Stream ask the path manager for a compatible lease; UDP cannot
  provide acknowledged, ordered, or file-delivery semantics.
- A ConnectionSession is 1:1 with its transport Connection: every new connection
  gets a new SessionId and Noise root, and loss destroys the session. There is no
  route migration or session/crypto-root continuity. Only business state crosses
  connections: Delivery by MessageId/channel state, Transfer by `transfer_id` +
  `confirmed_offset`; runtime restart/loss triggers new Resolve → Connection →
  ConnectionSession, while SSH/WebRTC build fresh sessions.
- `E2eePolicy::Required` creates fresh app crypto per connection.
  `E2eePolicy::Disabled` is identity-only Direct and is rejected for Relay.
- Stage A uses fresh cached/configured Direct candidates and can reuse a healthy,
  capability-compatible path without control. Stage B uses authoritative
  Resolve→Offer with a fixed four-second Direct window. Stage C reserves Relay
  only after READY, Direct failure, capability compatibility, Required E2EE, and
  budget checks. A reusable path never emits an unsolicited target-less Offer.
- Direct races key attempts by `(candidate_id, endpoint, generation)`; TCP and
  WebSocket race concurrently when supported, and late Answer candidates may join
  before the Direct deadline. Relay Data `Ready` is one-shot per pair; replacing or
  disconnecting either side closes the old pair and requires Connect → Ready again.

Implementation entry points: [Rust Connection](../../../native/network_core/crates/network-core/src/connection.rs),
[Rust Session](../../../native/network_core/crates/network-core/src/session.rs),
[peer routing](../../../native/network_core/crates/network-core/src/peer.rs),
[Dart facade](../../../packages/infrastructure/network_transport/README.md), and
[Go Relay](../../../relay/README.md).

Rationale: [path quality/migration ADR](../../../docs/adr/ADR-014-path-quality-and-migration.md),
[generic Connection](../../../docs/adr/ADR-019-generic-connection-layer.md),
[generic Session routes](../../../docs/adr/ADR-027-generic-session-routes.md),
and [forward-secret Session E2EE](../../../docs/adr/ADR-028-forward-secret-session-e2ee.md).

## Realtime screen-share signaling

WebRTC screen sharing remains a native Realtime carrier, not Relay video
forwarding. Relay Control V2 forwards the bounded signaling payload and writes
authenticated `source_device_id` only on the server-to-target direction. An
unknown incoming Offer is retained as native-only provisional state with formal
ICE bounds; matching typed REQUEST is required before Dart notification.
`ACCEPT` is a user decision and is sent immediately after claim/identity, while
Connected/native readiness is a separate media gate. Sender CANCEL, native
claim rollback, late ICE, and generation replacement must preserve exact-owner
cleanup and must not migrate candidates to a replacement session. Claiming ICE
uses a hybrid owner rule: queue until exact responder registration, then route
matching candidates only to that exact claiming generation. Provisional expiry
is native-authoritative; App timers only remove stale UI/arbitration state.
