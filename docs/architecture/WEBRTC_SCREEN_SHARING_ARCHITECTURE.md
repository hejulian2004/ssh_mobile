Last updated: 2026-09-12

# WebRTC Screen Sharing Architecture

## Status and authority

Status: Accepted architecture for Phase 0 through Phase 7. Phase 0 and Phase 1
have committed implementation evidence without separate screen-share PRs; their
current baseline was accepted together with Phase 2 in PR #67. Phase 2 was
merged at `352ef4dc9c602f648f0975809ce12553957b2a75` after final head
`3d9a4a575f303a573371ce843867cf002f3b163d`. Phase 3 and Phase 4 platform
owners are implemented on their dedicated branches, but hardware availability,
device lifecycle, and cross-platform E2E gates remain unaccepted. Phase 5
typed consent/state-machine work, Phase 6 authenticated TURN issuer/SDK
contracts, and the Phase 7 bounded statistics/adaptation plus generation-bound
native keyframe/decoder-reset bridge are likewise in progress; the bridge is
only a native recovery foundation and does not prove codec/RTCP actuation or
platform E2E. None of these follow-up contracts is a claim that screen sharing
is shipped. The native plugin remains fail-closed when platform workers are
unavailable; native implementation or compilation evidence is not evidence of
a working capture-to-render pipeline.

This is only the Screen Share slice of M8 (RTC) in
[`NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md`](../NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md).
Voice, camera/general video, and other M8 work remain outside this document and
need their own contract and acceptance gates; an Accepted architecture is not a
claim that M8 or screen sharing is shipped.

This document accompanies [ADR-034](../adr/ADR-034-screen-share-realtime-media.md).
It extends, rather than changes, the accepted ownership and lifecycle decisions
in ADR-016, ADR-020, ADR-021, ADR-024, ADR-026, and
ADR-BUSINESS-RECOVERY-V2.
The execution sequence and per-phase evidence checklist live in
[`WEBRTC_SCREEN_SHARING_TODO.md`](WEBRTC_SCREEN_SHARING_TODO.md).

When an earlier proposal conflicts with this architecture, this Phase 0
decision controls:

- Screen video is H.264 only through Phase 7. There is no VP8 or AV1 fallback.
- The screen-video transport queue is exactly three frames.
- The implementation order is Rust encoded media, native media bridge, Windows,
  Android, consent/UI, TURN credentials, then QoS hardening.
- No future capability may be described as current until its phase passes the
  stated contract and acceptance checks.

## Purpose

SSH Mobile will support one-to-one, authenticated, real-time screen sharing
between native clients. Screen sharing is a business operation that coordinates
a Realtime session; it is not a new generic transport, a file-transfer mode, or
a Relay media service.

The target chain is:

~~~text
Feature business state and explicit user consent
        |
        v
App Shell capability and RealtimeSession coordination
        |
        +-------------------------------+
        |                               |
        v                               v
Realtime media infrastructure       Network SDK contract
        |                               |
        +---------------+---------------+
                        |
                        v
App-owned NetworkRuntime
        |
        v
Rust RealtimeManager and network-webrtc
        |
        v
WebRTC RTP / DTLS-SRTP
        |
        +-------------------------------+
        |                               |
        v                               v
Direct ICE                         coturn ICE relay
~~~

The control path remains authenticated Relay signaling. RTP and screen pixels
do not traverse the Relay backend.

## Scope and non-goals

The planned Phase 0 through Phase 7 product scope is:

- one sender and one receiver, both authenticated SSH Mobile peers;
- one H.264 screen-video track in a Realtime session;
- Direct ICE first, TURN fallback, and a relay-only validation path;
- explicit sender action and explicit incoming receiver consent;
- native capture, encode, decode, and GPU rendering on Windows and Android;
- bounded media queues, keyframe recovery, QoS, privacy regression checks, and
  generation-safe recovery.

The following are outside this architecture:

- group calls, SFU, MCU, broadcasting, recording, cloud storage, or media
  transcoding;
- keyboard or mouse control, system audio, camera video, and persistent screen
  content;
- Flutter Web as a transparent substitute for the native Rust runtime;
- macOS and iOS implementation gates before Phase 8 or a separately approved
  platform lifecycle design;
- a Relay backend that receives, stores, decrypts, transcodes, or forwards
  video payloads.

Remote control, browser media, or multi-party media require independent ADRs
and must not be added as a side effect of screen sharing.

## Current baseline versus planned capability

The current baseline has a single App-owned NetworkRuntime and NetworkFacade,
Rust RealtimeManager, native network-webrtc, RealtimeIoDriver, authenticated
Relay signaling, and typed Dart Realtime session coordination. Phase 1 adds the
native-only H.264 RTP path and fixed screen queue; Phase 2 adds a
generation-bound native endpoint bridge with native-only H.264 push/pull plus
the payload-free `realtime_media` lifecycle contract. Phase 5 now adds the
typed consent/state-machine boundary, Phase 6 adds the authenticated TURN
issuer/SDK contract, and Phase 7 adds bounded low-frequency statistics,
adaptation policy, a generation-bound native keyframe/decoder-reset bridge,
and native owner wiring for bounded encoder targets plus PLI/IDR requests.
These are still prerequisites rather than a completed video product: platform
hardware/device E2E, consent UI acceptance, production credential deployment,
codec/RTCP device validation, privacy validation, and final gates must pass
before screen sharing is described as delivered.

