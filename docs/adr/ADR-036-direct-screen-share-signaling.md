最新更新时间：2026-10-14

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

The native Realtime generation retains its Direct signaling PathLease until
terminal session removal. Sends borrow that same carrier; they cannot migrate
to a replacement connection. This prevents an active video operation from being
retired as an unleased idle path. Normal session stop releases the reservation;
hard close, authorization revoke, and connection loss still invalidate it.
Both QUIC endpoint roles use transport keep-alives while application metadata
is quiet, because video uses a separate WebRTC socket. The finite transport idle
timeout and the peer owner's retirement of unused paths remain in force.

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
route selection without sending a packet. The target is the current authenticated
Direct carrier's remote IP (QUIC or TCP), with configured peer endpoint and default
route as fallbacks. This selects the hotspot interface rather than an unrelated
Internet/VPN interface, including on passive receivers without a configured endpoint.
Candidate discovery and selection
remain bounded and native-owned.

While explicit acceptance is pending, the native I/O driver's fallback wakeup
only pumps queued state. It calls the RTC timeout handler only for a deadline
returned by RTC; an unanswered offer must not fail on the idle wakeup.
SDP Answer application remains `Negotiating`; only the native ICE/DTLS peer
connection event publishes `Connected`. Each native UDP owner requests a
bounded 2 MiB receive buffer so a fragmented screen keyframe can survive the
default small Windows socket buffer while SRTP is processed. Outbound datagrams
are paced in bounded bursts of four with a 1 ms pause between bursts; enlarging
our socket alone cannot prevent overflow in an emulator or NAT hop's queue.

## Wire and compatibility

The direct-only framing contract is [DIRECT_REALTIME_SIGNAL_V2](../../protocol/DIRECT_REALTIME_SIGNAL_V2.md).
Relay V2 signaling remains unchanged. The local Network V2 start command adds
the optional `screen_video` intent (field 3): a sender configures its H.264-only
send track before Offer, and explicit incoming claim configures the receive
track before Answer. Ordinary Realtime starts omit this intent and remain
media-neutral. Negotiating a track never authorizes screen capture; acceptance
and the native generation guards remain mandatory.
Both Direct endpoints must run a version supporting screen video and frame kind 6;
old endpoints reject an unknown frame instead of downgrading authentication.
Media remains native WebRTC DTLS-SRTP; Relay still forwards only signaling.

## Validation

Independent tests require real authenticated QUIC and TCP runtimes with no
Relay, Offer/REQUEST notification, explicit claim/ACCEPT, and ICE/DTLS Connected.
Security tests reject forgery, replay, wrong recipients and stale bindings.
Wildcard-bind tests cover concrete candidate selection and I/O identity.
Actual Windows/Android capture/render remains separate device acceptance.
