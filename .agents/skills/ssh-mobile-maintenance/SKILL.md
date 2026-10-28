---
name: ssh-mobile-maintenance
description: Maintain and debug SSH Mobile (Flutter/Dart, Rust SDK, Relay/Admin, React, tests, docs, and Agent guidance).
---

> Last updated: 2026-10-23

# SSH Mobile Maintenance

## Entry and ownership

For every non-trivial task: inspect `git status`, preserve unrelated work, read
the [Memory Map](references/memory-map.md), locate real owning paths, then read
each nearer `AGENTS.md` and Workspace Member `README.md`. Load only the Domain,
Feature, ADR, and Architecture documents selected by the map. Code/tests are
current-behavior truth; Accepted ADRs are decision truth; package contracts are
local edit/ownership truth. Governance is in
[`docs/agent/skill-memory-maintenance.md`](../../../docs/agent/skill-memory-maintenance.md).

The repository is in active development: migrate callers when changing a
contract, preserve compatibility bridges until their inventory permits removal,
and do not invent a protocol/version rule absent an owning ADR or contract.

## Scope and safety

For local runtime log collection/query and reproduction, use
[`ssh-mobile-logs`](../ssh-mobile-logs/SKILL.md). Its tooling reuses the public
logging/redaction boundary; it does not authorize unrelated code changes.

- Classify the request (explain/review, diagnose, implement, monitor). A review
  or diagnosis does not receive an unsolicited implementation.
- Identify every touched Domain/owner and public caller before editing. An
  unchanged API call does not load or modify the provider Domain; changes to its
  shape, semantics, errors, state, lifecycle, or ownership do.
- Keep the smallest correction inside existing owners. Do not add an abstraction,
  database, protocol path, singleton, dependency, or compatibility layer
  without evidence the current boundary cannot own it.
- App/Module/Route resources have explicit owners and release paths. Features
  use injected Ports/Capabilities and release only their leases/subscriptions;
  they never close App-owned sessions, databases, native handles, or runtimes.
- Feature packages use public package entry points, never another package's
  `/src/` or copied implementations. `ssh_core` is Client infrastructure; the
  network facade/FFI/Rust/wire path is SDK. Terminal-only remains a restricted
  composition slice with no AI/RAG/MCP/WebView/LAN/SFTP business implementation.
- Structured data stays in its owning Feature/Core database, App diagnostics
  stay separate, and production database-open failures never fall back silently
  to memory. Secrets and user-private data stay in secure storage and never in
  source, logs, tests, fixtures, screenshots, traces, exports, Skill, or Memory.
- Remote writes/uploads/renames/deletes/downloads and sensitive reads require
  existing approval bound to immutable target/action snapshots; stale snapshots,
  hidden tools, MCP review failures, destructive commands, secret paths, and
  unsafe WebView targets fail closed. Keep redaction, host-key, bounded SFTP,
  receive-sandbox, transport-auth, Delivery, Session-routing, and E2EE rules.

## Test-first and editing

Observable or automatable behavior uses Red → Green → Refactor at the lowest
reasonable layer. Bugs start with a failing regression, new behavior with an
observable failure, and risky uncovered code with a characterization test; do
not weaken/skip failures or add test-only production hooks. Pure documentation,
formatting, generated output, behavior-free configuration, and visual-only
changes are the documented exceptions. Detailed TDD and owner focus are in
[Maintenance Workflow](references/workflow.md); command selection is in
[Validation](references/validation.md).

Use `rg`/`rg --files`; inspect implementations, callers, and focused tests before
ownership/API edits. Edit generator inputs, not only generated output, and review
regenerated diffs. Keep diagnostics behind the injected logger and user text in
the localization contract. Hand-written production files over 500 lines need a
responsibility-based split, never numbered chunks or gratuitous over-splitting.
Tests/fixtures use `test/` or `tests/` (Go `_test.go`, Rust `#[cfg(test)]` or
`src/tests`, TypeScript `.test`/`.spec` are native exceptions). Use deterministic
fixtures without real credentials, networks, or user machines; preserve
cancellation, timeout, ordering, backpressure, bounded allocation, and
fail-closed paths.

## Documentation and validation

Update only the canonical owner: Skill/routing for Agent rules, `memory_docs/`
for costly current facts, package `README.md`/`AGENTS.md` for local contracts,
ADR for rationale, Architecture for complete design, and Git for history. Do
not append timelines, temporary failures, test results, machine paths, or full
ADR/Architecture copies to Memory. Every maintained Markdown change updates its
leading date marker. `.agents/skills/` is the only Skill source; do not create a
Claude mirror.

Run checks selected for the touched owner/risk, never claim an unrun check, and
always run `git diff --check` plus final status/diff review. The commit Skill
formats changed files but does not rerun implementation tests. Keep paired Bash/
PowerShell scripts behaviorally aligned and use the actual host toolchain.

## PR/CI handoff

When the user asks to create, update, submit, or publish a PR:

1. Inspect the full worktree; run `git diff --check`, required formatting, and
   focused owner checks requested or needed for a safe handoff.
2. Run aggregate local CI only when the user explicitly mentions/requests it:
   `scripts/bash/ci/full_test.sh` on Linux/WSL or
   `scripts/powershell/ci/full_test.ps1` in native PowerShell 7. A GAP, timeout,
   failure, omission, or unrun check is never PASS.
3. After minimum preflight, the requested branch may be committed, pushed, and
   opened (prefer draft) so GitHub Actions runs its independent parallel jobs.
4. Immediately after every PR push/open, bind a background watcher to the exact
   commit/run (for example, `gh run watch <run-id> --exit-status > <temp-log>
   2>&1 &`; discover a not-yet-created run with `gh run list --commit <sha>`).
   Keep its PID/log temporary and never commit them.
5. If the watcher reports failure, read only the failed jobs with `gh run view
   <run-id> --log-failed`, diagnose the first actionable cause, apply the
   smallest in-scope fix, run permitted focused/static checks, commit/push, and
   restart the watcher for the new SHA. Repeat until required checks pass or a
   concrete blocker needs user input; do not hide, skip, or weaken a failure.
6. Never auto-approve or merge. The user alone decides whether merging is
   allowed; report the final watcher state and any blocker.

The initial PR write starts remote validation; it is not merge approval. After
source/test/dependency/structure/CI-scope changes, rerun only checks the user
requests and update the handoff. Report outcome first, then files, commands,
gaps, and residual risk. Commit only when requested/approved; stage explicit
paths and never include unrelated work, secrets, caches, or temporary output.