| Area | Current verified baseline | Planned screen-share capability |
| --- | --- | --- |
| WebRTC owner | network-webrtc owns a sans-I/O peer; RealtimeIoDriver owns that peer and its UDP socket | Keeps the same sole owner; no second peer or runtime |
| Runtime media | Generic Realtime sessions remain media-neutral; the explicit screen-share integration configures one H.264 screen transceiver on the sole native peer. `RealtimeIoDriver` flushes/receives encoded RTP without DataChannel or event-stream media; a native-only C ABI pushes/pulls encoded access units by opaque endpoint ID | Platform-native capture/codec/render owners invoke that bridge before screen SDP negotiation in later phases |
| QoS | A separate screen-video queue is fixed to three frames with keyframe-aware dropping; generic MediaFrame's four-frame policy remains unchanged. Native owners now accept bounded bitrate/frame-rate targets without resizing the queue | Phase 7 adaptation telemetry, hardware confirmation, and end-to-end recovery |
| Dart video shape | `network_sdk` exposes only Realtime signaling/state; `realtime_media` exposes opaque endpoint/surface lifecycle with no per-frame Dart path | Concrete platform surface adapter lifecycle notifications |
| Capture/rendering | Windows Graphics Capture, native H.264 send ingress, receive decoder/D3D11 texture owner, and the Android MediaProjection/MediaCodec/SurfaceTexture owner are implemented but have no accepted hardware/E2E evidence | Windows and Android native capture, hardware codecs, and native surfaces |
| Consent | Phase 5 now defines the typed signal/payload and Feature operation state machine; UI and platform acceptance remain gated | Explicit accept/reject before answer/capture, with operation and generation replay guards |
| TURN | Phase 6 has an authenticated short-lived issuer contract and in-memory SDK store; production relay integration remains gated | Per-session production credentials, expiry/refresh, redaction, and relay-only E2E |
| Recovery | Transport loss terminates Realtime and invalidates every bound native media endpoint before its peer closes; generation-bound native keyframe/decoder-reset requests, receive-side PLI, and send-side hardware IDR/adaptation commands are exposed through the owner port | Same rule, plus platform capture/decoder/surface cleanup, device validation, privacy teardown, and Phase 7 recovery policy |

In particular, a Video SDP m-line, a generic MediaFrame queue, or a
DataChannel test payload named like a frame is not evidence of H.264 video
transport. Phase 1's native encoded H.264/RTP tests and Phase 2's endpoint
lifecycle tests prove only their stated boundaries; no architecture, README,
test name, or release note may imply capture-to-render video until the relevant
later phase succeeds.

### Phase implementation status

| Phase | Current status | Evidence boundary |
| --- | --- | --- |
| 0 | Implementation evidence accepted with PR #67; no separate screen-share PR | Accepted architecture, ADR-034, memory routing, and documentation checks |
| 1 | Implementation evidence accepted with PR #67; no separate screen-share PR | Native H.264-only RTP ingress/egress, exact three-frame queue, bounded frame validation, terminal media discard tests, local loopback, and relay-only coturn H.264 coverage |
| 2 | Accepted in PR #67 and merged to `main` | Runtime/realtime-generation-bound opaque endpoint leases, native-only FFI create/release/H.264 push/pull controls, Dart lifecycle contract/fake tests, and no per-frame Dart API |
| 3 | In progress: boundary, Windows capture lifecycle, H.264 ingress, and decoder/texture implementation | Hardware availability, Windows E2E, and the complete Phase 3 acceptance matrix remain outstanding |
| 4 | In progress: Android MediaProjection/MediaCodec/SurfaceTexture owner implementation | Device permission/revocation, lifecycle interruption, hardware codec and cross-platform E2E acceptance remain outstanding |
| 5 | In progress: typed consent protocol, Feature state machine, and App Shell ports | UI/transport acceptance, duplicate/replay/recovery matrix, and Phase 5 PR gate remain outstanding |
| 6 | In progress: authenticated TURN issuer, SDK parser/store, and redaction contract | Production device-auth integration, secret scan, expiry/refresh, and relay-only E2E remain outstanding |
| 7 | In progress: bounded low-frequency stats/adaptation, generation-bound native recovery, and platform PLI/IDR/adaptation wiring | Hardware/device confirmation, privacy teardown, E2E, and final CI gate remain outstanding |

## Layer boundaries

### Feature

The planned feature package owns only business concerns:

- peer and capture-source selection;
- outgoing request, incoming request, accept, reject, cancel, retry, and stop;
- ScreenShareState, user-visible errors, and route-scoped presentation;
- persistent visible sharing status while local capture is active.

Feature code must not create a PeerConnection, parse SDP or ICE, hold a UDP
socket, hold a native pointer, choose RTP payload types, access a TURN
credential, or import another feature implementation. It borrows public
capabilities from the App Shell and releases only its own subscriptions and
operation leases.

ScreenShareState is deliberately separate from RealtimeSessionState. The former
models business states such as preparing, waitingForPeer, incomingRequest,
sharing, viewing, stopping, and failed. The latter remains the native
transport/session lifecycle.

### App Shell and SDK

The App Shell composes Feature, realtime media, network_sdk, network_transport,
and the native binding. It owns correlation between typed command completion,
native Realtime state, consent, and media readiness. It hides signaling,
command IDs, sockets, FFI handles, and native objects from Feature code.

