#!/usr/bin/env bash
#
# relay_v2_contract.sh — cross-language relay v2 contract check.
#
# Entry point for the Rust/Go relay v2 codec tests and the protocol-v2-contract
# CI job. Verifies that the frozen golden fixtures in protocol/relay_v2_testdata/
# are current by deterministically regenerating them and diffing against what is
# committed, then runs the optional toolchain gates that are available:
#
#   1. deterministically check golden fixtures without mutating the worktree (REQUIRED)
#   2. verify the single approved additive source field against the original
#      frozen descriptor through the shared Go helper
#   3. buf lint/breaking are run by the CI protocol job with pinned tools
#
# Exit code 0 = contract intact; non-zero = drift or gate failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TESTDATA="$REPO_ROOT/protocol/relay_v2_testdata"
PROTO="$REPO_ROOT/protocol/proto/relay/v2/relay_v2.proto"
GENERATOR="$TESTDATA/generate_fixtures.py"

cd "$REPO_ROOT"

echo "== relay v2 contract check =="

# --- 1. Golden fixtures must be current (deterministic non-mutating check) ---
python3 "$GENERATOR" --check
echo "golden fixtures: current (23 fixtures)"

# --- Semantic sanity: manifest shape ---
python3 - <<'PY'
import json, sys
with open("protocol/relay_v2_testdata/manifest.json") as f:
    m = json.load(f)
assert m["schema_version"] == 2, "manifest schema_version != 2"
assert len(m["fixtures"]) == 23, "expected 23 fixtures, got %d" % len(m["fixtures"])
assert m["constants"]["RELAY_V2_VERSION"] == 2
print("manifest: OK (%d fixtures)" % len(m["fixtures"]))
PY

# --- Frozen wire shape: reject the known PR #48 additions explicitly. ---
python3 - <<'PY'
from pathlib import Path

proto = Path("protocol/proto/relay/v2/relay_v2.proto").read_text(encoding="utf-8")

def message_body(name: str) -> str:
    marker = f"message {name} {{"
    start = proto.index(marker) + len(marker)
    end = proto.index("}\n", start)
    return proto[start:end]

offer = message_body("ConnectivityOffer")
signal = message_body("RealtimeSignal")
data_frame = message_body("RelayDataFrame")
assert "target_device_id = 7" not in offer, "ConnectivityOffer target field drift"
assert "source_device_id = 7" in signal, "RealtimeSignal source field missing"
assert "sender_device_id = 7" not in signal, "RealtimeSignal sender field drift"
assert "ready = 14" not in data_frame, "RelayDataFrame ready oneof drift"
assert "message RelayDataReady" not in proto, "RelayDataReady protobuf drift"
print("forbidden Relay V2 additions: absent")
PY

# --- Scoped Relay Bootstrap V1 retirement guards ---
if command -v rg >/dev/null 2>&1; then
  if rg -n --glob '!scripts/bash/contracts/relay_v2_contract.sh' '/v1/devices/(enroll|refresh)' \
    relay \
    packages/infrastructure/network_sdk \
    packages/features/feature_lan_share \
    native/network_core \
    apps \
    scripts; then
    echo "Found forbidden Relay Bootstrap V1 endpoint references" >&2
    exit 1
  fi
  if rg -n --glob '!scripts/bash/contracts/relay_v2_contract.sh' 'POST\\n/v1/devices/refresh' \
    relay packages native apps scripts; then
    echo "Found forbidden Relay Bootstrap V1 refresh transcript references" >&2
    exit 1
  fi
  echo "Relay Bootstrap V1 retirement guards: PASS"
fi

# --- 2. Descriptor compatibility against the original frozen proto revision. ---
descriptor_status="NOT RUN (protoc unavailable)"
if command -v protoc >/dev/null 2>&1; then
  frozen_commit="6ec194bb3a66a748215d3abc11d6da84bd329619"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  mkdir -p "$tmp_dir/protocol/proto/relay/v2"
  git show "${frozen_commit}:protocol/proto/relay/v2/relay_v2.proto" \
    > "$tmp_dir/protocol/proto/relay/v2/relay_v2.proto"
  protoc --proto_path=protocol \
    --descriptor_set_out="$tmp_dir/current.desc" \
    protocol/proto/relay/v2/relay_v2.proto
  (
    cd "$tmp_dir"
    protoc --proto_path=protocol \
      --descriptor_set_out=frozen.desc \
      protocol/proto/relay/v2/relay_v2.proto
  )
  if ! command -v go >/dev/null 2>&1; then
    echo "relay v2 descriptor: NOT RUN (go unavailable for shared helper)" >&2
    exit 1
  fi
  (cd "$REPO_ROOT/relay" && go run ./cmd/relay-v2-descriptor-check \
    --current "$tmp_dir/current.desc" \
    --frozen "$tmp_dir/frozen.desc")
  echo "relay v2 descriptor: additive source_device_id=7 compatible with frozen revision ${frozen_commit}"
  descriptor_status="additive source_device_id=7 compatible with frozen revision ${frozen_commit}"
else
  echo "NOT RUN: protoc unavailable; frozen descriptor equality requires the CI protocol job"
fi

echo "== relay v2 contract check: PASS (fixture/shape gates; descriptor ${descriptor_status}) =="
