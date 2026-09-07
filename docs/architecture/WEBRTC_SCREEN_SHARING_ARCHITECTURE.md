Last updated: 2026-09-07

# WebRTC Screen Sharing Architecture

## Status and authority

Status: Accepted architecture for Phase 0 through Phase 7. Phase 0 and Phase 1
have committed implementation evidence but no separate PR acceptance in the
current repository state; Phase 2 has implementation evidence on its dedicated
branch and also awaits its separate PR acceptance. Phase 3–7 remain planned
and must not be described as shipped capability.

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
the payload-free `realtime_media` lifecycle contract. These are prerequisites,
not a completed video product:
capture, decoding/rendering, consent UI, production TURN credentials, and QoS
hardening remain future work until their phase contract and acceptance evidence
pass.

| Area | Current verified baseline | Planned screen-share capability |
| --- | --- | --- |
| WebRTC owner | network-webrtc owns a sans-I/O peer; RealtimeIoDriver owns that peer and its UDP socket | Keeps the same sole owner; no second peer or runtime |
| Runtime media | Generic Realtime sessions remain media-neutral; the explicit screen-share integration configures one H.264 screen transceiver on the sole native peer. `RealtimeIoDriver` flushes/receives encoded RTP without DataChannel or event-stream media; a native-only C ABI pushes/pulls encoded access units by opaque endpoint ID | Platform-native capture/codec/render owners invoke that bridge before screen SDP negotiation in later phases |
| QoS | A separate screen-video queue is fixed to three frames with keyframe-aware dropping; generic MediaFrame's four-frame policy remains unchanged | Phase 7 adaptation and telemetry |
| Dart video shape | `network_sdk` exposes only Realtime signaling/state; `realtime_media` exposes opaque endpoint/surface lifecycle with no per-frame Dart path | Concrete platform surface adapter lifecycle notifications |
| Capture/rendering | No production platform screen capture, H.264 codec bridge, decoder, or texture chain | Windows and Android native capture, hardware codecs, and native surfaces |
| Consent | Existing signaling has no screen-share business intent or user-accept gate | Typed, versioned screen-share consent payload and explicit accept/reject before answer |
| TURN | Runtime configuration may hold development credentials in memory | Authenticated, short-lived, per-session production credentials |
| Recovery | Transport loss terminates Realtime and invalidates every bound native media endpoint before its peer closes | Same rule, with platform capture/decoder/surface cleanup in later phases |

In particular, a Video SDP m-line, a generic MediaFrame queue, or a
DataChannel test payload named like a frame is not evidence of H.264 video
transport. Phase 1's native encoded H.264/RTP tests and Phase 2's endpoint
lifecycle tests prove only their stated boundaries; no architecture, README,
test name, or release note may imply capture-to-render video until the relevant
later phase succeeds.

### Phase implementation status

| Phase | Current status | Evidence boundary |
| --- | --- | --- |
| 0 | Implementation evidence ready; PR acceptance pending | Accepted architecture, ADR-034, memory routing, and documentation checks |
| 1 | Implementation evidence ready; PR acceptance pending | Native H.264-only RTP ingress/egress, exact three-frame queue, bounded frame validation, terminal media discard tests, local loopback, and relay-only coturn H.264 coverage |
| 2 | Implementation ready; PR acceptance pending | Runtime/realtime-generation-bound opaque endpoint leases, native-only FFI create/release/H.264 push/pull controls, Dart lifecycle contract/fake tests, and no per-frame Dart API |
| 3–7 | Not started | Remain subject to the planned acceptance matrix below |

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
Future platform adapters
under that package will own capture, H.264 encoder/decoder instances, GPU
surfaces, and Flutter Texture or equivalent rendering while using the existing
native bridge by endpoint lease.

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
| Capture source and encoder | realtime_media platform adapter | Screen-share session | Stop production before encoder/capture release |
| Decoder, GPU surface, and Texture | realtime_media renderer | Viewer session | Detach decoder, then release surface and texture |
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
- a planned typed consent message and media endpoint/state extension, both
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

## Consent and signaling

Existing authenticated signaling carries offer, answer, ICE candidate, ICE
restart, and close. Phase 5 adds a dedicated, authenticated `RealtimeConsentV1`
control payload through the protocol source of truth. It is not a
`RelayDataFrame`, a video payload, or a sixth `RealtimeSignal` kind; the existing
Relay `RealtimeSignal` remains `realtime_id` + `target_device_id` + `kind` +
`revision` + bounded `payload`, with no sender field on that wire. The typed
consent payload is:

