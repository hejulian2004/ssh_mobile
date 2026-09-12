> Last updated: 2026-09-12

# Client Overview

Client contains the Flutter Apps, Core/Feature packages, and App-scoped SSH
infrastructure:

- `apps/ssh_mobile_full/`: complete product and composition root;
- `apps/ssh_mobile_terminal/`: restricted Terminal-only slice;
- `packages/core/`: shared contracts/UI, Telemetry runtime
  (`app_core/lib/src/telemetry/`), and Connection ownership;
- `packages/features/`: Feature implementations, including Developer telemetry;
- `packages/infrastructure/ssh_core/`: SSH contracts/runtime boundary.

Client Telemetry follows [telemetry design](../../docs/数据埋点架构.md) and
[ADR-033](../../docs/adr/ADR-033-telemetry-data-tracking-architecture.md): the
catalog is validated from `contracts/telemetry/events.yaml` and
`error_codes.yaml`; `syncState` (pending/synced/rejected) is orthogonal to
`logicalDeletedAt` and uses non-loss FIFO retention; Developer exposes storage
health/overflow and exact replay preserving `eventId`, `occurredAt`, `sessionId`,
and `traceId`. Recording is off until App Scope confirms a valid Relay
enrollment; a disabled Relay gate prevents new event rows and cache writes,
while `uploadEnabled=false` only pauses upload scheduling.

Network internals route to the [SDK domain](../sdk/overview.md); Go Relay and
React administration route to Backend/Front. For package work, read the nearest
`AGENTS.md` and `README.md`; they are local contracts, while this Memory keeps
only costly cross-package facts. The root README owns setup/configuration and
user-facing behavior.

## Realtime screen-share entry

PR74 connects the existing native screen-video capability to a user-facing
vertical slice. LAN supplies only a peer-scoped `LanShareScreenSharePort`;
App Shell owns the entry coordinator, global incoming host, peer arbitration,
route/session lease, and platform presenter. The screen-share Feature owns
consent/business state and opaque media-port coordination only. Camera/general
video is outside this slice; real Windows/Android capture and render remain
hardware acceptance evidence, not a CI claim.
