> Last updated: 2026-09-12

# Relay Protocol V2 — Frozen Wire Contract

## 1. Status

FROZEN (Step 2 / M1). This document and the files it points to are the lockstep
authority for the transport-network v2 relay control plane and relay data
plane. Downstream workstreams code against this contract and its golden
fixtures:

- WS-A — Go control plane (`/v2/control`, reservations)
- WS-B — network-nat ConnectivityAttempt (offer/answer candidate shapes)
- WS-C — network-relay split (RelayControlClient / RelayDataClient)
- Phase 4 — network-core (DiscoveryManager, ConnectivityAttemptCoordinator, RealtimeManager)

Device bootstrap and credential issuance are specified separately in
`protocol/RELAY_BOOTSTRAP_V2_CONTRACT.md` (`/v2/devices/enroll` and `/v2/devices/refresh`).
The retired Network SDK/Data Protocol V1 package and codec are not a
compatibility target for this contract.

Authoritative files:

- Wire schema: `protocol/proto/relay/v2/relay_v2.proto` (package `relay.v2`)
- Golden fixtures + manifest: `protocol/relay_v2_testdata/`
- Contract gate: `scripts/bash/contracts/relay_v2_contract.sh`

## 2. Frame envelope (both routes)

`WS Binary payload == [u32 big-endian length][protobuf bytes]`

- Exactly ONE message per WS frame. `length` MUST equal `frame.len() - 4`
  (violation → close with `ProtocolError MALFORMED_FRAME`; on `/v2/relay` →
  `RelayDataClose reason 2`).
- `/v2/control` frames decode to `relay.v2.RelayFrame`; `/v2/relay` frames
  decode to `relay.v2.RelayDataFrame`. Offering the wrong envelope type on a route is a protocol violation → close.
- `RelayFrame.version` / `RelayDataFrame.version` MUST be 2 (else `ProtocolError
  PROTOCOL`). Unknown oneof tags are SKIPPED (proto3) for forward compatibility;
  length/size/version violations are HARD errors.

## 3. Route semantics

### GET /v2/control (WSS, long-lived)

- Auth at upgrade (same mechanism as v1), then server sends `Ready` first.
- Carries ONLY: `Heartbeat`/`HeartbeatAck`, `DiscoveryPublish`/`DiscoveryAck`,
  `ResolvePeerRequest`/`ResolvePeerResponse`, `ConnectivityOffer`/`ConnectivityAnswer`,
  `PresenceHintSnapshot`/`PeerAvailableHint`/`PeerUnavailableHint`,
  `RelayReserveRequest`/`RelayReserveResponse`/`IncomingRelayReservation`,
  `RealtimeSignal`, `ProtocolError`.
- FORBIDDEN: `RelayDataFrame`, file chunks, delivery/bulk payloads.
- Heartbeat is SERVER-ENFORCED: server keeps a 20 s timer; 2 missed heartbeats
  → close + release presence lease. `Ready` carries `heartbeat_interval_s=20`
  and `presence_ttl_s=60` so a misconfigured server is visible to the client.
- On control reconnect (same `runtime_epoch`), the client re-publishes the FULL
  snapshot at the CURRENT revision (server CAS accepts because the owning
  control connection changed).

### GET /v2/relay/{reservation_id} (WSS, reservation-scoped)

- Token validated at upgrade AND optionally re-confirmed by the first
  `RelayDataConnect` (must match path segment + token).
- Carries ONLY: `RelayDataConnect` (first), `RelayDataPayload` (encrypted
  forwarding), `RelayDataAck` (flow control), and `RelayDataClose`.
- Relay enforces per-connection byte/rate budgets, frame size, reservation
  expiry (close when now > expires_at + 5 s grace). Relay NEVER parses
  `encrypted_payload`; it is a stateless opaque forwarder.
- Lifecycle: A `RelayReserveRequest` → server stores reservation (TTL=expires_at)
  → `RelayReserveResponse` to A + `IncomingRelayReservation` to B → both connect
  `/v2/relay/{id}` with role-specific tokens → Relay sends one WebSocket Ping
  carrying `ssh-mobile-relay-paired-v1:<reservation_id>` to both endpoints →
  encrypted payload flows → `RelayDataClose` or explicit revocation. PairReady
  is a WebSocket control frame, not a protobuf message.
