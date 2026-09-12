最新更新时间：2026-09-12

# ADR-035：PR74 屏幕共享控制面与 provisional claim

## Status

Accepted for PR74 on `main@1bed4c2`. ADR-034 remains the historical media
boundary decision and is not rewritten by this clarification.

## Decision

PR74 is a product-entry change for the existing one-to-one realtime screen
share. It does not add camera, voice, system audio, remote control, recording,
multi-party media, SFU, or a second signaling/media stack.

The Relay V2 `RealtimeSignal` gets additive protobuf field
`source_device_id = 7`. Client-to-Relay frames must leave it empty; Relay
rejects a non-empty client value and writes the authenticated sender device ID
when forwarding to a target. Receivers trust only that forwarded value. A
missing source remains compatible for an already-bound realtime session; an
unknown session without source fails closed; a present source that disagrees
with the established binding fails closed. Old clients ignore the additive
field.

`sender_peer_id` means the authenticated author of the individual consent
action, not a permanent operation owner:

```text
REQUEST.sender_peer_id = operation initiator
ACCEPT.sender_peer_id  = receiver that accepted
REJECT.sender_peer_id  = receiver that rejected
CANCEL.sender_peer_id  = actor that cancelled
```

The provisional native binding is metadata and protected native state only:

```text
pending → claiming → claimed
pending/claiming → terminal
```

It may retain one Offer, matching bounded ICE, immutable typed REQUEST metadata,
expiry, and an opaque claim token. It never creates a Dart/SDK
`RealtimeSession`, Answer, media endpoint, decoder, or renderer before explicit
Accept. Offer and REQUEST must be paired before metadata is published to Dart.
Matching ICE stays native-only and uses the formal signaling limits: 128
candidates, 8 KiB each, 256 KiB total, 256 KiB total queue bytes, and 120
seconds, with the earlier binding or REQUEST expiry winning. A native-only
epoch guards the supervised expiry worker from deleting a replacement entry.
Before exact responder registration, ICE arriving during `claiming` remains in
the protected queue; after that exact ownership is installed, matching ICE may
route directly to the exact claiming generation. Claim is externally committed
only after Answer succeeds; rollback destroys that generation and remaining
provisional state.

Each authenticated peer has a five-minute replay cache bounded to 256 keys.
The target component uses the local authenticated device identity, not an
untrusted forwarded string. REQUEST is action revision 1 and a same-author
CANCEL is revision 2. The Offer and REQUEST containers share one 32-operation
budget: one authenticated provisional `realtime_id` consumes one slot in every
Offer-only, REQUEST-only, or paired state.

The SDK claims in this order: register the exact responder session, call the
native provisional backend, consume Offer and queued ICE, create and send the
Answer, then return the registered session. Synchronous Negotiating events must
therefore be observed. Answer failure closes the exact responder, invalidates
its generation, removes only the identical SDK registry entry, and terminates
the binding. Reject has a provisional wire side effect; discard is silent
cleanup. The initial typed REQUEST is seeded into the Feature controller once
after claim, and typed ACCEPT is sent immediately rather than after Connected.

`RealtimeSession.currentSnapshot` and `snapshots` are SDK-normalized lifecycle
projections. Every accepted state or full snapshot update can advance this
projection, including a Negotiating state event without a full snapshot. App
code reads, subscribes, then reads again to close the subscription race.

Public `releaseSession(session)` is also terminal-authoritative: it records a
release request and asks native to stop, but it removes only the exact session
object after an authoritative stopped/failed event. Command completion or an
App timeout is not terminal and cannot make the same `realtime_id` reusable;
runtime disposal remains the final force-cleanup owner.

## Ownership

The App Shell owns route/session orchestration and the peer arbitration registry.
`AppScreenShareSessionLease` owns only the Realtime session stop/terminal wait
and exact release; the media coordinator owns endpoint, capture/encoder,
decoder, and opaque platform surface. LAN exposes only a public capability and
does not import the screen-share Feature.

## Consequences

This preserves consent-before-answer, avoids auto-answer on unknown sessions,
and makes sender Cancel, late ICE, replacement generations, and old Relay
compatibility explicit. Windows/Android real-device capture, permission,
trickle ICE, rendering, disconnect, and cleanup remain separate hardware
acceptance evidence and are not claimed by CI simulation.
