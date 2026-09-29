> Last updated: 2026-09-23

# LAN Share Feature Memory

`packages/features/feature_lan_share/` owns LAN Control Protocol V2 discovery,
pairing, capabilities, authenticated control HTTPS/WebSocket, Web Share, Relay
enrollment/orchestration, transfer history, non-secret metadata, and
`lan_share.db`. Binary App↔App payloads use Native Network Protocol V2 Transfer;
text/clipboard use authenticated LAN HTTPS + application E2E. Browser WebShare
uses the isolated authenticated/encrypted `POST /api/web/upload` boundary only
because browsers cannot run Native Network V2; it is never an App-transfer
fallback.

`LanShareModule` owns DB, repository, Receiver, TrustStore, and the single
Feature peer registry. `LanReceiverCoordinator` owns listener/discovery/pairing-session/
ViewModel lifecycle and borrows the AppRuntime `NetworkFacade`/`NetworkRuntime`;
it never creates, starts, stops, disposes, or reconfigures the shared runtime. Its
`LanRelayCoordinator` independently owns enrollment, refresh, Relay events,
typed retry policy, and bounded timers. One receiver-owned
`LanShareViewModel` is reused by LAN and pairing/chat routes; activation is
explicit/configured, not an import or App-start side effect.

## Pairing, trust, and routes

- Device taps and QR scans share a short-lived invitation flow; invitations
  request navigation and never establish trust. Pairing is reciprocal and
  role-independent: both PIN directions verify, simultaneous invitations merge,
  and role changes preserve typed input.
- `LanPairingNavigationHost` is the sole path that opens root pairing routes.
  Pairing-stream and route-completion callbacks enter one post-frame scheduler;
  navigation inside an active pairing/chat flow remains owned by those pages.
- LAN Control V2 is breaking-only: no old schema/storage migration, V1/V2
  dual-stack, deprecated wrapper, or HTTP binary fallback. A non-current schema
  is cleared and requires pairing again. Trust, Discovery, Reachability, Route,
  and Relay Enrollment/Authorization are independent; `isTrusted`, `isOnline`,
  and Relay state are not derived from each other.
- `LanPeerTrustRecord` atomically stores certificate fingerprint, inbound/outbound
  tokens, 32-byte X25519 and Network Identity public keys, origin, and explicit
  `PeerRouteAuthorization` (`localDirect`/`relay`). Local PIN defaults to direct=true,
  relay=false; Relay enrollment never grants every peer. Dynamic endpoints and
  native ports never enter the durable record. Secrets/PINs/credentials and
  remote `localPath` never enter plaintext storage/logs/exports.
- Post-pair endpoints authenticate and pin certificate identity; receives and
  recall cleanup stay in the LAN sandbox. `LanNativePeerRegistry` is the sole
  Trust→`NetworkFacade.registerPeer` and explicit-unpair→`removePeer` owner.
  Offline, discovery timeout, Relay disconnect, route change, or Feature
  deactivation only invalidate dynamic endpoints; only explicit trust
  revoke/unpair calls `removePeer`.
- App↔App image/video/audio/file transfers are Native Network V2 regular-file
  transfers via `LanNativeTransferCoordinator`; directory/multi-file and the old
  `/api/lan/upload` route are rejected. Lifecycle events must carry authoritative
  `peerId`; missing or mismatched IDs fail closed, never use `transferId` alone.
  The final Peer state selects the route, and history records actual Direct/Relay
  metadata.

## Transfer and lifecycle invariants

- WebShare QR Automatic uses the Feature-defined local IPv4 selection Port, never
  interface enumeration order. Candidates contain address, interface name, and
  transient `NetworkInterface.index`; indexes are not persisted. An explicit
  override is valid only while present in the current eligible candidate set;
  stale overrides fail closed without falling back to Automatic.
