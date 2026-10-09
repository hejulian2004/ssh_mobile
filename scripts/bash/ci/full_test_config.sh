#!/usr/bin/env bash

# Run the Linux-runnable GitHub Actions gates locally from WSL.
#
# Raw command output is kept in a per-job log. The terminal receives only
# failure/environment-gap summaries so an agent can inspect the signal first.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

SKIP_STATUS=125
# WSL measurements on 2026-08-20:
#   * architecture/core gates: about 5m45s
#   * feature gate serialised: about 4m07s (parallel Melos reached 8m35s)
#   * Full App shards without coverage: about 117s/102s when run one at a time
#   * Full App coverage shards are substantially slower under WSL because
#     Flutter instruments the whole App isolate; allow a long local window.
# App shards use per-shard Flutter build directories so their expensive test
# processes can run together without contending for the shared build/test cache.
# The daily gate deliberately skips coverage; the four domain-specific
# coverage scripts keep the slower instrumented reviews separate from ordinary
# regression feedback.
DEFAULT_APP_TIMEOUT="${FULL_TEST_APP_TIMEOUT:-8m}"
DEFAULT_FLUTTER_CONCURRENCY="${FULL_TEST_FLUTTER_CONCURRENCY:-1}"
DEFAULT_MELOS_CONCURRENCY="${FULL_TEST_MELOS_CONCURRENCY:-1}"
DEFAULT_MELOS_TEST_CONCURRENCY="${FULL_TEST_MELOS_TEST_CONCURRENCY:-1}"
DEFAULT_APP_SHARD_COUNT="${FULL_TEST_APP_SHARDS:-2}"
# CI keeps coverage as a separate job. Local full_test.sh is the daily basic
# regression gate; scripts/bash/coverage/client_coverage.sh is the focused client review.
# --with-coverage remains available for the historical full-App aggregate.
DEFAULT_APP_COVERAGE="${FULL_TEST_COVERAGE:-0}"
DEFAULT_WORKSPACE_TEST_TIMEOUT="${FULL_TEST_WORKSPACE_TEST_TIMEOUT:-5m}"

USER_HOME="${HOME:-}"
TOOLCHAIN_ROOT="${SSH_MOBILE_TOOLCHAIN_ROOT:-$USER_HOME/.local/ssh-mobile-toolchain}"
GO_ROOT="${SSH_MOBILE_GO_ROOT:-$TOOLCHAIN_ROOT/go1.27.2}"
WSL_TEMP_ROOT="${FULL_TEST_TMPDIR:-/tmp}"

JOB_LIMIT="${FULL_TEST_JOBS:-}"
FLUTTER_CONCURRENCY="$DEFAULT_FLUTTER_CONCURRENCY"
MELOS_CONCURRENCY="$DEFAULT_MELOS_CONCURRENCY"
MELOS_TEST_CONCURRENCY="$DEFAULT_MELOS_TEST_CONCURRENCY"
APP_TIMEOUT="$DEFAULT_APP_TIMEOUT"
APP_TIMEOUT_EXPLICIT=0
if [[ -n "${FULL_TEST_APP_TIMEOUT:-}" ]]; then
  APP_TIMEOUT_EXPLICIT=1
fi
APP_COVERAGE_ENABLED="$DEFAULT_APP_COVERAGE"
APP_SHARDS_PARALLEL="${FULL_TEST_APP_SHARDS_PARALLEL:-}"
APP_SHARD_COUNT="$DEFAULT_APP_SHARD_COUNT"
WORKSPACE_TEST_TIMEOUT="$DEFAULT_WORKSPACE_TEST_TIMEOUT"
FEATURE_LOOPBACK_ENABLED="${FULL_TEST_FEATURE_LOOPBACK:-0}"
WITH_CLIENT_BACKEND_SMOKE="${FULL_TEST_CLIENT_BACKEND_SMOKE:-0}"
SKIP_BOOTSTRAP=0
DOCKER_ENABLED=1
VERBOSE=0
ONLY_JOBS=""

