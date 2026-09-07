#!/usr/bin/env bash

# Collect the SDK coverage gate independently from the daily regression gate.
# Dart package coverage covers the public Dart/native facades. Rust coverage
# covers the public native SDK crates; network-core and the Relay implementation
# remain internal engines and are reported separately by the Rust workspace gate.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
MINIMUM="${SDK_COVERAGE_MINIMUM:-90}"
DART_TIMEOUT="${SDK_DART_COVERAGE_TIMEOUT:-10m}"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ssh-mobile-sdk-coverage.XXXXXX")"
KEEP_ARTIFACTS="${SDK_KEEP_COVERAGE_ARTIFACTS:-0}"
RUST_SDK_PACKAGES=(
  network-ffi
  network-identity
  network-nat
  network-protocol
  network-quic
  network-relay-proto
  network-transfer
  network-transport
  network-webrtc
)

cleanup() {
  if [[ "$KEEP_ARTIFACTS" == '1' ]]; then
    printf 'SDK coverage artifacts retained at %s\n' "$RUN_DIR"
  else
    rm -rf "$RUN_DIR"
  fi
}
trap cleanup EXIT

if ! [[ "$MINIMUM" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "SDK_COVERAGE_MINIMUM must be numeric: $MINIMUM" >&2
  exit 64
fi
for command_name in dart cargo cargo-llvm-cov timeout; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required for SDK coverage." >&2
    exit 69
  fi
done

run_dart_package() {
  local package_name="$1"
  local package_dir="$2"
  local coverage_file="$3"
  shift 3
  local -a test_targets=("$@")
  local raw_coverage_dir="$RUN_DIR/${package_name}-raw"

  printf '\n[Dart SDK] %s\n' "$package_name"
  printf 'Tests: %s\n' "${test_targets[*]}"
  mkdir -p "$raw_coverage_dir"
  if ! (
    cd "$package_dir" || exit 1
    timeout "$DART_TIMEOUT" \
  dart test --coverage="$raw_coverage_dir" --concurrency=1 \
        --reporter compact "${test_targets[@]}"
    dart run coverage:format_coverage \
      --lcov --in="$raw_coverage_dir" --out="$coverage_file" \
      --packages="$ROOT_DIR/.dart_tool/package_config.json" \
      --report-on=lib --package="$package_dir"
  ); then
    echo "Dart SDK tests failed for $package_name." >&2
    return 1
  fi
}

dart_coverage() {
  local package_name="$1"
  local profile="$2"
  awk -v package_name="$package_name" '
    function in_scope(path) {
      return (path ~ /^lib\// || path ~ ("^package:" package_name "/") ||
        path ~ ("/packages/infrastructure/" package_name "/lib/")) &&
        path !~ /(^|\/)third_party\// && path !~ /\.g\.dart$/
    }
    /^SF:/ {
      source = substr($0, 4)
      scoped = in_scope(source)
      found = 0
      hit = 0
    }
    /^LF:/ { if (scoped) found += substr($0, 4) }
    /^LH:/ { if (scoped) hit += substr($0, 4) }
    /^end_of_record/ {
      if (scoped) {
        total_found += found
        total_hit += hit
      }
      scoped = 0
    }
    END {
      if (total_found == 0) exit 65
      printf "%d/%d %.2f%%\n", total_hit, total_found, 100 * total_hit / total_found
    }
  ' "$profile"
}

report_dart_misses() {
  local package_name="$1"
  local profile="$2"
  awk -v package_name="$package_name" '
    function in_scope(path) {
      return (path ~ /^lib\// || path ~ ("^package:" package_name "/") ||
        path ~ ("/packages/infrastructure/" package_name "/lib/")) &&
        path !~ /(^|\/)third_party\// && path !~ /\.g\.dart$/
    }
    /^SF:/ { source = substr($0, 4); scoped = in_scope(source); misses = "" }
    /^DA:/ {
      if (scoped) {
        split(substr($0, 4), fields, ",")
        if ((fields[2] + 0) == 0) misses = misses (misses == "" ? "" : ", ") fields[1]
      }
    }
    /^end_of_record/ {
      if (scoped && misses != "") print "Uncovered " source ": " misses
      scoped = 0
    }
  ' "$profile"
}

network_sdk_dir="$ROOT_DIR/packages/infrastructure/network_sdk"
network_transport_dir="$ROOT_DIR/packages/infrastructure/network_transport"
realtime_media_dir="$ROOT_DIR/packages/infrastructure/realtime_media"
native_sdk_dir="$ROOT_DIR/packages/infrastructure/ssh_mobile_network_native"

run_dart_package network_sdk "$network_sdk_dir" "$RUN_DIR/network-sdk.lcov" \
  test/network_sdk_contract_test.dart \
  test/network_v2_contract_test.dart \
  test/network_v2_facade_test.dart \
  test/network_models_boundaries_test.dart \
  test/realtime_test.dart
run_dart_package network_transport "$network_transport_dir" "$RUN_DIR/network-transport.lcov" \
  test/event_mux_test.dart \
  test/network_boundary_test.dart \
  test/network_runtime_test.dart \
  test/transport_contract_test.dart
run_dart_package realtime_media "$realtime_media_dir" "$RUN_DIR/realtime-media.lcov" \
  test/realtime_media_lifecycle_test.dart \
  test/realtime_media_public_contract_test.dart
run_dart_package ssh_mobile_network_native "$native_sdk_dir" "$RUN_DIR/native-sdk.lcov" \
  test/ssh_mobile_network_native_test.dart \
  test/protocol_event_matrix_test.dart \
  test/protocol_event_matrix_events_test.dart

dart_total_found=0
dart_total_hit=0
for package_name in network_sdk network_transport realtime_media ssh_mobile_network_native; do
  case "$package_name" in
    network_sdk) profile="$RUN_DIR/network-sdk.lcov" ;;
    network_transport) profile="$RUN_DIR/network-transport.lcov" ;;
    realtime_media) profile="$RUN_DIR/realtime-media.lcov" ;;
    ssh_mobile_network_native) profile="$RUN_DIR/native-sdk.lcov" ;;
  esac
  coverage_line="$(dart_coverage "$package_name" "$profile")" || {
    echo "Unable to calculate Dart coverage for $package_name." >&2
    exit 65
  }
  printf 'Dart %s line coverage: %s\n' "$package_name" "$coverage_line"
  package_total="${coverage_line##* }"
  if ! awk -v value="${package_total%%%}" -v minimum="$MINIMUM" 'BEGIN { exit !(value + 0 >= minimum + 0) }'; then
    echo "Dart SDK coverage for $package_name is below ${MINIMUM}%." >&2
    report_dart_misses "$package_name" "$profile"
    exit 1
  fi
  package_counts="${coverage_line%% *}"
  package_hit="${package_counts%%/*}"
  package_found="${package_counts##*/}"
  dart_total_hit=$((dart_total_hit + package_hit))
  dart_total_found=$((dart_total_found + package_found))
