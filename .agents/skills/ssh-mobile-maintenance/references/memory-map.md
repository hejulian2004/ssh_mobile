> Last updated: 2026-09-04

# Memory Map

Route by real owning paths; never load every Domain or Feature Memory.

## Loading algorithm

1. Read the canonical Skill, then this map.
2. Collect paths named by the task; if only behavior is named, locate owners with
   read-only search.
3. From each target to the root, read every `AGENTS.md`; for a Workspace Member
   also read its `README.md` (responsibility, API, dependencies, storage,
   lifecycle, validation).
4. Load the matched Domain `overview.md` and `current-state.md`.
5. Add `architecture.md` only for structure/dependency/ownership/lifecycle/
   storage/compatibility/public-API changes; add `lessons.md` only for a matching
   diagnostic, regression, or performance task.
6. Add a listed Feature Memory, ADR, or Architecture document only when its
   route/escalation below applies; Feature Memory never replaces local contracts.

Docs-only spelling/format/link fixes that change no fact may stop at Skill, map,
and nearest contract. Governance work additionally reads the [Memory README](../../../../memory_docs/README.md)
and [maintenance rules](../../../../docs/agent/skill-memory-maintenance.md).

## Client

Default: [overview](../../../../memory_docs/client/overview.md) +
[current state](../../../../memory_docs/client/current-state.md). Add
[architecture](../../../../memory_docs/client/architecture.md) for shared
ownership/public-boundary, dependency, scope, database, storage, or compatibility
changes; add [lessons](../../../../memory_docs/client/lessons.md) only for matching
regression/performance work.

| Target or behavior | Add |
| --- | --- |
| `apps/ssh_mobile_full/**`, `apps/ssh_mobile_terminal/**`, `packages/core/**`, `packages/features/**` | Client default + nearest App/Feature contract |
| `packages/infrastructure/ssh_core/**` | Client default; architecture for Manager/Pool/Lease/public-contract changes |
| App Shell/startup/navigation/settings/logging/backup/platform | Client; [startup design](../../../../docs/STARTUP_INITIALIZATION.md) when startup changes |
| AI/Agent/Skills/LLM/tools/App AI adapters | [AI Memory](../../../../memory_docs/client/features/ai.md) + AI contract |
| SFTP UI/service/preview/cache/history/App adapters | [SFTP Memory](../../../../memory_docs/client/features/sftp.md) + SFTP contract |
| LAN discovery/pairing/share/Receiver/Web Share/App adapters | [LAN Share Memory](../../../../memory_docs/client/features/lan-share.md) + LAN contract |
| MCP server/policy/approval/console/activity/App adapters | [MCP Memory](../../../../memory_docs/client/features/mcp.md) + MCP contract |
| Telemetry/event tracking/storage/upload/Developer card | Client overview + [telemetry design](../../../../docs/数据埋点架构.md) + [ADR-033](../../../../docs/adr/ADR-033-telemetry-data-tracking-architecture.md) |

Conditional Client references: AI trace/metrics → [Agent Trace](../../../../docs/AGENT_RUN_TRACE.md);
host keys/credentials/tools/secret paths/preview security → [security regression](../../../../docs/security_manual_regression.md);
large SFTP/monitoring data → [performance acceptance](../../../../docs/PERFORMANCE_ACCEPTANCE.md);
Monitoring/System Admin integration → [integration design](../../../../docs/SYSTEM_ADMIN_MONITOR_INTEGRATION.md);
accessibility/responsive/large text → [mobile UI QA](../../../../docs/MOBILE_UI_QA.md).

Connection, Terminal, Monitoring, System Administration, Playbook, RAG, WebView,
Developer, and shared UI have no initial Feature Memory; use Client basics,
nearest contract, and conditional documents. `ssh_core` remains Client; add SDK
only when a real public interface to `network_transport`/native changes.

## SDK

Default: [overview](../../../../memory_docs/sdk/overview.md) +
[current state](../../../../memory_docs/sdk/current-state.md). Paths are
`native/network_core/**`, `packages/infrastructure/network_sdk/**`,
`packages/infrastructure/network_transport/**`,
`packages/infrastructure/ssh_mobile_network_native/**`, and `protocol/**`.
Add [architecture](../../../../memory_docs/sdk/architecture.md) for public
contract, App/native ownership, FFI, lifecycle, dependency, or wire changes;
add [lessons](../../../../memory_docs/sdk/lessons.md) for matching recovery,
ordering, routing, or crypto regressions. Transport/candidate/path/Connection/
Session/Route/Relay/direct/reconnect/resume/Delivery/Transfer/E2EE/Realtime/
WebRTC/native command-event work also reads [Transport and Routing](../../../../memory_docs/sdk/features/transport-routing.md).
Each Dart SDK package still requires its nearest README/AGENTS; Rust currently
has no nested contract, so use root rules, SDK Memory, code/tests, and exact ADR.

