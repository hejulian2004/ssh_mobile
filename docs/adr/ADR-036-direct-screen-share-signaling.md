最新更新时间：2026-10-12

# ADR-036：直连屏幕共享信令

## Status

Accepted for paired Direct screen sharing. This supplements the Relay-only
signaling restriction in ADR-020/034; ADR-035 consent and provisional claim
semantics remain mandatory. The product requirement is that authenticated
Direct peers can share screens without configuring Relay.

## Decision

Native Realtime first borrows an authorized, ready Direct reliable-message
PathLease. Signaling uses a dedicated bounded frame, encrypted with the current
ConnectionSession application root. Source identity comes from authenticated
admission and must match the decrypted author; target is the local identity.
The remote Session binding and current local Session are checked around decode.
Nonce replay, wrong author/target, stale binding and unauthenticated input fail
closed. No signal is retried or replayed across a replacement connection.

When no Direct carrier is available, existing Relay Control signaling remains
available. Direct signaling never uses Relay Data, Delivery, Transfer, or Dart
media bytes. It does not create another socket owner or Realtime runtime.

The App prepares the native carrier through LAN's existing identity-pinned
capability and native peer-policy owner before starting Realtime. Discovery
metadata is never identity authority; simulator port mapping is used only after
certificate and paired public keys validate. Preparing a carrier sends no file.

Offer plus typed REQUEST still creates provisional metadata only. Explicit
Accept precedes Answer; capture requires acceptance plus current native media
readiness. All ADR-035 action authors, replay bounds, expiry and exact-generation
cleanup apply equally to both signaling carriers.

For wildcard UDP binds, Realtime publishes one concrete interface candidate.
The native I/O receive context uses that advertised address while preserving the
actual bound address separately. A temporary connected UDP socket performs OS
route selection without sending a packet. Candidate discovery and selection
remain bounded and native-owned.

## Wire and compatibility

The direct-only framing contract is [DIRECT_REALTIME_SIGNAL_V2](../../protocol/DIRECT_REALTIME_SIGNAL_V2.md).
Existing Network/Relay V2 protobuf schemas, enums and generated descriptors are
unchanged. Both Direct endpoints must run a version supporting frame kind 6;
old endpoints reject an unknown frame instead of downgrading authentication.
Media remains native WebRTC DTLS-SRTP; Relay still forwards only signaling.

## Validation

Independent tests require real authenticated QUIC and TCP runtimes with no
Relay, Offer/REQUEST notification, explicit claim/ACCEPT, and ICE/DTLS Connected.
Security tests reject forgery, replay, wrong recipients and stale bindings.
Wildcard-bind tests cover concrete candidate selection and I/O identity.
Actual Windows/Android capture/render remains separate device acceptance.