The public SDK remains a low-frequency control boundary. The previous
producer-less remote-video bytes placeholder was retired in Phase 2 under the
compatibility inventory; it cannot return as the screen-share hot path. Opaque
endpoint and rendering contracts remain outside the Feature-facing SDK.

### Native media infrastructure

The `realtime_media` infrastructure package currently owns the Dart
endpoint-lifecycle contract, opaque source/surface descriptors, and payload-free
statistics snapshots; its independent tests provide the fake backend. It does
not own platform capture, hardware codecs, a renderer, or the NetworkRuntime.
The separate `realtime_media_windows` and future Android adapter packages own
capture, H.264 encoder/decoder instances, GPU surfaces, and Flutter Texture or
equivalent rendering while using the existing native bridge by endpoint lease.

### Rust runtime

Rust network-webrtc remains the only PeerConnection owner. RealtimeManager
owns each Realtime session's registration, terminal state, and signaling
coordination. RealtimeIoDriver holds the session's network-webrtc peer, UDP
socket, timer loop, and I/O task; it does not transfer those resources to the
Feature. The task is supervised under the Realtime session and closes before
the session's native resources are released.

## Resource ownership and release

| Resource | Owner | Scope | Release rule |
| --- | --- | --- | --- |
| NetworkRuntime and NetworkFacade | AppRuntime | App | App shutdown only |
| RealtimeManager | Rust NetworkRuntime | App/native | Closes sessions before Runtime destruction |
| Realtime session registration and terminal state | RealtimeManager | Realtime session | Manager coordinates signaling close before driver/media release |
| WebRtcPeer | network-webrtc, held by RealtimeIoDriver | Realtime session | Manager requests terminal close; driver cancels/joins before peer release |
| UDP socket, timer, and I/O task | RealtimeIoDriver | Realtime session | Driver task is cancelled and joined before socket release |
| Realtime media endpoint | Native runtime/media bridge | Realtime session generation | Revoked on detach, close, replacement, or Runtime stop |
| ScreenShareOperation | feature_screen_share | Business operation | Stop, reject, cancel, terminal failure, or route disposal |
| Capture source and encoder | platform adapter (`realtime_media_windows` or Android equivalent) | Screen-share session | Stop production before encoder/capture release |
| Decoder, GPU surface, and Texture | platform adapter renderer | Viewer session | Detach decoder, then release surface and texture |
| Feature subscriptions and ViewModel | Feature Route scope | Route | Cancel and dispose without closing App resources |

A Feature may stop its own operation through the injected App Shell capability,
but it may never dispose, stop, reconfigure, or destroy the App-owned
NetworkRuntime, NetworkFacade, native handle, RealtimeManager, socket, peer,
wire `webrtc_close`, or another operation's endpoint. RealtimeManager is the
only owner that coordinates a terminal session close; the driver and media
owners release their own resources after that close request.

Normal stop has this order:

~~~text
Feature stop request
  -> stop producing new screen frames
  -> detach local media ingress
  -> release capture and encoder
  -> request Realtime session stop through App Shell
  -> RealtimeManager sends/handles webrtc_close and waits for correlated native completion
  -> RealtimeIoDriver cancels/joins before releasing peer, socket, and task
  -> cancel Realtime subscriptions
  -> detach decoder and release render surface/Texture
  -> dispose route-scoped feature resources
~~~

App shutdown releases borrowers and media adapters before NetworkRuntime and its
native handle. Each release path must be idempotent and must continue its
remaining cleanup after an earlier release failure.

## Control plane and native media data plane

The existing protobuf command/event ABI remains the low-frequency control plane:

- current start, stop, state, signaling, command completion, errors, and bounded
  statistics;
- the typed `ScreenShareConsentV2` message and media endpoint/state extension,
  authored in the protocol source schema before generated artifacts;
- surface-ready, resolution-change, paused, resumed, and endpoint lifecycle
  notifications once the planned media contract exists;
- no encoded or decoded video payload on the event stream.

Screen video requires a separate, narrow native encoded-media data plane:

~~~text
Platform native capture
  -> hardware H.264 encoder
  -> native media bridge
  -> Rust network-webrtc RTP sender

Rust network-webrtc RTP receiver
  -> native media bridge
  -> hardware H.264 decoder
  -> GPU surface
  -> Flutter Texture or equivalent platform surface
~~~

The control plane may create, bind, detach, and release a media endpoint. The
high-frequency data plane may submit or deliver only native-resident encoded
H.264 frames. Phase 2 defines the native-only
`ssh_net_realtime_media_endpoint_*` C ABI for endpoint create/release and H.264
push/pull. Its frame metadata and Rust-owned pull buffer are unavailable to the
Dart FFI facade; platform-native capture and decoder owners use them directly.
The additive native owner port exposes generation-validated start/stop/close
and renderer attach/detach gates plus the same native-only push/pull path. Its
opaque token retains the full endpoint identity; runtime stop and destroy
invalidate the token registry before the runtime can be released, and every
push/pull operation revalidates that identity before touching the bounded media
queue. Dart only uses the low-frequency endpoint owner open/close adapter and
never declares these frame or renderer functions.
The boundary must obey these invariants:

- Dart receives only a bounded opaque RealtimeMediaEndpointId, never a pointer,
  socket, peer, codec instance, or native buffer address.
- Every endpoint is bound to runtime generation, realtime ID, peer ID, and
  direction. A prior generation is invalid after stop, transport loss, or
  Runtime replacement.
- Native ingress validates codec, frame length, dimensions, timestamp, and
  monotonic sequence before a queue commit.
- Releasing an endpoint is safe and idempotent. It also clears the released
  direction's pending queue and ordering state before a replacement lease can
  observe the native peer. Input after release or against a stale generation
  fails without use-after-free.
- Dart observes state, errors, statistics, and an opaque renderer capability;
  it does not observe one Uint8List per video frame.
- Raw RGBA and YUV frames never cross the Dart main isolate. Encoded H.264
  frames also never use the protobuf event stream as their high-frequency
  transport.

Command completion and generation validation are separate guards. The App Shell
uses `commandId` only to match queue acceptance to the corresponding native
completion. A separate generation guard checks `(realtime_id, generation)` on
every state/signal event, endpoint operation, and frame submission; a new
Realtime session or Retry gets a new generation, and stale events/results/input
are dropped before they reach Feature or media owners. `generation` is not a
`commandId`, a Relay `revision`, or a Discovery `runtime_epoch`.

The following routes are forbidden:

~~~text
Screen frame -> Dart bytes -> FFI -> Rust
RTP or video payload -> RelayDataFrame
RTP or video payload -> Delivery, Transfer, or file resume
RTP or video payload -> generic protobuf event stream
Feature -> native pointer, PeerConnection, SDP, ICE, socket, or TURN credential
~~~

## Codec and frame contract

H.264 is the only Screen Video Track codec from Phase 0 through Phase 7. Native
media and network-webrtc negotiate it; Feature code does not parse SDP or select
RTP payload types.

If H.264 cannot be negotiated, the session fails with UnsupportedCodec. If an
encoder or decoder cannot be obtained, the caller receives the appropriate
encoder or decoder availability/failure error. No code may silently fall back to
VP8, AV1, a DataChannel, Dart bytes, or another WebRTC implementation.

The planned public error mapping preserves actionable categories rather than
collapsing every failure into `NetworkError`:

| Source | Screen Share/SDK category | User/business meaning |
| --- | --- | --- |
| Capture permission | `PermissionDenied` | Permission was denied or revoked |
| Capture source | `CaptureSourceEnded` | The selected source closed or disappeared |
| H.264 encoder | `EncoderUnavailable` / `EncoderFailed` | Encoder is unavailable or failed |
| H.264 decoder | `DecoderUnavailable` / `DecoderFailed` | Decoder is unavailable or failed |
| SDP capability | `UnsupportedCodec` | Peers have no common H.264 capability |
| Signaling/negotiation | `RealtimeNegotiationFailed` | SDP, version, signaling, or DTLS failed |
| ICE/TURN | `IceFailed` / `TurnUnavailable` | Direct ICE or TURN path failed |
| Consent/recovery | `PeerRejected` / `OperationExpired` / `ResumeRejected` | Peer rejected, intent expired, or recovery was rejected |
| Terminal transport | `PeerDisconnected` / `RecoverableTransportLoss` | Peer ended or business Retry is available |

Relay wire errors remain typed: `PEER_OFFLINE`/`PEER_NOT_READY` map to the
peer-unavailable `PeerDisconnected` result; `CONTROL_UNAVAILABLE`,
`RELAY_UNAVAILABLE`, and `RESOLVE_TIMEOUT` map to
`RealtimeNegotiationFailed`; `RESERVATION_FAILED` and `RESERVATION_EXPIRED` map
to `TurnUnavailable`. Unknown or unauthenticated wire errors fail closed and do
not fall through to a generic `RelayError` or `IoError`.

The Phase 1 encoded-frame model must carry at least:

| Field | Contract |
| --- | --- |
| codec | H.264 only |
| sequence | Strictly monotonic per endpoint generation |
| timestamp | Validated, bounded, and ordered for the media clock |
| width and height | Bounded dimensions; reconfiguration is explicit |
| keyframe | Used for recovery and congestion policy |
| payload | Native-resident, non-empty, at most 4 MiB |

Frame payloads, SDP, TURN credentials, and complete ICE candidates must never be
logged.

Android's hardware H.264 owner keeps a bounded (64 KiB) SPS/PPS cache. Encoder
codec configuration may arrive through either `BUFFER_FLAG_CODEC_CONFIG` or
`INFO_OUTPUT_FORMAT_CHANGED` `csd-0`/`csd-1`; both are normalized to validated
Annex-B parameter sets. The sender drops deltas until a complete CSD+IDR is
accepted into the native bounded queue. A decoder learns CSD only from received
Annex-B access units, replays its validated cache after flush, and drops deltas
until a recovery IDR is queued. Any parameter-set update relocks the decoder
recovery gate, including an update carried by an IDR; the IDR is rechecked only
after codec-config replay and the gate opens only after
`MediaCodec.queueInputBuffer` succeeds. CSD cache overflow or malformed NAL
units fail closed; codec-config is never sent as a standalone media frame.

## Consent and signaling

