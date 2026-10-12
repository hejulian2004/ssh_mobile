Last updated: 2026-10-12

# Direct Realtime Signal V2

Authority: [ADR-036](../docs/adr/ADR-036-direct-screen-share-signaling.md).

The authenticated QUIC `SMCH` and TCP/WebSocket `SMGF` reliable carrier frames
add kind **6**, `RealtimeSignal`. Existing kinds and Network Protocol V2 remain
unchanged. The entire payload is at most 48 KiB, matching the QUIC channel bound.
Relay Data cannot carry this frame kind.

Payload layout:

```text
magic                 5 bytes: ASCII SMRS2
sender_session_length 2 bytes: unsigned big-endian, 1..128
sender_session_id     UTF-8, exactly sender_session_length bytes
encrypted_signal      current application E2EE envelope (SME1)
```

The exact prefix through `sender_session_id` is AEAD associated data. Plaintext
is the existing `relay.v2.RealtimeSignal` protobuf shape, used only as a native
container; it is not submitted to Relay. `request_id` is a nonzero placeholder,
`source_device_id` is the authenticated local author, target is the selected
peer, revision is positive, and payload is the existing shared-session-bound
`network.v2.RealtimeSignalEnvelope`. No new protobuf or generated descriptor is
introduced.

Sender releases its Direct PathLease after each send. The encoded plaintext
container is limited to 48 KiB minus 512 bytes for header/encryption overhead.
Payloads exceeding the
direct bound fail closed; they are not fragmented or retried through another
carrier. Direct errors do not silently choose an unauthorized fallback.

Receiver requires Direct authorization, current admitted connection and exact
authenticated remote Session binding. AEAD uses that session's crypto alias,
including normal nonce replay protection. Decrypted source must equal the
carrier-authenticated peer and target must equal local device identity. Check
current local session again after decryption. Malformed UTF-8/protobuf,
lengths, identities, revisions, old roots and old sessions cannot reach consent
or media state. SDP and ICE remain native-only and are never logged.

After these checks, the existing native provisional/claim/consent state machine
processes Offer, Answer, ICE, Close and typed screen-share actions. No incoming
Offer alone can create an Answer or start capture. No media bytes use this
frame, Delivery or Transfer.
