最新更新时间：2026-09-12

# feature_lan_share 维护约束

## Boundary and ownership

- LAN Control Protocol V2 is breaking-only: no old pairing schema/storage
  migration, V1/V2 dual stack, deprecated wrapper, old file-protocol fallback,
  or legacy aliases (`AppLanguage`, `AppSettings`, `AppStrings`). A non-current
  schema clears pairing/trust and requires re-pairing. LAN Control V2 and Native
  Network V2 are separate version domains: LAN owns discovery/pairing/capabilities,
  control HTTP, and text/clipboard; Native V2 owns peer registry, sessions,
  Direct/Relay data, E2EE, file transfer, and Realtime. LAN changes never make
  native wire V2 into V3.
- Scope: LAN discovery/pairing/transfer/Receiver/Module/Repository/pages/tests;
  public API is `feature_lan_share.dart` (pure WebShare worker via
  `lan_web_share.dart`). No SSH, other Feature/App `/src/`, or copied model bridge.
  Cross-boundary capabilities use `LanShare*Port` from
  `domain/lan_share_ports.dart` (including `LanShareNetworkAccessPort`); network
  types come directly from `network_sdk` and Features consume only the
  AppRuntime-owned `NetworkFacade`.
- Never create Socket, FFI, HTTP client, native handle, runtime configuration, or
  a second transport. `BootstrapClient` and `NetworkCommandGateway` are App
  Shell-injected. The network Port only borrows `NetworkFacade`.
- `LanShareModule` owns `lan_share.db`, Repository, TrustStore, Receiver, Route
  Service, and the single Feature peer registry. Receiver owns listener/discovery/pairing/
  Feature resources and ViewModel lifecycle but never starts/stops/disposes/
  reconfigures App Facade/NetworkRuntime/native handle. `LanRelayCoordinator`
  owns endpoint observation, enrollment/refresh, Relay subscriptions and bounded
  retry timers through `LanRelay*Port` only.
- Screen sharing is a peer-scoped secondary action only. Use the public
  `LanShareScreenSharePort`; never import `feature_screen_share`, access the
  TrustStore from App Shell, or replace the existing device-tap Chat action.
  Outgoing UI calls `canShareWith`; incoming App hosts call the independent
  `canReceiveScreenShareFrom` capability.

## Protocol, trust, and transfer invariants

- Network V2 transfer events (`Progress`/`Completed`/`Failed`) require authoritative
  `peerId`; missing/mismatched IDs fail closed, never use `transferId` alone.
  App↔App binary image/video/audio/file uses Native Network V2 regular-file
  transfer; directory/multi-file and `/api/lan/upload` are rejected. Browser
  WebShare alone may use authenticated/encrypted `POST /api/web/upload`, with
  bounded cleanup, and it is never an App transfer fallback. Text/clipboard use
  authenticated LAN HTTPS + application E2E with no plaintext toggle.
- Trust, Discovery, Reachability, Route Availability, and Relay
  Enrollment/Authorization are independent. `LanPeerTrustRecord` atomically
  stores certificate fingerprint, inbound/outbound tokens, 32-byte X25519 and
  Network Identity public keys, origin, and `localDirect`/`relay` authorization.
  Local PIN defaults direct=true/relay=false; Relay enrollment never grants a
  peer relay access. Dynamic endpoints/native ports and secrets never enter the
  record or plaintext DB/log/export.
- `LanNativePeerRegistry` alone maps Trust→`registerPeer` and explicit unpair→
  `removePeer`. Offline, discovery timeout, Relay disconnect, route change, and
  deactivate only invalidate dynamic endpoints; only explicit trust revoke/unpair
  removes Trust. Receiver generations restore every valid trusted peer with
  pinned 32-byte keys and `endpointAddress=''` before advertising; malformed
  material fails closed and capabilities cannot overwrite keys.
- Post-pair endpoints authenticate/pin certificate identity; remote `localPath`
  is ignored and all receive/recall cleanup stays inside the LAN sandbox. Native
  metadata is consumed once before async body read; pending+active leases share
  capacity, body/name/size/preview are bounded, replay/reuse cannot create an
  untracked write, and failure releases the exact lease/deletes partial data/
  records failure. Desktop export uses bounded streams, never a huge memory copy.