- `RelayDataConnect` authenticates the initiator/responder role from its token;
  same-role retries replace an unpaired endpoint. Once a pair has completed
  PairReady, replacing either role invalidates the whole old pair: Relay closes
  both old endpoints with `RelayDataClose(reason=2)`, creates a fresh pending
  pair, and never sends a second PairReady to the endpoint that remained
  connected. Both roles must complete a new `Connect → PairReady` sequence
  before payload or ack traffic resumes.
- `RelayDataPayload` and `RelayDataAck` are rejected until the two roles are
  paired and the PairReady WebSocket Ping has been sent. PairReady is one-shot
  for one paired data connection; a client must wait for that Ping before
  treating the data plane as connected. A 30 s server Ping / 15 s Pong timeout
  uses the same single writer as binary frames.
- There is no `RelayDataReady` protobuf message and no `ready` oneof field in
  the frozen `RelayDataFrame`.
- The reservation TTL governs pending admission only. Once PairReady has been
  established, active data lifetime is independent of reservation TTL and
  natural credential expiry. Explicit device revocation closes pending and
  active endpoints, including the active counterpart.

## 4. Message inventory

### Common

| Message | Purpose |
|---|---|
| `RuntimeEpoch` | 128-bit runtime identity; two `fixed64` `{high, low}` (big-endian) so Go/Rust/vectors agree byte-stably |
| `CandidateBundle` | `repeated bytes candidates` — opaque native candidate blobs; relay never parses |
| `DiscoverySnapshot` | `runtime_epoch`, `revision` (monotonic within epoch), `transport_capabilities`, `candidate_bundle`, `published_at_ms` |

### Control (`RelayFrame` oneof tags 10–26; reserved 30–63)

| Tag | Message | Notes |
|---|---|---|
| 10 | `Ready` | `protocol_version=2`, device_id, server_time_ms, heartbeat/ttl |
| 11 | `Heartbeat` | `request_id`, `sent_at_ms` |
| 12 | `HeartbeatAck` | echoes `request_id`, `server_time_ms` |
| 13 | `DiscoveryPublish` | `request_id`, snapshot |
| 14 | `DiscoveryAck` | echoes `request_id`, epoch, revision |
| 15 | `ResolvePeerRequest` | `request_id`, `target_device_id` |
| 16 | `ResolvePeerResponse` | 4-state `status` (no fail-open `online=true`); discovery iff READY; `retry_after_ms` hint (NOT_READY 2000 / UNKNOWN 5000) |
| 17 | `ConnectivityOffer` | `attempt_id`-keyed; target is the preceding successful Resolve on the shared control connection; initiator epoch/revision/snapshot |
| 18 | `ConnectivityAnswer` | echoes `attempt_id`; accepted; responder epoch/revision/snapshot |
| 19 | `PresenceHintSnapshot` | `repeated PeerPresenceHint` — advisory, UI cache only |
| 20 | `PeerAvailableHint` | device online/updated |
| 21 | `PeerUnavailableHint` | device offline + reason |
| 22 | `RelayReserveRequest` | `attempt_id`, target, desired lifetime (server clamps [15, 120]) |
| 23 | `RelayReserveResponse` | reservation_id (16-byte hex / 32 chars), self-contained endpoint, expires_at_ms, 32-byte local_token |
| 24 | `IncomingRelayReservation` | pushed to B; receiver-specific token |
| 25 | `RealtimeSignal` | `realtime_id`, target, kind, revision, payload ≤ 256 KiB, additive tag 7 `source_device_id` written only by Relay |
| 26 | `ProtocolError` | echoes failing `request_id` (0 = server-initiated), `attempt_id`, `code`, `message` |

### Relay data (`RelayDataFrame` oneof tags 10–13; reserved 14, 30–63)

| Tag | Message | Notes |
|---|---|---|
| 10 | `RelayDataConnect` | reservation_id must equal path segment; local_token must match |
| 11 | `RelayDataPayload` | `sequence` (monotonic per direction), `encrypted_payload` opaque |
| 12 | `RelayDataAck` | echoes `sequence` (receipt/flow control) |
| 13 | `RelayDataClose` | `reason` 0 normal / 1 expiry / 2 error |

### Enums (value numbers are the frozen part; names carry the Network Protocol
enum-name prefix so value identifiers stay unique within the package)

