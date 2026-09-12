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
`source_device_id = 7`. Clients must omit it; Relay rejects a non-empty client
value and writes the authenticated sender device ID when forwarding to a target.
Receivers trust only that forwarded value. A missing source remains compatible
for an already-bound realtime session; an unknown session without source fails
closed; a present source that disagrees with the established binding fails
closed. Old clients ignore the additive field.

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
candidates, 8 KiB each, 256 KiB total, 120 seconds, with the earlier binding or
REQUEST expiry winning. ICE arriving during `claiming` enters the same protected
queue and is drained exactly once into the exact responder generation.

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