Existing authenticated signaling carries offer, answer, ICE candidate, ICE
restart, and close. Phase 5 adds the dedicated
`REALTIME_SIGNAL_KIND_SCREEN_SHARE_CONSENT` signal and its authenticated
`ScreenShareConsentV2` control payload through the protocol source of truth. It
is not a `RelayDataFrame` or a video payload. Relay V2 extends the existing
`RealtimeSignal` additively with `source_device_id = 7`: a client-to-Relay
signal must omit it, while Relay writes the authenticated sender device ID on
the server-to-target direction. Existing bound sessions still accept an absent
source from an old Relay; an unknown session without an authenticated source
fails closed. The typed consent payload is:

~~~text
schema_version = 2                  # payload schema version, not Relay v2
decision = REQUEST | ACCEPT | REJECT | CANCEL
purpose = SCREEN_SHARE               # typed enum, not free-form text
operation_id                         # non-empty, <= 128 bytes
sender_peer_id                       # non-empty, <= 128 bytes
realtime_id                          # canonical 32-char shared session identity
media = SCREEN_VIDEO                 # typed enum
requires_acceptance = true
issued_at_ms
expires_at_ms                        # issued < expires <= issued + 120 s
action_revision >= 1                 # monotonic within (operation_id, sender_peer_id)
~~~

The whole typed payload is at most 4 KiB, below the existing 256 KiB
`RealtimeSignal` payload bound. `sender_peer_id` identifies the authenticated
author of the individual consent action: REQUEST identifies the operation
initiator, ACCEPT/REJECT identify the receiver that made that decision, and
CANCEL identifies the actor that cancelled. The operation ID binds later
actions to that request; no `peer_id` or `sender_device_id` alias is introduced.
`contentSenderPeerId` is a derived provisional-operation property, not another
wire field.
The payload contains no bearer token, private key, or reusable credential.

The receiver keeps at most 32 live provisional operations, where one
authenticated provisional `realtime_id` consumes one slot whether it is
Offer-only, REQUEST-only, or paired. Offer and REQUEST storage therefore share
one budget, and an identity mismatch on the other half of an existing
`realtime_id` fails closed. A bounded replay cache keeps at most 256 keys per
authenticated peer for five minutes; its key is
`(sender_peer_id, local_authenticated_device_id, realtime_id, operation_id,
decision, action_revision)`. Expiry deletes provisional state and cannot be
renewed. A native-only entry epoch makes expiry deletion exact across
REQUEST-before-Offer pairing and replacement.
Replay-cache failure, duplicate or out-of-order action, expired intent, unknown
version/purpose/media, oversized payload, or a non-contiguous action revision
fails closed.

Authentication and binding checks are mandatory: the Relay-authenticated outer
source and target must match the expected peers; `sender_peer_id` must match the
authenticated author of this individual action. REQUEST establishes the
operation initiator; ACCEPT/REJECT must be authored by the authenticated
receiver and CANCEL by the authenticated actor issuing the cancellation.
`realtime_id` must map to the current shared session. REQUEST alone creates
provisional state; ACCEPT/REJECT only acts on a matching, non-terminal,
non-expired REQUEST.
`schema_version`, action replay, and the local native-generation guard are
separate checks. Native generation is process-local media-lease freshness and
never appears in the consent wire payload. The Relay routes this bounded
control message but does not trust, rewrite, parse, store, or forward media
payload.

Consent freshness is checked at ingress, not by the value constructor:
`issued_at_ms` may be at most 30 seconds in the future, `expires_at_ms` must be
after the injected current time, and the lifetime is at most 120 seconds.
Simultaneous REQUESTs are resolved without a response race by comparing the
UTF-8 byte order of `(peer_id, operation_id)`. The smaller tuple keeps its
outgoing operation; the other controller locally abandons its outgoing
operation, resets its local action lane and adopts the incoming operation. No
collision REJECT or CANCEL is sent, and late actions for the abandoned ID are
ignored.

The accepted receiving flow is:

~~~text
Incoming screen-share request
  -> feature presents accept and reject
  -> user reject: close/reject without an accepted media session
  -> user accept: validate operation, authenticated sender, realtime ID, and generation
  -> pre-register the exact SDK responder session
  -> native consumes the pending Offer and queued ICE, creates and sends Answer
  -> send typed ACCEPT immediately; Connected remains a transport gate
  -> native ready + matching generation: attach remote decode/render path
~~~

An incoming Offer may be retained only as bounded provisional signaling state
needed to ask the user. It must not automatically create a final accepted media
session, auto-answer, auto-display a screen, or start local capture. Before
claim, authenticated matching ICE remains native-only in a bounded queue:
128 candidates, 8 KiB per candidate, 256 KiB total, and a 120-second binding
lifetime. Offer and ICE share the formal signaling validation. A claim uses the
state machine `pending -> claiming -> claimed`; ICE arriving before exact
responder registration remains in the protected queue, while later matching ICE
may route directly to that exact claiming generation. Answer success is the
external claim commit; rollback destroys the exact generation and any remaining
provisional queue. A sender CANCEL must also remove an unclaimed provisional
binding. A runtime-supervised native expiry worker is authoritative; App expiry
only removes stale UI/arbitration state.
Stale, duplicate, oversized, unknown, or mismatched operation actions fail
closed.