## Backend and Front

- `relay/**` → [Backend overview](../../../../memory_docs/backend/overview.md),
  [current state](../../../../memory_docs/backend/current-state.md), and
  [Relay README](../../../../relay/README.md). Enrollment/auth/admin/hub/
  WebSocket lifecycle/Compose/Caddy are Backend. Wire/proofs/opaque data,
  Session route, or Client enrollment also add SDK; an admin response consumed by
  React also adds Front.
- `front/**` → [Front overview](../../../../memory_docs/front/overview.md),
  [Front README](../../../../front/README.md), and nearest `AGENTS.md`. Add
  [Front UI Architecture](../../../../docs/architecture/FRONT_ADMIN_UI_ARCHITECTURE.md)
  for shared UI primitives, Design System, component ownership, page/state/responsive
  architecture, form controls, or cross-page refactoring. Pure presentation does not
  add Client; API/auth/session changes add Backend.

## Cross-domain and escalation

An unchanged public-API call does not load the provider Domain; changing shape,
semantics, errors, state, lifecycle, or ownership does. Union all real touched
Domains. `network_transport`/native handles are SDK; AppRuntime composition or
App Shell result correlation is SDK + Client. Relay API/deployment is Backend;
wire/session/opaque handshake/E2EE is Backend + SDK + exact ADR. Admin DTO/API is
Front + Backend. `protocol/**` is SDK + Backend, plus Client when Feature-facing.
Tests/docs follow the behavior's Domain, not their physical directory.

Read [Module Dependency](../../../../docs/architecture/MODULE_DEPENDENCY.md) for
dependency boundaries, [Resource Ownership](../../../../docs/architecture/RESOURCE_OWNERSHIP.md)
for owner/create/dispose changes, and [Compatibility Inventory](../../../../docs/architecture/COMPATIBILITY_MIGRATION_INVENTORY.md)
for bridge changes. The broad [Modular Refactor Plan](../../../../docs/architecture/MODULAR_REFACTOR_PLAN.md)
is conditional, not a default input.

For wire/API, Session/Connection/Route lifetime, path selection, recovery,
Delivery ordering, crypto, Relay/direct, WebRTC, or native task ownership, read
only the precise ADR. Use complete names for [ADR-030 file resume](../../../../docs/adr/ADR-030-file-resume.md),
[ADR-011 transfer-session route dispatch](../../../../docs/adr/ADR-011-transfer-session-route-dispatch.md),
and [ADR-033 telemetry](../../../../docs/adr/ADR-033-telemetry-data-tracking-architecture.md).

## Quick routes

- Flutter UI → Client default + local contract; add Client architecture only for shared ownership/API.
- Rust/transport → SDK default + Transport and Routing + exact ADR; add Client only for public FFI/Dart changes.
- Backend API → Backend default + Relay README; add Front for admin consumers, SDK for wire/device changes.
- Front Admin → Front overview/README/AGENTS; add Front UI Architecture for design system/shared UI/forms; add Backend for API/auth/session changes.
- Client↔SDK → both defaults + architecture, both contracts, dependency/resource docs, exact ADRs.
- Screen Share / Realtime Media (`feature_screen_share`, `realtime_media`, or
  `network-webrtc`) → Client + SDK defaults and architecture, Transport and
  Routing, Module Dependency, Resource Ownership, Compatibility Inventory,
  `ADR-BUSINESS-RECOVERY-V2`, ADR-016/020/021/024/026 and ADR-034. Read the
  protocol source/contract (`protocol/RELAY_V2_CONTRACT.md` and the owning
  schema/generated-artifact contract) plus every nearest Feature/SDK/App
  `AGENTS.md`/`README.md` when the boundary changes. Add Backend overview/current
  state and Relay README only for Relay signaling/consent or TURN credential
  issuance; add ADR-033 and telemetry design only for telemetry work.
- Relay architecture → Backend + SDK architecture/current + Transport and Routing + Relay README + exact ADRs; add Front only for dashboard/API.
- Telemetry → ADR-033 + [telemetry design](../../../../docs/数据埋点架构.md) + Client/Backend/Front overviews + `contracts/telemetry/`; add owning contracts for UI/storage.

Code/tests remain current-behavior truth; Accepted ADRs remain decision truth.
