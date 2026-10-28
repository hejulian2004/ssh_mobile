> Last updated: 2026-10-23

# SSH Mobile Relay Admin & Observability Console

This directory contains the standalone React + Vite + TypeScript administration
console for SSH Mobile Relay and the Telemetry & Observability suite. It owns the browser UI only; the Go service in
`../relay/` owns authentication, device enrollment, optional Relay MySQL/Redis
state, Relay sessions, isolated Analytics telemetry storage, and the v2
control/data WebSocket protocol.

## Architecture and Governance

- Workspace constraints: [`AGENTS.md`](AGENTS.md)
- Complete UI architecture and Design System: [`../docs/architecture/FRONT_ADMIN_UI_ARCHITECTURE.md`](../docs/architecture/FRONT_ADMIN_UI_ARCHITECTURE.md)
- Memory reference: [`../memory_docs/front/overview.md`](../memory_docs/front/overview.md)
- UI baseline entry points:
  - Primitives: `src/components/ui.tsx`
  - Style rules: `src/styles.css`
  - Shell and navigation: `src/layout/app-shell.tsx`

## Directory Ownership

```text
src/
├── api/             # Typed API adapters and HTTP error normalization
├── components/      # Generic cross-feature Admin UI primitives
├── features/        # Feature pages and feature-scoped components
│   ├── access/      # Enrollment Token management and rotation
│   ├── auth/        # Administrator login gate
│   ├── devices/     # Device catalog, presence, and revocation
│   ├── overview/    # Relay runtime metrics and signal rail
│   └── telemetry/   # Observability dashboard, explorer, logs, and settings
├── hooks/           # TanStack Query hooks, query keys, and cache policies
├── layout/          # AppShell, persistent navigation, and session header
├── schemas/         # Zod runtime validation DTO contracts
└── utils/           # Time, duration, and string formatters
```

## Development

```sh
cp .env.example .env
npm ci
npm run dev
```

Vite reads `FRONT_DEV_PORT` and `RELAY_DEV_API_ORIGIN` from `.env`, then proxies
`/api/admin/v1`, `/api/v1`, `/healthz`, and `/v2` to the configured local Relay origin. Production
requests use relative paths through Caddy, so the browser keeps the
HttpOnly administrator session same-origin.

The browser API is versioned under `/api/admin/v1`. Overview and Devices use
separate response DTOs; the Overview endpoint is polled every three seconds,
while the device list refreshes every fifteen seconds. The Telemetry Suite provides:
- Telemetry Overview (`/api/admin/v1/telemetry/overview`): ingest metrics, error counts, and
  receivedAt trends (UTC hourly for `1d`/`24h`, UTC daily for `7d`/`30d`). Business and
  error-free-session rates use explicit denominators; a zero denominator renders `No data`.
- Event Explorer (`/api/admin/v1/telemetry/events`): filterable event log with property viewer.
- Diagnostic Stream (`/api/admin/v1/telemetry/diagnostics`): periodically refreshed diagnostic log feed backed by a Redis hot cache / MySQL fallback.
- Policy & Retention Settings (`/api/admin/v1/telemetry/settings`): dynamic policy configuration and retention policies.

The legacy `/api/*` dashboard routes are intentionally not supported.

## Validation

```sh
npm run typecheck
npm run typecheck:tests
npm run lint
npm run test:run
npm run build
```

From the repository root, run `bash scripts/bash/contracts/admin_api_contract.sh` to replay
responses emitted by the real Go administrator handlers through the production
Front request client and Zod schemas. The fixture is generated in a private
temporary directory for each run, redacts credentials, and is never committed.

The Docker image is built by `Dockerfile` and serves the Vite output through
Nginx. Do not store administrator sessions or Enrollment Tokens in browser
storage or URLs.

## Local development diagnostics

Runtime output and agent queries follow the [local diagnostic contract](../docs/agent/runtime-diagnostics.md).
App composition roots inject `app_diagnostics` through public Core logging
contracts; Feature dependencies remain unchanged. Development tools own launched
processes and file queries, and are never imported by runtime packages.