The App receives a `RealtimeIncomingSessionOffer` only after an authenticated
Offer and the complete matching typed REQUEST have been paired. The metadata
contains the immutable REQUEST, operation/revision/freshness, peer/session
identity, expiry, and an opaque claim token; SDP, ICE, and the pending native
handle never enter Dart. Reject has a provisional wire side effect and then
terminates the binding; discard is silent local cleanup. Answer-send failure
rolls back the exact responder generation and exact SDK registry entry, without
touching a replacement session.

`releaseSession` is not a command-completion shortcut: it records a pending
release, requests stop, and waits for the exact session's authoritative
stopped/failed lifecycle event before removing the SDK registry entry. A
bounded route teardown may return while that release remains pending; runtime
dispose is the final force-cleanup owner.

The accepted sending flow is:

~~~text
User explicitly starts sharing
  -> select peer and source metadata
  -> create ScreenShareOperation and outgoing intent
  -> receiver explicitly accepts
  -> validate consent and obtain OS permission
  -> WebRTC answer, ICE, DTLS-SRTP, and native media endpoint are ready
  -> begin actual capture and H.264 encoding
~~~

The sender must not continuously capture, encode, or queue real screen content
until all three conditions are true: explicit sender action, remote acceptance,
and WebRTC readiness. Sharing UI must visibly state that sharing is active; use
a platform capture indicator or foreground notification where available.

## PR74 product entry and ownership gate

PR74 connects the accepted capability stack to a user-facing vertical slice:

~~~text
LAN trusted online peer
  -> source metadata picker and App-issued route token
  -> sender RealtimeSession / Negotiating identity
  -> native provisional Offer + bounded ICE
  -> typed REQUEST and Offer/REQUEST pairing
  -> global incoming host / explicit Reject or Accept
  -> claim, Answer, identity, typed ACCEPT
  -> Connected + consent + current generation
  -> capture / decode / opaque surface presenter
  -> Stop, disconnect, and role-aware cleanup
~~~

The LAN Feature exposes only a narrow public capability and never imports the
screen-share Feature. An App-scope peer arbitration registry covers pending and
active intents for a remote peer, uses the public UTF-8
`(initiatorPeerId, operationId)` comparator, and does not duplicate consent
business logic. The App session lease owns only the `RealtimeSession`, stop,
terminal wait, and exact SDK release. The media coordinator owns endpoints,
capture/encoder, decoder, and platform surface/texture. Sender teardown stops
production before capture/endpoint release and then stops/releases the session;
receiver teardown stops ingress, stops/releases the session, then detaches and
releases the decoder/surface. No route stops the App `NetworkRuntime`.

## Media lifecycle, backpressure, and recovery

The current generic `network-webrtc` `MediaFrame` video policy is four frames
and remains the policy for existing generic Realtime media. Phase 1 added a
separate screen-video transport profile whose capacity is exactly three frames;
this architecture does not change the generic four-frame default.
Capture, encode, decode, and render staging queues also have explicit, small,
fixed bounds in their respective owner contracts. Unlimited VecDeque instances,
unbounded asynchronous channels, and unbounded StreamController instances are
not allowed.

Queue rules are:

1. Reject payloads larger than 4 MiB before queue commit.
2. Drop an already stale frame before it can be sent.
3. Under pressure, drop the oldest non-keyframe first.
4. Preserve the recovery keyframe. If preserving it leaves no safe space, drop
   a new delta frame rather than the only recovery point.
5. On stop, terminal loss, endpoint replacement, or generation mismatch,
   discard all pending video. Never replay historical video after recovery.

Android capture owns a one-shot `ProjectionLease` with states
`granted -> consumed -> released`. A consumed `MediaProjection` is used for
one `createVirtualDisplay()` only. Normal stop releases the VirtualDisplay,
codec, and surface before unregistering the projection callback and calling
`MediaProjection.stop()`. If the encoder worker reaches `cleanup_deferred`,
the consumed lease remains bound to its owner and its callback/projection stay
alive for a later retry; they are not stopped while the worker is unsafe.
Display-size changes remain `capture_source_ended` and require a fresh capture
and fresh projection grant; this architecture does not add rotation hot-resize.

The App Shell's Android backend is an App-scope singleton shared by route
coordinators. It serializes projection preparation across routes: a caller
owns the preparation slot only after an `acquired` result, and an
`invalidated` or failed preparation has already performed its own cleanup.
Attach success releases the slot before any later stale-operation check; attach
failure keeps it until the caller's matching abandon completes. This prevents
an asynchronous route disposal from abandoning a newer route's unconsumed
grant without adding a projection identifier. Queued starts re-check their
operation epoch before requesting permission.

An Android decoder may retain at most one already-pulled encoded frame while
`MediaCodec` input is unavailable. A pending frame prevents another native
pull. Reset/flush clears that frame, preserves validated CSD for replay, and
never replays a pre-reset delta frame.

A native keyframe request is required after first-track activation, decoder
reset, source or resolution change, ICE restart, unrecoverable packet loss, or
viewer reconnect. The generation-bound owner port now carries explicit
keyframe-request, decoder-reset, and bounded adaptation commands with native
rate limiting. Windows and Android owners apply hardware bitrate/frame-rate
targets, send owners request native IDR frames, and receive owners emit PLI on
the WebRTC path. Device capability and end-to-end actuation remain acceptance
gates.

A transport loss is terminal for the affected realtime generation:

~~~text
old RealtimeSession, PeerConnection, ICE, DTLS-SRTP, endpoint, and queues
  -> close and discard