# Flutter's test runner starts a local VM service and coverage endpoint. A
# WSL-local HTTP(S) proxy must not receive those loopback requests; dependency
# bootstrap and artifact downloads intentionally keep the caller's proxy
# environment unchanged.
FLUTTER_LOCAL_TEST_ENV=(
  HTTP_PROXY=
  HTTPS_PROXY=
  http_proxy=
  https_proxy=
  ALL_PROXY=
  all_proxy=
  SSH_MOBILE_WINDOWS_PROXY=
  NO_PROXY=localhost,127.0.0.1,::1
  no_proxy=localhost,127.0.0.1,::1
)

usage() {
  cat <<'EOF'
Usage: bash scripts/bash/ci/full_test.sh [options]

Run the CI gates that are available in a WSL/Linux environment. Normal passing
output is kept in a log directory; failures and environment gaps are printed.

Options:
  --jobs N                  Maximum independent CI jobs running at once (default: 4).
  --serial                  Equivalent to --jobs 1 and serial App shards.
  --flutter-concurrency N   Flutter test workers per App test process (default: 1).
  --melos-concurrency N     Workspace packages tested by Melos at once (default: 1).
  --melos-test-concurrency N
                            Test cases per workspace Flutter package (default: 1).
  --app-timeout DURATION    Timeout for one App test attempt (default: 8m; coverage: 30m).
  --app-shards N            App test file partitions (default: 2; local tuning: 4).
  --with-coverage            Opt into Flutter coverage and the App coverage gate.
  --no-coverage              Skip Flutter coverage (default for the daily gate).
  --with-feature-loopback    Include the native MCP loopback integration test.
  --with-client-backend-smoke
                            Run the isolated Flutter/Rust client → Caddy → Go Relay smoke gate.
  --workspace-test-timeout DURATION
                            Timeout for one Melos package test process (default: 5m).
  --no-bootstrap            Do not run dependency installation first.
  --no-docker               Do not use Docker-backed CI checks.
  --only JOBS               Comma-separated job names to run.
  --verbose                 Print a short tail for successful jobs too.
  -h, --help                Show this help.

Examples:
  bash scripts/bash/ci/full_test.sh
  bash scripts/bash/ci/full_test.sh --jobs 4 --flutter-concurrency 4
  bash scripts/bash/ci/full_test.sh --no-bootstrap --jobs 4
  bash scripts/bash/coverage/client_coverage.sh --no-bootstrap
  bash scripts/bash/ci/full_test.sh --only protocol-v2-contract,architecture-check
  bash scripts/bash/ci/full_test.sh --only lan-network-v2-targeted
  FULL_TEST_APP_TIMEOUT=8m bash scripts/bash/ci/full_test.sh --serial
  FULL_TEST_APP_SHARDS_PARALLEL=1 bash scripts/bash/ci/full_test.sh --with-coverage --no-bootstrap
  FULL_TEST_APP_SHARDS_PARALLEL=0 bash scripts/bash/ci/full_test.sh --with-coverage --no-bootstrap
  FULL_TEST_APP_SHARDS=4 FULL_TEST_APP_SHARDS_PARALLEL=1 bash scripts/bash/ci/full_test.sh --with-coverage --no-bootstrap
  bash scripts/bash/ci/full_test.sh --with-client-backend-smoke --no-bootstrap

Exit status:
  0  All selected checks passed.
  1  A selected check failed.
  2  Checks were incomplete because a required local environment capability
     was unavailable (for example Docker or a platform-only toolchain).
EOF
}

is_positive_int() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

