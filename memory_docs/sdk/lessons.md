> Last updated: 2026-10-28

# SDK Lessons

- ConnectionSession is 1:1 with a transport Connection; new connection means new
  SessionId/Noise root and loss destroys the session. See [lifecycle ADR](../../docs/adr/ADR-CONNECTION-LIFECYCLE-V2.md).
- Queue acceptance, native completion, transport ACK, and application ACK prove
  different facts. `SendFile` acceptance is not transfer dispatch: hashing the
  whole file or selecting a route inside the command worker makes a short
  client acceptance timeout mark media failed before any `TransferFailed`
  exists. See [Delivery ADR](../../docs/adr/ADR-010-delivery-recovery-layer.md)
  and [Realtime correlation ADR](../../docs/adr/ADR-026-realtime-command-completion-correlation.md).
- Active receive state is not processed dedup history; TTL/LRU must not prune
  in-flight or ordered-buffered work ([active delivery ADR](../../docs/adr/ADR-025-active-delivery-state-lifetime.md)).
- Delivery resumes by MessageId/channel state; Transfer resumes by
  `transfer_id` + `confirmed_offset` on a fresh session
  ([business recovery ADR](../../docs/adr/ADR-BUSINESS-RECOVERY-V2.md)).
- Noise transcript hash is context, not secret root material
  ([E2EE ADR](../../docs/adr/ADR-028-forward-secret-session-e2ee.md)). Relay
  forwards opaque stages and never owns plaintext, RootSeed, or Application Root.
- `PathHandle`/runtime projection is not a carrier owner: `PeerPathManager` owns
  paths, business code holds `PathLease`, and hard close closes streams bound to
  an inactive lease.
- Passive inbound is not reconnect. Preserve maintenance only when explicitly
  enabled; Direct recovery waits for ready Relay so it cannot interrupt healthy
  Relay/Realtime.
- Test instrumentation stays in independent tests; no `#[cfg(test)]` production
  hooks/fields/observers. Fixtures may use existing diagnostic/read-only APIs.
- Move a WSL failure to native Windows PowerShell 7 or CI only with evidence of
  an environment/toolchain gap (for example no Flutter VM Service). Product or
  test failures must be fixed; Windows evidence remains separately labeled.
