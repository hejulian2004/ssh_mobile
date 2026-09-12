> Last updated: 2026-09-12

# SDK Architecture

Maintained flow:

```text
Feature → network_sdk contract → App Shell adapter → network_transport
       → ssh_mobile_network_native → Rust network_core
```

Ownership and boundaries:

- `network_sdk` exposes typed business contracts and owns no socket, native
  handle, HTTP client, DB, isolate, or App lifecycle. App adapters correlate
  public operations/events and hide SDP, ICE, sockets, and FFI handles.
- LAN Control V2 is a separate breaking-only version domain for discovery,
  pairing, capabilities, and authenticated text/clipboard HTTPS. Native Network
  V2 owns peer registry, sessions, Direct/Relay, E2EE, binary transfer, and
  Realtime; LAN changes must not turn native wire V2 into V3.
- App root owns one Ed25519/X25519 `NetworkIdentityBundle`, one configured
  `NetworkRuntime`, and one shared `NetworkFacade` per process. Features borrow
  contracts and release subscriptions/leases; `registerPeer` is separate from
  connect and `removePeer` means explicit trust revoke/unpair, not route loss.
- `network_transport` owns the App-scoped native facade and lends bounded
  gateways. Diagnostics may project a confirmed bound port but never transfer a
  handle/listener/socket. The native package owns helper-isolate and explicit
  `start → stop → destroy`; its static facade delegates encoding, envelope/event
  mapping, typed domain mapping, and bounded FFI validation to stateless owners.
- Rust owns `PeerSupervisor`, `PeerPathManager` Direct/Relay carriers,
  transport-scoped ConnectionSession security, Delivery/Transfer, full-epoch
  connectivity attempts/candidate races, streams, crypto, transfer, Realtime,
  and supervised tasks. Relay is an authenticated opaque forwarder, not a
  ConnectionSession or crypto owner. Business code borrows `PathLease`; the
  `ConnectionSessionStore` is admission/security only.
- Connectivity execution owns bounded Stage A→B→C effects; candidate cache/
  ranking is separate from authoritative Resolve/Relay eligibility, so a
  configured endpoint cannot bypass status, E2EE, capability, or budget.
- ReliableStream codec/preamble/token is stateless; its manager owns registry,
  sequence, bounded buffers, tombstones, and one lease. SSH gateway/FFI only
  maps commands and pumps opaque bytes to local sshd. Runtime accept/handshake
  tasks never own Session receivers; Session receivers detect precise route loss
  and schedule root cleanup only after the final physical path disappears.
- Result/Control/Data event lanes independently own classification, count/byte
  admission, per-event limits, and weighted fairness. Result backpressures the
  command worker; Control/Data retain best-effort overflow. A separate weak path
  projection store owns Session bindings/topology replacement/stale cleanup;
  `PeerPathManager` remains carrier owner and `ConnectionSessionStore` remains
  admission owner.
- Each transport Connection owns exactly one ConnectionSession. A new connection
  gets a new `SessionId` and Noise/application root; loss destroys it. Delivery
  and Transfer own business state that can resume on a fresh session. Required
  E2EE is normal; Disabled is Direct identity-only and rejected for Relay.
- Route eligibility is authorization-filtered: Direct requires peer
  `localDirect`; Relay requires peer `relay` plus local/remote enrollment and
  capability. Relay enrollment/disconnect never changes trust. One Direct and
  one Relay ready path may coexist; `PathHandle`/projection is weak and
  `PathLease` is the only business lifetime reservation. Delivery releases its
  per-send lease before ACK wait; Transfer retains one per attempt; streams keep
  one through open/close without migration.
- Passive inbound is Online-only and does not enable maintenance. Environment
  changes preserve healthy Relay/Realtime and schedule maintained-peer Direct
  recovery only after Relay readiness. Native/FFI/Dart ingress is bounded at
  Result `256/4 MiB`, Control `256/4 MiB`, Data `128/8 MiB`, `1 MiB` per event;
  dequeue fairness is `8 Result → 8 Control → 1 Data` and Result saturation
  backpressures command completion instead of dropping it.

Full rationale: [Network design](../../docs/网络传输SDK架构设计_最终版.md) and
the precise [ADRs](../../docs/adr/).

## PR74 Realtime binding

The SDK/App adapter boundary is intentionally asymmetric. Native owns raw SDP,
ICE, pending-offer handles, PeerConnection, and provisional binding; Dart sees
only `RealtimeIncomingSessionOffer` metadata and an opaque token. The adapter
implements `RealtimeIncomingSessionBackend`; `claimIncomingSession` creates and
registers the exact `_RealtimeSession` before sending the native claim command.
Every accepted state event and full snapshot is folded into the session's
normalized `currentSnapshot`/`snapshots` projection, allowing App code to wait
for Negotiating + generation + shared-session identity without the old
start/Connected consent deadlock.