while (($# > 0)); do
  case "$1" in
    --jobs)
      (($# >= 2)) || { echo "--jobs requires a value" >&2; exit 64; }
      JOB_LIMIT="$2"
      shift 2
      ;;
    --jobs=*)
      JOB_LIMIT="${1#*=}"
      shift
      ;;
    --serial)
      JOB_LIMIT=1
      APP_SHARDS_PARALLEL=0
      shift
      ;;
    --flutter-concurrency)
      (($# >= 2)) || { echo "--flutter-concurrency requires a value" >&2; exit 64; }
      FLUTTER_CONCURRENCY="$2"
      shift 2
      ;;
    --flutter-concurrency=*)
      FLUTTER_CONCURRENCY="${1#*=}"
      shift
      ;;
    --melos-concurrency)
      (($# >= 2)) || { echo "--melos-concurrency requires a value" >&2; exit 64; }
      MELOS_CONCURRENCY="$2"
      shift 2
      ;;
    --melos-concurrency=*)
      MELOS_CONCURRENCY="${1#*=}"
      shift
      ;;
    --melos-test-concurrency)
      (($# >= 2)) || { echo "--melos-test-concurrency requires a value" >&2; exit 64; }
      MELOS_TEST_CONCURRENCY="$2"
      shift 2
      ;;
    --melos-test-concurrency=*)
      MELOS_TEST_CONCURRENCY="${1#*=}"
      shift
      ;;
    --app-timeout)
      (($# >= 2)) || { echo "--app-timeout requires a value" >&2; exit 64; }
      APP_TIMEOUT="$2"
      APP_TIMEOUT_EXPLICIT=1
      shift 2
      ;;
    --app-timeout=*)
      APP_TIMEOUT="${1#*=}"
      APP_TIMEOUT_EXPLICIT=1
      shift
      ;;
    --app-shards)
      (($# >= 2)) || { echo "--app-shards requires a value" >&2; exit 64; }
      APP_SHARD_COUNT="$2"
      shift 2
      ;;
    --app-shards=*)
      APP_SHARD_COUNT="${1#*=}"
      shift
      ;;
    --with-coverage)
      APP_COVERAGE_ENABLED=1
      shift
      ;;
    --no-coverage)
      APP_COVERAGE_ENABLED=0
      shift
      ;;
    --with-feature-loopback)
      FEATURE_LOOPBACK_ENABLED=1
      shift
      ;;
    --with-client-backend-smoke)
      WITH_CLIENT_BACKEND_SMOKE=1
      shift
      ;;
    --workspace-test-timeout)
      (($# >= 2)) || { echo "--workspace-test-timeout requires a value" >&2; exit 64; }
      WORKSPACE_TEST_TIMEOUT="$2"
      shift 2
      ;;
    --workspace-test-timeout=*)
      WORKSPACE_TEST_TIMEOUT="${1#*=}"
      shift
      ;;
    --no-bootstrap)
      SKIP_BOOTSTRAP=1
      shift
      ;;
    --no-docker)
      DOCKER_ENABLED=0
      shift
      ;;
    --only)
      (($# >= 2)) || { echo "--only requires a value" >&2; exit 64; }
      ONLY_JOBS="$2"
      shift 2
      ;;
    --only=*)
      ONLY_JOBS="${1#*=}"
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "$JOB_LIMIT" ]]; then
  CPU_COUNT="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  if ! is_positive_int "$CPU_COUNT"; then
    CPU_COUNT=2
  fi
  JOB_LIMIT=$((CPU_COUNT < 4 ? CPU_COUNT : 4))
fi

if ! is_positive_int "$JOB_LIMIT"; then
  echo "--jobs must be a positive integer: $JOB_LIMIT" >&2
  exit 64
fi
if ! is_positive_int "$FLUTTER_CONCURRENCY"; then
  echo "--flutter-concurrency must be a positive integer: $FLUTTER_CONCURRENCY" >&2
  exit 64
fi
if ! is_positive_int "$MELOS_CONCURRENCY"; then
  echo "--melos-concurrency must be a positive integer: $MELOS_CONCURRENCY" >&2
  exit 64
fi
if ! is_positive_int "$MELOS_TEST_CONCURRENCY"; then
  echo "--melos-test-concurrency must be a positive integer: $MELOS_TEST_CONCURRENCY" >&2
  exit 64