| Enum | Values |
|---|---|
| `TransportCapability` | UNSPECIFIED=0, QUIC=1, TCP=2, UDP_DATAGRAM=3, WEBSOCKET=4, WEBRTC=5, RELAY_DATA=6 |
| `ResolveStatus` | UNSPECIFIED=0, READY=1, OFFLINE=2, NOT_READY=3, UNKNOWN=4 |
| `RealtimeSignalKind` | UNSPECIFIED=0, OFFER=1, ANSWER=2, ICE_CANDIDATE=3, ICE_RESTART=4, CLOSE=5 (mirrors Network Protocol V2 values 1..5) |
| `ErrorCode` | UNSPECIFIED=0, CONTROL_UNAVAILABLE=1, AUTHENTICATION_FAILED=2, PEER_OFFLINE=3, PEER_NOT_READY=4, RESOLVE_TIMEOUT=5, PROTOCOL=6, EPOCH_CONFLICT=7, REVISION_STALE=8, RESERVATION_FAILED=9, RESERVATION_EXPIRED=10, RELAY_UNAVAILABLE=11, RATE_LIMITED=12, MALFORMED_FRAME=13, FRAME_TOO_LARGE=14 |

## 5. Correlation & error model

- Every request carries `request_id` (uint64, client-generated, unique per control
  connection). Every async attempt carries `attempt_id` (string ≤ 128 bytes).
- Responses echo `request_id` (HeartbeatAck, DiscoveryAck, ResolvePeerResponse,
  RelayReserveResponse, ProtocolError). Async attempts correlate by `attempt_id`;
  stale/mismatched answers are dropped. No global Notify.
- `RealtimeSignal.target_device_id` is the device that should receive the frame.
  `source_device_id` is directional: clients MUST omit it when sending to the
  Relay; a non-empty client value is a protocol violation. The Relay writes the
  authenticated `sender.deviceID` before forwarding. Receivers trust only this
  Relay-authenticated value. An absent source remains compatible for existing
  bound sessions; an unknown session without an authenticated source fails
  closed, while a present source that does not match the bound peer also fails
  closed.
- Compatibility matrix for tag 7 is deliberately directional: client omission
  is accepted by old and new Relay; a non-empty client `source_device_id` is a
  protocol violation and is rejected; Relay-forwarded source is authoritative;
  old clients ignore the additive field; existing bound sessions continue to
  use their established `realtime_id → peer_id` binding when source is absent.
- Descriptor compatibility is checked structurally, not by deleting text or
  comparing the whole descriptor byte-for-byte: the shared Go helper parses
  `FileDescriptorSet`, verifies `relay.v2.RealtimeSignal.source_device_id` is
  singular string tag 7, removes only that field from the current descriptor,
  deterministically serializes both sets, and compares the result with the
  frozen descriptor. Bash and PowerShell invoke that same helper.
- `ConnectivityOffer` has no target field. It is accepted only after a
  successful `ResolvePeerRequest`/READY response on the same control
  connection; the server forwards it through that Resolve → Offer gate. The
  gate does not hold a lock across the later answer or direct-probe work.
- Error mapping: OFFLINE/NOT_READY/UNKNOWN → `ResolvePeerResponse.status`;
  unknown backend failure → `ProtocolError CONTROL_UNAVAILABLE`; discovery CAS
  conflict → `EPOCH_CONFLICT`; reservation failure/expiry → `RESERVATION_FAILED`/
  `RESERVATION_EXPIRED`; peer refusal → `PEER_OFFLINE`/`PEER_NOT_READY`.
  No generic RelayError/IoError fallthrough on the wire.

## 6. Centralized constants (no magic numbers)

```
RELAY_V2_VERSION                      = 2
FRAME_LENGTH_PREFIX_BYTES             = 4
MAX_RELAY_FRAME_BYTES                 = 4 + 512 * 1024
MAX_RELAY_DATA_FRAME_BYTES            = 4 + 512 * 1024
MAX_DEVICE_ID_BYTES                   = 128
MAX_ATTEMPT_ID_BYTES                  = 128
MAX_REALTIME_ID_BYTES                 = 128
MAX_REALTIME_SIGNAL_PAYLOAD_BYTES     = 256 * 1024
MAX_DISCOVERY_CANDIDATES              = 64
MAX_DISCOVERY_CANDIDATE_BYTES         = 4096
MAX_DISCOVERY_CAPABILITIES            = 64
RESERVATION_ID_BYTES                  = 16   (32 hex chars)
RESERVATION_TOKEN_BYTES               = 32
HEARTBEAT_INTERVAL_S                  = 20
PRESENCE_TTL_S                        = 60
SERVER_HEARTBEAT_MISSES_BEFORE_CLOSE  = 2    (60s TTL / 20s)
RESERVATION_LIFETIME_S_DEFAULT        = 60   (server clamps [15, 120])
RESERVATION_EXPIRY_GRACE_S            = 5
RESOLVE_RETRY_HINT_NOT_READY_MS       = 2000
RESOLVE_RETRY_HINT_UNKNOWN_MS         = 5000
DIRECT_CONNECT_WINDOW_MS              = 4000  (fixed; not carried on the wire)
```