retry
  -> Resolve
  -> new RealtimeSession
  -> new PeerConnection
  -> new signaling
  -> new ICE and DTLS-SRTP
~~~

No caller may reuse a closed PeerConnection, old session ID, old endpoint ID,
old media queue, or late command result. Command correlation discards a result
that has no matching command; the separate generation guard discards any event,
endpoint operation, or frame that belongs to an old generation.

## QoS, statistics, and telemetry

The first fixed profile is a maximum of 1920 by 1080, 15 FPS, and about 3 Mbps.
Phase 7 may adapt it using loss, RTT, encoder backlog, and queue pressure. The
low-frequency Dart controller applies three-second congestion hysteresis,
bounded 25-percent bitrate steps, a severe-loss/RTT 720p10 target, and one-level
recovery only after ten healthy seconds; native owners remain responsible for
the actual hardware mutation and the queue never grows beyond three frames:

| Condition | Action |
| --- | --- |
| About three seconds of loss at least 5 percent, RTT at least 250 ms, or queue/encoder pressure | One degradation step: 1080p15 to 1080p10 |
| Continued degradation | Reduce bitrate by 25 percent per bounded step |
| Loss at least 10 percent or RTT at least 400 ms | Move to 720p10 |
| Ten seconds healthy with loss below 2 percent, RTT below 150 ms, and healthy queues | Recover one level only |

Statistics update outside the blocking media hot path. The current native owner
bridge exports fixed-width enqueue/dequeue/drop, packet sent/received/lost,
recovered-frame, keyframe-request, jitter, and bounded queue depth/capacity
counters into the low-frequency `RealtimeMediaStats` snapshot. RTT remains
platform-gated until the rtc integration exposes an authoritative RTCP/ICE
source; it is never synthesized from media arrival timing. The planned
aggregate fields include capture, encode, sent, decode, and render FPS;
resolution; target and actual bitrate; RTT, jitter, loss; frame and keyframe
counters; codec; and selected ICE path.

For RTP screen video, `packets_lost` is a finalized monotonic total within one
endpoint generation. A 128-packet reorder window keeps missing sequence
numbers provisional; only numbers outside that window are finalized, so a late
reordered packet never decreases the native total or creates a new loss burst.
Timing, connection-loss, and track-close resets preserve the total; a new
endpoint generation starts at zero. Dart treats a defensive decrease as
`delta = 0` and rebaselines the sample.

Telemetry work follows ADR-033 and its contract source. It may emit outcome,
duration, metric buckets, codec, ICE path, and error category. It may not emit
screen pixels, screenshots, encoded video, SDP, TURN credentials, complete ICE
candidates, remote IPs, window titles, source titles, or any user screen
content.

### Planned performance acceptance (Phase 7)

These are acceptance thresholds for the planned product, not current baseline
measurements:

| Scenario | Required evidence |
| --- | --- |
| Normal direct or TURN session | First frame < 5 s after consent, permission, and native readiness; 1080p15 remains stable |
| 30-minute run | Process memory and every media queue remain bounded and do not continuously grow |
| Dart boundary | Dart main isolate performs no raw-frame copy or per-frame event handling |
| Stop | No new capture/send content within < 1 s; capture, encoder, decoder, surface, and Texture are released |
| Congestion | Profile follows the bounded loss/RTT steps, drops frames, and never grows latency or queues without bound |

Evidence must include counters/buckets and owner cleanup assertions without
capturing or persisting screen content.

## Transport, Relay, and TURN

Relay and TURN have separate responsibilities:

~~~text
Relay backend: device authentication, identity/presence, and bounded signaling
coturn: standard ICE relay for encrypted WebRTC packets
~~~

Relay never carries RTP or media payload. It does not store SDP, ICE, consent
history, or any screen content. The consent signal is bounded live control
metadata only; it must not create history. Delivery, Transfer, file resume, and
RelayDataFrame remain unrelated to the video data plane.

Development may retain the existing in-memory runtime TURN configuration.
Phase 6 replaces a production static client credential with a device-authenticated
short-lived TURN REST credential for each Realtime session. The server keeps the
shared secret only in its secret environment; the client retains the issued
credential only in session memory, never exposes it to Feature, and never
persists or logs it.

The current device-proof transcript remains `METHOD`, `PATH`, `TIMESTAMP`, and
`NONCE`. Consider binding `BODY_SHA256` to the proof transcript before
production security certification; that change requires an approved protocol
migration across the source schema and generated Go/Rust/Dart clients.

## Platform rendering and capture

The first platform matrix is:

| Platform | Capture | Codec and rendering | Gate |
| --- | --- | --- | --- |
| Windows | Windows Graphics Capture | Media Foundation H.264 and D3D/GPU surface to Flutter Texture | Phase 3 |
| Android | MediaProjection | MediaCodec H.264 and Surface or SurfaceTexture to Flutter Texture | Phase 4 |
| macOS | Not in Phase 0-7 implementation scope | Requires ScreenCaptureKit and VideoToolbox review | Future |
| iOS | Not in Phase 0-7 implementation scope | Requires ReplayKit lifecycle review | Future |
| Flutter Web | Not a native-runtime substitute | Requires separate browser adapter ADR | Future |