fi
if [[ ! "$APP_TIMEOUT" =~ ^[0-9]+[smhd]$ ]]; then
  echo "--app-timeout must look like 60s, 20m, or 1h: $APP_TIMEOUT" >&2
  exit 64
fi
if ! is_positive_int "$APP_SHARD_COUNT" || ((APP_SHARD_COUNT > 4)); then
  echo "--app-shards must be an integer from 1 through 4: $APP_SHARD_COUNT" >&2
  exit 64
fi
if [[ "$APP_COVERAGE_ENABLED" != 0 && "$APP_COVERAGE_ENABLED" != 1 ]]; then
  echo "FULL_TEST_COVERAGE/coverage option must be 0 or 1: $APP_COVERAGE_ENABLED" >&2
  exit 64
fi
if ((APP_COVERAGE_ENABLED)) && ((APP_TIMEOUT_EXPLICIT == 0)); then
  APP_TIMEOUT=30m
fi
if [[ -z "$APP_SHARDS_PARALLEL" ]]; then
  if ((APP_COVERAGE_ENABLED)); then
    APP_SHARDS_PARALLEL=0
  else
    APP_SHARDS_PARALLEL=1
  fi
fi
if [[ "$APP_SHARDS_PARALLEL" != 0 && "$APP_SHARDS_PARALLEL" != 1 ]]; then
  echo "FULL_TEST_APP_SHARDS_PARALLEL must be 0 or 1: $APP_SHARDS_PARALLEL" >&2
  exit 64
fi
if [[ "$FEATURE_LOOPBACK_ENABLED" != 0 && "$FEATURE_LOOPBACK_ENABLED" != 1 ]]; then
  echo "FULL_TEST_FEATURE_LOOPBACK/loopback option must be 0 or 1: $FEATURE_LOOPBACK_ENABLED" >&2
  exit 64
fi
if [[ "$WITH_CLIENT_BACKEND_SMOKE" != 0 && "$WITH_CLIENT_BACKEND_SMOKE" != 1 ]]; then
  echo "FULL_TEST_CLIENT_BACKEND_SMOKE option must be 0 or 1: $WITH_CLIENT_BACKEND_SMOKE" >&2
  exit 64
fi
if [[ ! "$WORKSPACE_TEST_TIMEOUT" =~ ^[0-9]+[smhd]$ ]]; then
  echo "--workspace-test-timeout must look like 60s, 5m, or 1h: $WORKSPACE_TEST_TIMEOUT" >&2
  exit 64
fi

# Prefer the Linux toolchain installed for this WSL workspace when it exists.
for candidate in \
  "$TOOLCHAIN_ROOT/protobuf/bin" \
  "$TOOLCHAIN_ROOT/flutter/bin" \
  "$TOOLCHAIN_ROOT/flutter/bin/cache/dart-sdk/bin" \
  "$USER_HOME/.pub-cache/bin" \
  "$USER_HOME/.go/bin" \
  "$USER_HOME/go/bin" \
  "$USER_HOME/.cargo/bin"; do
  if [[ -d "$candidate" ]]; then
    PATH="$candidate:$PATH"
  fi