~~~text
version = 1                         # payload schema version, not Relay v2
action = REQUEST | ACCEPT | REJECT | CANCEL
purpose = SCREEN_SHARE               # typed enum, not free-form text
intent_id                            # non-empty, <= 128 bytes
sender_peer_id                       # non-empty, <= 128 bytes
realtime_id                          # non-empty, <= 128 bytes
media = SCREEN_VIDEO                 # typed enum
requires_acceptance = true
issued_at_ms
expires_at_ms                        # issued <= expires <= issued + 120 s
action_revision >= 1                 # monotonic within (intent_id, sender_peer_id)
~~~

The whole typed payload is at most 4 KiB, below the existing 256 KiB
`RealtimeSignal` payload bound. `sender_peer_id` always means the peer that owns
the screen content and originated the REQUEST; ACCEPT/REJECT/CANCEL echo that
value. The actual actor for each action is obtained from the authenticated
control connection and its peer binding, so no `peer_id` or `sender_device_id`
alias is introduced. The payload contains no bearer token, private key, or
reusable credential.

The receiver keeps at most 32 live provisional intents, with no more than one
for a given `(sender_peer_id, intent_id)`, and stores only typed metadata plus a
protected pending-offer handle. A bounded replay cache keeps at most 256 keys
per authenticated peer for five minutes; its key is
`(sender_peer_id, target_device_id, realtime_id, intent_id, action,
action_revision)`. Expiry deletes provisional state and cannot be renewed.
Replay-cache failure, duplicate or out-of-order action, expired intent, unknown
version/purpose/media, oversized payload, or a non-contiguous action revision
fails closed.

Authentication and binding checks are mandatory: the outer authenticated source
and target must match the expected peers; `sender_peer_id` must match the
authenticated content sender and the pending operation; `realtime_id` must map
to that peer and the current session generation; REQUEST alone creates
provisional state; ACCEPT/REJECT only acts on a matching, non-terminal,
non-expired REQUEST. `version`, action replay, and the local generation guard
are separate checks. The Phase 5 Relay extension will authenticate and route this
future control message but will not trust, rewrite, parse, store, or forward
media payload.

The accepted receiving flow is:

~~~text
Incoming screen-share request
  -> feature presents accept and reject
  -> user reject: close/reject without an accepted media session
  -> user accept: validate intent, sender_peer_id, realtime ID, and generation
  -> only then permit WebRTC answer and negotiation
  -> native ready: attach remote decode/render path
~~~

An incoming Offer may be retained only as bounded provisional signaling state
needed to ask the user. It must not automatically create a final accepted media
session, auto-answer, auto-display a screen, or start local capture. Stale,
duplicate, oversized, unknown, or mismatched intent actions fail closed.

The accepted sending flow is:

~~~text
User explicitly starts sharing
  -> select peer and source, obtain OS permission
  -> create ScreenShareOperation and outgoing intent
  -> receiver explicitly accepts
  -> WebRTC answer, ICE, DTLS-SRTP, and native media endpoint are ready
  -> begin actual capture and H.264 encoding
~~~

The sender must not continuously capture, encode, or queue real screen content
until all three conditions are true: explicit sender action, remote acceptance,
and WebRTC readiness. Sharing UI must visibly state that sharing is active; use
a platform capture indicator or foreground notification where available.

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

A native keyframe request is required after first-track activation, decoder
reset, source or resolution change, ICE restart, unrecoverable packet loss, or
viewer reconnect.

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
Phase 7 may adapt it using loss, RTT, encoder backlog, and queue pressure:

| Condition | Action |
| --- | --- |
| About three seconds of loss at least 5 percent, RTT at least 250 ms, or queue/encoder pressure | One degradation step: 1080p15 to 1080p10 |
| Continued degradation | Reduce bitrate by 25 percent per bounded step |
| Loss at least 10 percent or RTT at least 400 ms | Move to 720p10 |
| Ten seconds healthy with loss below 2 percent, RTT below 150 ms, and healthy queues | Recover one level only |

Statistics update outside the blocking media hot path. The planned aggregate
fields include capture, encode, sent, decode, and render FPS; resolution;
target and actual bitrate; RTT, jitter, loss; frame and keyframe counters;
codec; and selected ICE path.

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

Relay never carries RTP or media payload. It does not store SDP, ICE, intent
history, or any screen content. The future consent extension may retain only the
bounded live intent routing state required by its owner; it must not create
history. Delivery, Transfer, file resume, and RelayDataFrame remain unrelated
to the video data plane.

Development may retain the existing in-memory runtime TURN configuration.
Phase 6 replaces a production static client credential with a device-authenticated
short-lived TURN REST credential for each Realtime session. The server keeps the
shared secret only in its secret environment; the client retains the issued
credential only in session memory, never exposes it to Feature, and never
persists or logs it.

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
service, and revocation callback. Projection revoke, surface destruction,
rotation, background behavior, and permission denial fail closed and stop
production immediately.

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