- LAN HTTPS and native QUIC/TCP use separate ports. Native binds ephemerally and
  advertises only its confirmed port; senders never guess HTTPS. URI construction
  is structured, connections direct/certificate-pinned/no-redirect. Advertising
  restart releases the prior mDNS/UDP generation; delayed callbacks retain their
  creation socket identity. Runtime startup ensures only `NetworkCapability.runtime`,
  not QUIC; Wave 1 `ConfigureRuntime` still initializes direct QUIC/TCP, while
  QUIC-free WSS-only is deferred to Wave 2 and absent today.
- Relay settings are changed only through `LanRelaySettingsViewModel` and the
  injected Coordinator; form Token is call-local. Endpoint change closes old
  socket and clears enrollment. Retry follows server `retry_disposition`: bounded
  `retryAfter` (≤60s), silent refresh for `refreshCredentialThenRetry`/
  `credentialExpired`, terminate `noRetry`/`identityConflict`, otherwise
  exponential `1/2/4/8/16/30s` for at most six retries. Native owns one Relay
  data socket; Dart owns enrollment, secure storage, and presentation. Send uses
  final Peer state and history records actual Direct/Relay route metadata.
- Pairing invitations from device taps/QR share a short-lived navigation flow and
  never establish Trust. Pairing is reciprocal/role-independent; both PIN
  directions verify, simultaneous invitations merge, and role changes preserve
  typed input. TLS context/static X25519 creation is single-flight and cached TLS
  binds one local identity. Unpair/cache reset invalidates generation-bound
  verification; pinned HTTP has size/time bounds and closes in `finally`.
- Incoming native offers use a Coordinator-owned stable broadcast stream whose
  Facade subscription is replaced on deactivate/reactivate. Final release waits
  Discovery/WebShare then Transfer; services serialize starts/stops, close
  sockets before streams, reject late publication, and continue cleanup after
  individual failures. ViewModel drains keepalive/history migration/persistence.

## Validation and targeted acceptance

For Dart changes run package format/analyze/test; Drift input changes regenerate
`*.g.dart`. Local aggregate CI is opt-in per the canonical Skill. Contract or
security changes use failure-first tests and the following selectors (missing
tests must be added, never replaced by an empty selector):

- `lan_peer_trust_v2_test.dart` (schema reset, atomic trust, keys/Relay auth);
  `lan_native_peer_registry_v2_test.dart` (restore, empty endpoint, invalidation,
  unpair, isolated restore); `lan_pairing_protocol_v2_test.dart` (identity-bound
  transcript, atomic commit, old-protocol/timeout rejection); and
  `lan_peer_trust_identity_v2_test.dart` (cert/X25519/Network Identity conflict).
- `lan_peer_presentation_models_test.dart` (Discovery-only/trusted-offline);
  `lan_native_transfer_coordinator_v2_test.dart` (regular file, incoming
  decisions, fresh-policy Relay fallback, unspecified-route fail-closed);
  `network_incoming_transfer_host_test.dart` (approval/retry/error/double-submit).
- `lan_storage_service_test.dart` (100MiB disk buffer, unknown-space fail-closed,
  cross-filesystem stream-copy, sandbox delete); `lan_network_v2_acceptance_matrix_test.dart`
  (offline Relay, direct→Relay, blocked incoming, re-pair, neutral inbox/sandbox,
  cross-layer history); `lan_http_v2_route_test.dart` (no old upload route);
  `lan_web_share_request_handler_test.dart` (bounded drain/reject/oversize/chunked,
  encryption/cleanup, no native TLS dependency).
- `scripts/bash/contracts/check_network_v2_contract.dart` checks canonical proto,
  Rust prost, and Dart codec block parity (including `PeerTransferProgressEvent`
  tag 32 and tags 1–5). Full App `network_runtime_ownership_v2_test.dart` covers
  AppRuntime exactly-once; SDK lifecycle uses `network_facade_v2_refactor_test.dart`
  and package contracts. Bash/PowerShell `lan-network-v2-targeted` jobs select
  these Feature tests together with App/SDK adapter contracts.