Windows source closure, encoder unavailability, resize, double start, and
release ordering need deterministic fake-platform tests before device testing.
Android must use the system MediaProjection prompt, correctly typed foreground
service, and revocation callback. Each grant is a single-use lease for one
VirtualDisplay; revoke affects only the bound send owner. Projection revoke,
surface destruction, rotation/size change, background behavior, and permission
denial fail closed and stop production immediately. Rotation remains a known
device-acceptance gap and uses restart-required handling until a separately
approved hot-resize design exists.

The renderer uses a native decoder and GPU surface. A Flutter widget observes an
opaque surface and low-frequency state; it must not rebuild from raw frame bytes
on every frame.

## Delivery plan and phase acceptance matrix

| Phase | Planned deliverable | Acceptance evidence (not current-state evidence) | May not do |
| --- | --- | --- | --- |
| 0 | This architecture, ADR-034, and Memory Map routing | Companion parity, current/planned labels, link/structure checks, and no protocol/code change | Product code, protocol, UI, or platform changes |
| 1 | Rust encoded H.264 ingress/egress, RTP loopback, 3-frame screen queue, keyframe and TURN video tests | Native encoded-access-unit loopback, H.264 negotiation/error tests, exact three-frame drop/keyframe tests, and terminal-generation discard | Dart API, UI, capture, or a second peer/runtime |
| 2 | Native media bridge and `realtime_media` public lifecycle contract with opaque endpoint | Endpoint create/release plus native-only H.264 push/pull, generation rejection, bounded frame validation, and native surface lifecycle tests | Real Windows/Android capture or Feature-owned native resources |
| 3 | Windows capture, hardware codec, native decode/render, and Windows-to-Windows E2E | First pass deterministic **synthetic/fake Windows capture** plus synthetic H.264/codec/surface/release-order acceptance; then Windows-to-Windows E2E. Synthetic pass is not shipped platform support | Android capture or feature UI |
| 4 | Android MediaProjection, MediaCodec, rendering, and cross-platform E2E | First pass deterministic **synthetic permission/projection/codec/surface** acceptance for deny, revoke, rotation, background, and cleanup; then Windows↔Android and Android↔Android E2E | Screen-share business entry before consent layer |
| 5 | Typed consent protocol and `feature_screen_share` UI/operation | Version/size/expiry/replay/auth-binding tests; explicit accept/reject before answer; no auto-answer or capture; operation/error mapping | Feature-to-Feature dependency or auto-accept |
| 6 | Authenticated short-lived TURN credential and relay-only screen-share E2E | Relay-only media path, per-session expiry/revocation, credential redaction, and proof Relay never sees RTP | Static production credential in a Feature |
| 7 | Adaptive QoS, telemetry, privacy regression, CI gates, and stability evidence | QoS hysteresis, bounded queues, privacy/redaction, and the Phase 7 performance thresholds below | Unbounded queues, content telemetry, or unbounded latency |

Each phase starts from the approved prior phase, uses its own branch and review
scope, and follows Red, Green, Refactor for observable behavior. Phase 0 is the
documentation exception. New protocol fields are authored in the source schema,
then generated through the repository process; generated output alone is never
the source of a contract change.

## Acceptance and hard stops

Phase 0 accepts only when:

- this Architecture and ADR-034 agree on ownership, H.264-only policy, media
  boundary, consent, recovery, queue capacity, privacy, and phase ordering;
- current state and future commitments are visibly distinguished;
- no existing Accepted ADR is altered;
- the Memory Map routes future screen-share work to the necessary Client, SDK,
  transport, ownership, recovery, compatibility, protocol-contract, and ADR
  context;
- the phase acceptance matrix and planned performance thresholds are explicit;
- documentation checks and git diff validation pass.

Before Phase 1 proceeds, the team must prove that the selected rtc integration
can send and receive application-provided encoded H.264 access units through
the existing sole PeerConnection and RealtimeIoDriver. It must not assume that a
Video SDP transceiver is a frame API.

Stop and return to architecture review if any of these conditions holds:

- rtc cannot expose a safe H.264 RTP ingress/egress path under the existing
  native PeerConnection owner;
- high-frequency media can proceed only by passing Dart bytes;
- implementation needs another PeerConnection, another runtime, or Relay media;
- platform bridging cannot bind safely to runtime generation;
- a Feature would need a raw native pointer;
- recovery would reuse a closed PeerConnection.

A stop report must identify the concrete code evidence, the ADR-034 conflict,
at least two architecture-safe alternatives, a recommendation, and the ADR
change required before implementation resumes.

## References

- [ADR-034](../adr/ADR-034-screen-share-realtime-media.md)
- [ADR-016](../adr/ADR-016-webrtc-media-qos.md)
- [ADR-020](../adr/ADR-020-webrtc-runtime.md)
- [ADR-021](../adr/ADR-021-native-dart-realtime-api.md)
- [ADR-024](../adr/ADR-024-webrtc-data-plane.md)
- [ADR-026](../adr/ADR-026-realtime-command-completion-correlation.md)
- [ADR-BUSINESS-RECOVERY-V2](../adr/ADR-BUSINESS-RECOVERY-V2.md)
- [Module Dependency](MODULE_DEPENDENCY.md)
- [Resource Ownership](RESOURCE_OWNERSHIP.md)
- [Compatibility Inventory](COMPATIBILITY_MIGRATION_INVENTORY.md)
- [Relay V2 wire contract](../../protocol/RELAY_V2_CONTRACT.md)