- The App composition root injects the selector through `LanShareModule` and
  `LanReceiverCoordinator`. Windows route/interface API and FFI stay in the
  App-owned Dart adapter; every successfully returned route table is released
  exactly once with `FreeMibTable`, and native failures become Feature-local
  unavailable state. Windows groups IPv4 default-route rows by interface and
  compares route metric + interface metric; duplicate lowest routes on one
  interface are equivalent, while cross-interface ties or multiple candidates
  on the selected interface require manual selection. With no eligible route,
  only a sole candidate is a valid fallback. A route-query failure is unavailable,
  not evidence that no default route exists. Other platforms auto-select only a
  sole candidate; sorted order is for display only.
- A QR URL never advertises loopback. If address resolution fails or an override
  becomes stale, stop only the WebShare HTTPS session and clear its QR URL; keep
  the separate LAN Control listener running. Preserve all five QR fields:
  `deviceId`, `lanPort`, `nativePort`, `access`, and `certFingerprint`. WebShare
  HTTPS, LAN Control HTTPS, and native transfer ports remain distinct.

- Native/WebShare metadata is consumed once before the first async body read;
  pending+active leases share one capacity budget, replay/reuse cannot create an
  untracked write, and body/name/size/preview parsing is bounded. Failure releases
  the exact lease, deletes partial data, and records failure. Desktop export uses
  bounded streams, never a multi-gigabyte in-memory copy.
- Temporary remote verification binds to pairing generation; unpair/cache reset
  invalidates it. Pinned HTTP responses have size/time limits and close in
  `finally`. TLS context and static X25519 first creation are single-flight, and
  cached TLS is bound to one local identity.
- LAN endpoints use structured host/port URIs, certificate pinning, direct
  connections, and no redirects. Advertising restart releases the prior
  mDNS/UDP generation; delayed callbacks retain their creation socket identity.
  HTTPS and native reliable transfer listen on separate ports. Receiver binds
  native transport ephemerally and advertises only the confirmed port; senders
  never guess the HTTPS port.
- Each Receiver native-runtime generation restores every valid trusted peer
  (pinned 32-byte Network Identity/X25519 keys, `endpointAddress=''`) through one
  registry before advertising. Missing/malformed trust fails closed; capabilities
  may verify but not overwrite keys. Pair success syncs the live registry even
  when the LAN page is closed; explicit unpair deletes Trust and calls
  `removePeer`, route loss does not.
- Incoming native offers use a Coordinator-owned stable broadcast stream whose
  internal Facade subscription is replaced across deactivate/reactivate. Paired
  text, clipboard, and file sends have no plaintext toggle; missing E2E fails.
- Final Receiver release awaits Discovery/WebShare, then Transfer. Each service
  serializes starts/stops, closes sockets/servers before streams, rejects late
  publication, and continues cleanup after individual failures. ViewModel close
  drains keep-alive, history migration, and persistence work.
- Direct is preferred; Relay is fallback only when peer Relay authorization,
  local enrollment/configuration, remote capability, and native route checks
  pass. There is no Relay-only peer creation flow. Receiver startup ensures only
  `NetworkCapability.runtime`; QUIC is not an implicit command-gateway
  prerequisite. Wave 1 `ConfigureRuntime` still initializes direct QUIC/TCP;
  QUIC-free WSS-only is deferred to Wave 2 and does not exist today.

Current implementation checkpoints: AppRuntimeFactory/AppRuntime loads identity and configures one
shared Facade before LAN activation; V2 pairing binds both static identities and
writes one complete record; LanShareModule owns the DB, Repository, Receiver,
TrustStore, and single Feature peer registry; the registry handles restore/invalidation/route
authorization and explicit unpair; HTTP binary upload is removed; regular-file
transfer is Coordinator-owned; ViewModel delegates file send/unpair to the
Coordinator/registry while retaining text/clipboard/history; text/clipboard
remain the stable authenticated HTTPS + application-E2E path. Current
App/Feature/SDK/native tests cover
exact-once AppRuntime, dual-runtime/device-restart transfer, V2 pairing/storage,
and explicit peer removal.

Typed network contracts/native events/route migration/wire/E2EE belong to the
[SDK domain](../../sdk/overview.md); Relay server auth/deployment belongs to the
[Backend domain](../../backend/overview.md). Contracts: [LAN README](../../../packages/features/feature_lan_share/README.md)
and [LAN AGENTS](../../../packages/features/feature_lan_share/AGENTS.md).