These live in the `.proto` header comment, `manifest.json.constants`, and must
be mirrored in the Rust and Go codecs with a test asserting they match.

## 7. Golden fixtures

Location: `protocol/relay_v2_testdata/`

- 23 full-wire-frame `.bin` files (each = 4-byte BE length + protobuf) named
  `<message>.control.bin` / `<message>.data.bin`.
- `manifest.json` — shared semantic expectations (schema_version 2): constants,
  seed values, enum maps, and per-fixture `expects` (epoch hex, revision,
  request_id, status, reservation fields, token hex, sequence).
- `session_sequence.golden.json` — ordered full lifecycle:
  ready → heartbeat/ack → discovery_publish/ack → resolve_ready →
  connectivity_offer/answer → reserve/incoming → relay_data_connect →
  relay_data_payload ×2 → close. PairReady is a WebSocket Ping and therefore
  has no golden protobuf fixture.

Deterministic seed values:

```
epoch_high = 0x6a09e667   epoch_low = 0xbb67ae85
responder_epoch_high = 0x9e3779b9   responder_epoch_low = 0x7f4a7c15
revision = 7             responder_revision = 3
request_id = 1001        responder_request_id = 2002
attempt_id = a1b2c3d4e5f60718293a4b5c6d7e8f90  (32 hex)
reservation_id = 9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d  (32 hex)
device_a = 11111111111111111111111111111111  device_b = 22222222222222222222222222222222
```

### Regeneration

The fixtures are produced deterministically by
`protocol/relay_v2_testdata/generate_fixtures.py` (minimal protobuf wire
encoding, no external deps). Regenerate with
`python3 protocol/relay_v2_testdata/generate_fixtures.py --regenerate`, or run
`scripts/bash/contracts/relay_v2_contract.sh`, which checks the committed files without
mutating the worktree.

Cross-language tests (WS-P-R Rust, WS-P-G Go): decode each fixture → assert the
`expects` in `manifest.json` → re-encode → assert byte-identical. Framing
negatives (bad length, length ≠ frame-4, frame > max, version ≠ 2, unknown
oneof tag tolerated) are asserted in both codec suites.

## 8. v1 → v2 mapping (summary)

| v1 (JSON `type` / frame) | v2 message | v2 transport |
|---|---|---|
| `ready` | `Ready` | /v2/control |
| `heartbeat` / `heartbeat_ack` | `Heartbeat` / `HeartbeatAck` | /v2/control |
| `discovery_update` | `DiscoveryPublish` (+ new `DiscoveryAck`) | /v2/control |
| `lookup` / `lookup_response` | `ResolvePeerRequest` / `ResolvePeerResponse` (4-state) | /v2/control |
| `presence_snapshot` | `PresenceHintSnapshot` (advisory) | /v2/control |
| `peer_online` / `peer_updated` | `PeerAvailableHint` | /v2/control |
| `peer_offline` | `PeerUnavailableHint` | /v2/control |
| `candidate_offer` / `candidate_answer` | `ConnectivityOffer` / `ConnectivityAnswer` | /v2/control |
| `webrtc_offer` / `webrtc_answer` / `webrtc_ice_candidate` / `webrtc_ice_restart` / `webrtc_close` | `RealtimeSignal` (OFFER/ANSWER/ICE_CANDIDATE/ICE_RESTART/CLOSE) | /v2/control |
| (none) | `RelayReserveRequest` / `RelayReserveResponse` / `IncomingRelayReservation` | /v2/control |
| JSON error strings | `ProtocolError` | /v2/control |
| `channel_message`/`channel_ack`, `crypto_handshake`, file-transfer frames | REMOVED from control → inside the encrypted ConnectionSession payload | /v2/relay (opaque) |
| `0x10` binary (`0x10`+session16+seq8+cipher) | `RelayDataPayload` (`sequence` replaces seq8) | /v2/relay |

Discovery identity: v1 `generation` (uint64) → v2 `RuntimeEpoch` + `revision`.
`revision` strictly increases within an epoch; cross-epoch revisions are
incomparable. `EPOCH_CONFLICT`/`REVISION_STALE` replace the old generation-CAS
rejections. This is the deliberate wire break coordinated across Rust+Go.