done

dart_total_percent="$(awk -v hit="$dart_total_hit" -v found="$dart_total_found" 'BEGIN { printf "%.2f", 100 * hit / found }')"
printf 'Dart SDK aggregate line coverage: %s/%s %s%%\n' \
  "$dart_total_hit" "$dart_total_found" "$dart_total_percent"

rust_profile="$RUN_DIR/rust-sdk.lcov"
printf '\n[Rust SDK] public native crates\n'
printf 'Scope: network-core implementation is excluded; public crates are network-ffi, network-identity, network-nat, network-protocol, network-quic, network-relay-proto, network-transfer, network-transport, network-webrtc.\n'
rust_package_args=()
for package_name in "${RUST_SDK_PACKAGES[@]}"; do
  rust_package_args+=(--package "$package_name")
done
if ! (
  cd "$ROOT_DIR/native/network_core" || exit 1
  cargo llvm-cov "${rust_package_args[@]}" --locked --all-features --no-fail-fast \
    --lcov --output-path "$rust_profile"
); then
  echo 'Rust SDK tests or coverage collection failed.' >&2
  exit 1
fi

rust_coverage="$(awk -v minimum="$MINIMUM" '
  function selected(path, crate) {
    return path ~ ("/crates/" crate "/") &&
      crate != "network-core" && crate != "network-relay" &&
      path !~ /(^|\/)target\// && path !~ /(^|\/)build\.rs$/
  }
  /^SF:/ {
    source = substr($0, 4)
    crate = source
    sub(/^.*\/crates\//, "", crate)
    sub(/\/.*$/, "", crate)
    scoped = selected(source, crate)
    found = 0
    hit = 0
  }
  /^LF:/ { if (scoped) found += substr($0, 4) }
  /^LH:/ { if (scoped) hit += substr($0, 4) }
  /^end_of_record/ {
    if (scoped) { total_found += found; total_hit += hit }
    scoped = 0
  }
  END {
    if (total_found == 0) exit 65
    printf "%d/%d %.2f%%", total_hit, total_found, 100 * total_hit / total_found
  }
' "$rust_profile")" || {
  echo 'Unable to calculate Rust SDK coverage.' >&2
  exit 65
}
printf 'Rust SDK line coverage: %s\n' "$rust_coverage"
rust_percent="${rust_coverage##* }"
rust_percent="${rust_percent%\%}"
if ! awk -v value="$rust_percent" -v minimum="$MINIMUM" 'BEGIN { exit !(value + 0 >= minimum + 0) }'; then
  echo "Rust SDK coverage is below ${MINIMUM}%. Add meaningful protocol, failure, and state-transition tests." >&2
  awk '
    /^SF:/ { source = substr($0, 4); scoped = (source ~ /\/crates\/(network-ffi|network-identity|network-nat|network-protocol|network-quic|network-relay-proto|network-transfer|network-transport|network-webrtc)\//); misses = "" }
    /^DA:/ { if (scoped) { split(substr($0, 4), fields, ","); if ((fields[2] + 0) == 0) misses = misses (misses == "" ? "" : ", ") fields[1] } }
    /^end_of_record/ { if (scoped && misses != "") print "Uncovered " source ": " misses; scoped = 0 }
  ' "$rust_profile"
  exit 1
fi

printf 'SDK coverage gate passed at Dart %s%% and Rust %s%% (minimum %s%%).\n' \
  "$dart_total_percent" "$rust_percent" "$MINIMUM"
