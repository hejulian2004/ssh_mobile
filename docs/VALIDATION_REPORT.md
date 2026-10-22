> Last updated: 2026-10-22

# Network V2 Validation Report

This file records the closure run for branch
`agent/network-v2-final-20260819`. It is a historical snapshot. Current gates
live at `scripts/bash/contracts/network_v2_acceptance.sh`,
`scripts/bash/contracts/relay_v2_contract.sh`,
`scripts/bash/e2e/client_backend_e2e.sh`, and
`scripts/bash/ci/full_test.sh`. The commands later in this file are the entry
points used for that SHA.

`FINAL_CLOSURE_BASE_SHA: 926967e08ed2abb638bf13596fa4d25595c75da9`
`CODE_VALIDATION_HEAD: 2253282f3afa7dc64ff38e5604eb2f272518969b`
`CI_HEAD: 2253282f3afa7dc64ff38e5604eb2f272518969b`
`PR_HEAD_SHA: 2253282f3afa7dc64ff38e5604eb2f272518969b (code/CI head before this docs sync)`
`GitHub CI RUN: 32639926098 — all listed checks PASS for CI_HEAD`

## Contract and owner closeout

`protocol/contract_tests/acceptance_matrix.json` records 71/71 cases as
`covered`. That run used `bash scripts/network_v2_acceptance.sh strict` and
preserved the frozen Relay V2 wire shape: target-less
`ConnectivityOffer`, request/attempt correlation, fail-closed Resolve status,
and separate Control/Data channels.

The final-fix owner tests add concrete coverage for the Stage B transaction and
the Stage C fallback: one authoritative Resolve, one Offer enqueue, a recorded
Direct failure, one Reserve, and the same Resolve snapshot used by the
connectivity coordinator. The lifecycle regressions also prove cancellation and
overall timeout cleanup do not poison the next admission. All instrumentation
is in independent test files; no production observer, hook, protobuf fixture,
public Dart/Rust contract, or FFI ABI was changed.

## Checks run for the final-fix working tree

- `python3 -m json.tool protocol/contract_tests/acceptance_matrix.json` — passed.
- `bash scripts/network_v2_acceptance.sh strict` — passed: the initial
  17-case contract inventory had 3 test-defined architecture-guard skips; the
  final strict pass ran all 17 cases, plus the selected Rust/Go/Dart owner
  suites and concrete RelayControlClient integration selector.
- `cargo fmt --all -- --check` — passed.
- `cargo check --workspace --locked` — passed.
- `cargo clippy --workspace --all-targets --locked -- -D warnings` — passed.
- `cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked` —
  passed: 63/63, including healthy-path Offer suppression, bounded active
  `NOT_READY` retry, lifecycle cancellation/timeout reconnect isolation, and
  Stage C order/count evidence.
- `cargo test -p network-relay --locked` — passed: 45/45.
- `cargo test -p network-relay --features test-support --test relay_control_client_integration --locked -- --test-threads=1` — passed: 7/7.
- `cargo test --workspace --locked` — passed: all workspace crates.
- Go fmt/test/race/vet/govulncheck — passed; SDK, transport, native FFI, and
  app static/unit no-coverage selectors — passed.
- `bash scripts/full_test.sh --no-bootstrap --with-coverage --serial` —
  attempted; front/native/SDK/Relay/protocol/workspace/app-static stages passed,
  but the App coverage shard stayed at `loading` without a Flutter VM Service in
  WSL. The run was stopped and is recorded as an environment gap, not a pass.
- `CLIENT_BACKEND_E2E_STORAGE=memory bash scripts/client_backend_e2e.sh strict`
  and the MySQL equivalent — both passed.
- Exact protocol commands (`protoc`, `bash scripts/relay_v2_contract.sh`,
  `buf lint`, scoped `buf breaking`) — passed.
- `git diff --check` — passed.
- GitHub Actions run `32639926098` — every listed check passed for the final
  `CI_HEAD`, including App coverage/static/unit shards, Android, Windows,
  macOS, iOS, both client-backend E2E modes, and all owner quality jobs.

## Not run on this host

- Physical mobile lifecycle and deployment evidence still require native or
  service hosts; the final Windows/macOS/iOS/Android CI build jobs passed.
- Real multi-host Relay deployment, physical-device lifecycle, and broader
  transport fault injection require external services/devices; local Stage C
  order/count evidence and RelayData owner coverage are complete.
- The final CI App coverage pass is separately labeled CI evidence; it does not
  turn the WSL aggregate Flutter loading stall into a Linux local PASS.