done
if [[ -d "$USER_HOME/.nvm/versions/node" ]]; then
  for candidate in "$USER_HOME"/.nvm/versions/node/*/bin; do
    if [[ -d "$candidate" ]]; then
      PATH="$candidate:$PATH"
    fi
  done
fi
if [[ -d "$GO_ROOT" ]]; then
  PATH="$GO_ROOT/bin:$PATH"
  export GOROOT="$GO_ROOT"
fi
export PATH

if [[ -z "${JAVA_HOME:-}" && -d "$TOOLCHAIN_ROOT/jdk-17" ]]; then
  export JAVA_HOME="$TOOLCHAIN_ROOT/jdk-17"
fi
if [[ -z "${ANDROID_HOME:-}" && -d "$TOOLCHAIN_ROOT/android-sdk" ]]; then
  export ANDROID_HOME="$TOOLCHAIN_ROOT/android-sdk"
fi

# Flutter's local HTTP tests need both proxy variable spellings to bypass the
# WSL loopback proxy. Preserve any user-provided entries.
LOOPBACK_NO_PROXY="127.0.0.1,localhost,::1"
if [[ -n "${NO_PROXY:-}" ]]; then
  NO_PROXY="$NO_PROXY,$LOOPBACK_NO_PROXY"
else
  NO_PROXY="$LOOPBACK_NO_PROXY"
fi
export NO_PROXY
export no_proxy="$NO_PROXY"

# Keep Flutter/Dart/Rust/Node temporary files on the Linux filesystem. WSL can
# inherit TMP/TEMP from Windows, which makes test subprocesses cross the
# /mnt/c boundary and can break loopback HTTP startup under load.
if [[ ! -d "$WSL_TEMP_ROOT" || ! -w "$WSL_TEMP_ROOT" ]]; then
  echo "WSL temporary directory is unavailable or not writable: $WSL_TEMP_ROOT" >&2
  exit 69
fi
export TMPDIR="$WSL_TEMP_ROOT"
export TMP="$WSL_TEMP_ROOT"
export TEMP="$WSL_TEMP_ROOT"

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
if [[ -n "${FULL_TEST_LOG_DIR:-}" ]]; then
  LOG_DIR="${FULL_TEST_LOG_DIR%/}/$RUN_ID"
  mkdir -p "$LOG_DIR"
else
  LOG_DIR="$(mktemp -d "$WSL_TEMP_ROOT/ssh-mobile-full-test.XXXXXX")"
fi

if ! command_available rg; then
  echo "rg is required for compact failure filtering; install ripgrep first." >&2
  exit 69
fi

DOCKER_AVAILABLE=0
if ((DOCKER_ENABLED)) && command_available docker; then
  if docker info >/dev/null 2>&1; then
    DOCKER_AVAILABLE=1
  fi
fi

printf 'SSH Mobile local CI\n'
printf 'root: %s\n' "$ROOT_DIR"
printf 'parallel jobs: %s; Flutter workers per App process: %s\n' "$JOB_LIMIT" "$FLUTTER_CONCURRENCY"
printf 'Melos package concurrency: %s\n' "$MELOS_CONCURRENCY"
printf 'Melos test-case concurrency: %s\n' "$MELOS_TEST_CONCURRENCY"
printf 'App test attempt timeout: %s\n' "$APP_TIMEOUT"
printf 'App coverage: %s\n' "$([[ $APP_COVERAGE_ENABLED -eq 1 ]] && echo enabled || echo disabled)"
printf 'App shard scheduling: %s\n' "$([[ $APP_SHARDS_PARALLEL -eq 1 ]] && echo parallel-with-isolated-builds || echo serial)"
printf 'App shard count: %s\n' "$APP_SHARD_COUNT"
printf 'Workspace package test timeout: %s\n' "$WORKSPACE_TEST_TIMEOUT"
printf 'Feature loopback tests: %s\n' "$([[ $FEATURE_LOOPBACK_ENABLED -eq 1 ]] && echo enabled || echo skipped-for-WSL)"
printf 'Client-backend smoke: %s\n' "$([[ $WITH_CLIENT_BACKEND_SMOKE -eq 1 ]] && echo enabled || echo skipped-by-default)"
printf 'Docker-backed checks: %s\n' "$([[ $DOCKER_AVAILABLE -eq 1 ]] && echo available || echo unavailable)"
printf 'logs: %s\n\n' "$LOG_DIR"

declare -a SELECTED_NAMES=()
declare -A RESULTS=()
declare -A LOG_PATHS=()
declare -A DURATIONS=()
OVERALL_FAILURE=0
OVERALL_INCOMPLETE=0
RUN_START_SECONDS="$(date +%s)"
