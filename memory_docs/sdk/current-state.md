> Last updated: 2026-09-12

# SDK Current State

Native transport/Relay implements Network Protocol V2; Relay bootstrap is V2
(`POST /v2/devices/enroll`, `POST /v2/devices/refresh`, `protocol_version=2`).
LAN Control V2 is a separate breaking-only domain: pairing/discovery/capabilities
and authenticated text/clipboard HTTPS stay in LAN Share; peer registration,
sessions, route authorization, E2EE, and binary transfer stay in Native Network
V2. App Scope owns one Ed25519/X25519 identity bundle, one configured runtime,
and one Facade; Feature lifecycle cannot reconfigure them.

## Current contracts and runtime

- `network_sdk` exposes typed bootstrap/API/Session/event/Feature-safe Realtime
  contracts; the typed `network_v2` contract keeps PeerState, E2EE policy,
  terminal results, diagnostics, environment changes, and peer business IDs
  separate from the legacy wire adapter. `RefreshRequest` requires integer Unix
  seconds and the exact signed
  `POST\n/v2/devices/refresh\n<timestamp>\n<nonce>` transcript; V1 has no fallback
  ([ADR-031](../../docs/adr/ADR-031-relay-refresh-proof-freshness.md)). Rust
  Relay Control/Data upgrades likewise each use a positive timestamp, 32-byte
  nonce, and `X-Relay-Timestamp` plus exact
  `GET\n<path>\n<timestamp>\n<nonce>` signature with no trailing
  newline; timestamp-less builders are retired.
- `network_transport` provides one App runtime and borrowed command/Realtime
  gateways. `ssh_mobile_network_native` polls events on a helper isolate and
  maps typed Protobuf commands/events through separate stateless encoders,
  envelope/domain mappers, and FFI validation.
- Rust owns authenticated QUIC, generic TCP/WebSocket, UDP datagrams, WSS Relay,
  WebRTC, `PeerSupervisor`, `PeerPathManager`, Delivery/Recovery, E2EE, and
  resumable transfer. `ConnectionSessionStore` is admission/security-only;
  operations select carriers through `PathLease`.
- One ConnectionSession belongs to one transport Connection. New connection →
  new SessionId + Noise root; loss destroys it. Delivery/Transfer resume only
  business state by ID. Discovery keeps full 128-bit `runtime_epoch`; revisions
  order only within that epoch and late Answer candidates may join a live race.
- ReliableStream uses `StreamHandle(opener_device_id, stream_id)` end-to-end;
  framing/preamble/token codec, stream manager (registry/sequence/bounded buffer/
  tombstones/one lease), and SSH gateway/FFI byte pump are separate owners. The
  gateway does not interpret SSH protocol. Queue acceptance, native completion,
  transport ACK, and application ACK are distinct.
- Native results use a bounded Result lane with async worker backpressure ahead
  of Control/Data; only a rolling completed-command window is retained. Dart
  drops duplicate/unknown terminal results, coalesces peer connect intents, and
  rejects stale generations. Handles are leased and revoked handles cannot be
  reacquired. Event ingress is count+byte bounded with Result/Control/Data
  fairness and overflow policy before Feature adapters.

## Routing, recovery, and security

- Passive authenticated inbound makes a peer Online but does not enable
  maintenance. Environment changes refresh discovery while preserving healthy
  Relay/Realtime; maintained peers schedule Direct recovery only after Relay is
  ready, with `1/2/4/8/15/30s` backoff+jitter. Unleased idle paths retire after
  60s. Direct and Relay may coexist; compatible Direct wins, `ensure` does not
  enable maintenance, and hard revocation closes streams bound to the lease;
  normal retirement drains leases rather than migrating them.
- `CandidatePayloadV2` validates transport capabilities; Relay candidates never
  enter DirectProbe. Cache freshness uses a monotonic clock, server TTL,
  `runtime_epoch`/same-epoch revision ordering, and fingerprint consistency.
  `RuntimeState` owns the per-peer resolved cache. Reuse a healthy path without a
  target-less Offer; new/replacement paths use authoritative Resolve→Offer.
  Session teardown leaves bounded StreamHandle tombstones so old handles cannot
  write into a new session.
- Required E2EE creates a fresh application root after authenticated
  Noise/path admission; Disabled is Direct identity-only and Relay rejects it.
  Direct eligibility requires peer local-direct authorization; Relay requires
  peer relay authorization plus local/remote enrollment and capability. Relay
  enrollment/disconnect never mutates trust; Dart `removePeer` is explicit
  trust revoke/unpair only.
- Connectivity is ordered: Stage A uses fresh configured/cache Direct candidates
  and may reuse a healthy compatible path; Stage B performs one Resolve→Offer
  with a fixed four-second Direct window; Stage C reserves Relay only when
  Resolve READY, Direct failed, capabilities match, Required E2EE is active, and
  budget remains. Snapshot decoding/cache projection/ranking are separate from
  coordinator execution. Accept/handshake tasks are runtime-scoped; readers are
  Session-scoped and retire only the lost route before finishing a Session.
- Result/Control/Data lanes are owned independently of RuntimeState. Result
  backpressures command workers and is never drop-on-full; weak path projections
  separately own Session bindings/topology replacement/stale cleanup without
  extending carriers or replacing admission storage. Feature Realtime exposes
  no native signaling/media resources; public package contract defines decoded
  media availability. Generic reliable carriers carry Delivery frames; SSH and
  Realtime close explicitly rather than transparently migrating stale sessions.

## Validation ownership

Run package-local checks from each SDK `README.md`/`AGENTS.md`. The public SDK
coverage gate is independent:

```bash
bash scripts/bash/coverage/sdk_coverage.sh
```

Public Dart packages and the public Rust SDK aggregate require 90% line
coverage; internal `network-core`/Relay coverage remains in ordinary workspace
checks. Cross-owner parity uses:

```bash
bash scripts/bash/contracts/network_v2_acceptance.sh strict
```

Do not copy test-run results here; device-dependent evidence belongs in the
[network fault matrix](../../docs/NETWORK_FAULT_MATRIX.md).

LAN V2 implementation currently has typed `removePeer`, `allowDirect/allowRelay`,
App identity wiring, atomic V2 pairing, discovery-only presentation models,
peer registry, regular-file transfer coordinator, and explicit unpair. V1
pairing/trust helpers, the legacy aggregate model, and HTTP binary route are
removed; metadata rejects binary. AppRuntime exactly-once and dual-runtime/
device-restart acceptance are covered by current App/Feature/SDK/native tests.
`NetworkFacade.sendMessage` remains the stable unavailable boundary; text/
clipboard use authenticated HTTPS + application E2E.

## Realtime screen-share control plane

Relay V2 `RealtimeSignal.source_device_id = 7` is additive and directional:
client values must be empty, Relay writes authenticated sender identity, and
unknown-session signals without source fail closed while established bindings
remain compatible with old Relay. Native retains Offer, bounded provisional ICE
(128 / 8 KiB / 256 KiB / 120 s), and matched typed REQUEST in
`pending → claiming → claimed/terminal` state. A native expiry worker uses a
provisional epoch, one shared 32-operation budget, and a five-minute bounded
per-peer consent replay cache; REQUEST is revision 1 and same-author CANCEL is
revision 2. No Dart session, Answer, or media endpoint exists before explicit
Accept. SDK claim pre-registers the responder, normalized snapshots expose
Negotiating identity without waiting for Connected, and `releaseSession` keeps
the exact registry entry until authoritative stopped/failed.
