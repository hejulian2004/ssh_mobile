#!/usr/bin/env bash

# Workspace and service CI jobs. Sourced by full_test.sh; keep shared state in the aggregate.

job_bootstrap() {
  need dart flutter npm cargo go python3 || return "$SKIP_STATUS"
  step 'Install root Dart workspace dependencies' dart pub get
  step 'Install native Flutter package dependencies' run_in packages/infrastructure/ssh_mobile_network_native flutter pub get
  step 'Install Full App dependencies' run_in apps/ssh_mobile_full flutter pub get
  step 'Install front dependencies' run_in front npm ci
  step 'Fetch locked Rust dependencies' run_in native/network_core cargo fetch --locked
  step 'Fetch Go dependencies' run_in relay go mod download
}

job_client_backend_smoke() {
  need bash curl || return "$SKIP_STATUS"
  step 'Run client → Caddy → Go Relay smoke E2E' bash "$ROOT_DIR/scripts/bash/e2e/client_backend_e2e.sh" smoke
}

job_front() {
  need npm || return "$SKIP_STATUS"
  step 'Typecheck front' run_in front npm run typecheck
  step 'Typecheck front tests' run_in front npm run typecheck:tests
  step 'Lint front' run_in front npm run lint
  step 'Test front' run_in front npm run test:run
  step 'Build front' run_in front npm run build
  if ((DOCKER_AVAILABLE)); then
    step 'Build front container' docker build -t "ssh-mobile-relay-front:full-test-$RUN_ID" "$ROOT_DIR/front"
  else
    echo 'ENVIRONMENT GAP: Docker daemon is unavailable; front container build was not run.'
    return "$SKIP_STATUS"
  fi
}

job_admin_api_contract() {
  need go npm || return "$SKIP_STATUS"
  step 'Check Front ↔ Relay administrator API contract' bash "$ROOT_DIR/scripts/bash/contracts/admin_api_contract.sh"
}

job_telemetry_contract() {
  need dart go npm flutter || return "$SKIP_STATUS"
  step 'Check Telemetry data contract across Go, Front, and Dart' bash "$ROOT_DIR/scripts/bash/contracts/telemetry_contract.sh"
}

job_native() {
  need cargo || return "$SKIP_STATUS"
  step 'Check Rust formatting' run_in native/network_core cargo fmt --all -- --check

  local turn_ready=0
  COTURN_CONTAINER="ssh-mobile-full-test-coturn-$RUN_ID"
  if ((DOCKER_AVAILABLE)); then
    if docker run -d --rm --name "$COTURN_CONTAINER" --network host \
      coturn/coturn:4.6.3@sha256:71c3c990283385567f11794ee692e3a47b66fd9b0bb39e42afbe776e331dd888 -n --log-file=stdout --lt-cred-mech \
      --fingerprint --user test:test --realm=ssh-mobile.test \
      --no-tls --no-dtls --min-port=49160 --max-port=49200 \
      --no-multicast-peers >/dev/null; then
      turn_ready=1
      trap 'docker rm -f "$COTURN_CONTAINER" >/dev/null 2>&1 || true' EXIT
    else
      echo 'ENVIRONMENT GAP: coturn container could not be started; TURN fallback was not run.'
    fi
  else
    echo 'ENVIRONMENT GAP: Docker daemon is unavailable; TURN fallback was not run.'
  fi

  # Network integration tests share loopback/QUIC resources. Keep one Rust
  # test case active so the gate does not turn scheduler pressure into a
  # transport-handshake flake.
  step 'Test Rust workspace' run_in native/network_core cargo test --workspace --locked -- --test-threads=1
  if ((turn_ready)); then
    step 'Test WebRTC TURN fallback' run_in native/network_core cargo test -p network-webrtc --locked -- --ignored relay_only_drivers_exchange_data_channel_payloads
  fi
  step 'Lint Rust workspace' run_in native/network_core cargo clippy --workspace --all-targets --locked -- -D warnings

  if ((turn_ready == 0)); then
    return "$SKIP_STATUS"
  fi
}

wait_for_mysql() {
  local attempt
  for attempt in $(seq 1 60); do
    if docker exec "$RELAY_MYSQL_CONTAINER" mysqladmin ping -h 127.0.0.1 -urelay -prelay >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_redis() {
  local attempt
  for attempt in $(seq 1 30); do
    if docker exec "$RELAY_REDIS_CONTAINER" redis-cli ping 2>/dev/null | rg -q '^PONG$'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_analytics_mysql() {
  local attempt
  for attempt in $(seq 1 60); do
    if docker exec "$ANALYTICS_MYSQL_CONTAINER" mysqladmin ping -h 127.0.0.1 \
      -utelemetry -p"$ANALYTICS_MYSQL_PASSWORD" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_analytics_redis() {
  local attempt
  for attempt in $(seq 1 30); do
    if docker exec "$ANALYTICS_REDIS_CONTAINER" redis-cli -a "$ANALYTICS_REDIS_PASSWORD" \
      --no-auth-warning ping 2>/dev/null | rg -q '^PONG$'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

start_relay_services() {
  RELAY_MYSQL_CONTAINER="ssh-mobile-full-test-mysql-$RUN_ID"
  RELAY_REDIS_CONTAINER="ssh-mobile-full-test-redis-$RUN_ID"
  ANALYTICS_MYSQL_CONTAINER="ssh-mobile-full-test-analytics-mysql-$RUN_ID"
  ANALYTICS_REDIS_CONTAINER="ssh-mobile-full-test-analytics-redis-$RUN_ID"
  trap 'docker rm -f "${RELAY_MYSQL_CONTAINER:-}" "${RELAY_REDIS_CONTAINER:-}" "${ANALYTICS_MYSQL_CONTAINER:-}" "${ANALYTICS_REDIS_CONTAINER:-}" >/dev/null 2>&1 || true' EXIT

  docker run -d --rm --name "$RELAY_MYSQL_CONTAINER" -p 127.0.0.1::3306 \
    -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=relay \
    -e MYSQL_USER=relay -e MYSQL_PASSWORD=relay mysql:8.4@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb >/dev/null || return 1
  docker run -d --rm --name "$RELAY_REDIS_CONTAINER" -p 127.0.0.1::6379 \
    redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf >/dev/null || return 1
  ANALYTICS_MYSQL_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  ANALYTICS_MYSQL_ROOT_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  ANALYTICS_REDIS_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  docker run -d --rm --name "$ANALYTICS_MYSQL_CONTAINER" -p 127.0.0.1::3306 \
    -e MYSQL_ROOT_PASSWORD="$ANALYTICS_MYSQL_ROOT_PASSWORD" \
    -e MYSQL_DATABASE=telemetry -e MYSQL_USER=telemetry \
    -e MYSQL_PASSWORD="$ANALYTICS_MYSQL_PASSWORD" mysql:8.4@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb >/dev/null || return 1
  docker run -d --rm --name "$ANALYTICS_REDIS_CONTAINER" -p 127.0.0.1::6379 \
    -e ANALYTICS_REDIS_PASSWORD="$ANALYTICS_REDIS_PASSWORD" redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf sh -ec \
    'exec redis-server --maxmemory 64mb --maxmemory-policy noeviction --requirepass "$ANALYTICS_REDIS_PASSWORD"' >/dev/null || return 1

  RELAY_MYSQL_PORT="$(docker port "$RELAY_MYSQL_CONTAINER" 3306/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
  RELAY_REDIS_PORT="$(docker port "$RELAY_REDIS_CONTAINER" 6379/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
  ANALYTICS_MYSQL_PORT="$(docker port "$ANALYTICS_MYSQL_CONTAINER" 3306/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
  ANALYTICS_REDIS_PORT="$(docker port "$ANALYTICS_REDIS_CONTAINER" 6379/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
  [[ "$RELAY_MYSQL_PORT" =~ ^[0-9]+$ && "$RELAY_REDIS_PORT" =~ ^[0-9]+$ && \
    "$ANALYTICS_MYSQL_PORT" =~ ^[0-9]+$ && "$ANALYTICS_REDIS_PORT" =~ ^[0-9]+$ ]] || return 1

  wait_for_mysql || return 1
  wait_for_redis || return 1
  wait_for_analytics_mysql || return 1
  wait_for_analytics_redis || return 1
  export RELAY_TEST_MYSQL_DSN="relay:relay@tcp(127.0.0.1:${RELAY_MYSQL_PORT})/relay?parseTime=true&loc=UTC"
  export RELAY_TEST_REDIS_URL="redis://127.0.0.1:${RELAY_REDIS_PORT}/0"
  export TELEMETRY_TEST_MYSQL_DSN="telemetry:${ANALYTICS_MYSQL_PASSWORD}@tcp(127.0.0.1:${ANALYTICS_MYSQL_PORT})/telemetry?parseTime=true&loc=UTC"
  export TELEMETRY_MYSQL_DSN="$TELEMETRY_TEST_MYSQL_DSN"
  export TELEMETRY_TEST_REDIS_URL="redis://:${ANALYTICS_REDIS_PASSWORD}@127.0.0.1:${ANALYTICS_REDIS_PORT}/0"
  export TELEMETRY_REDIS_URL="$TELEMETRY_TEST_REDIS_URL"
}

job_relay() {
  need go || return "$SKIP_STATUS"
  local storage_ready=0
  if [[ -n "${RELAY_TEST_MYSQL_DSN:-}" && -n "${RELAY_TEST_REDIS_URL:-}" && \
    -n "${TELEMETRY_TEST_MYSQL_DSN:-}" && -n "${TELEMETRY_TEST_REDIS_URL:-}" ]]; then
    storage_ready=1
    echo 'Using caller-provided Relay and Analytics test endpoints.'
  elif ((DOCKER_AVAILABLE)); then
    if start_relay_services; then
      storage_ready=1
      trap 'docker rm -f "${RELAY_MYSQL_CONTAINER:-}" "${RELAY_REDIS_CONTAINER:-}" "${ANALYTICS_MYSQL_CONTAINER:-}" "${ANALYTICS_REDIS_CONTAINER:-}" >/dev/null 2>&1 || true' EXIT
    else
      echo 'ENVIRONMENT GAP: Relay/Analytics MySQL/Redis test containers could not be started; storage integration tests were not run.'
    fi
  else
    echo 'ENVIRONMENT GAP: Docker daemon is unavailable; Relay/Analytics integration tests were not run.'
  fi

  step 'Check Go formatting' bash -c 'files="$(gofmt -l .)"; if [[ -n "$files" ]]; then printf "%s\n" "$files"; exit 1; fi'
  step 'Test relay' run_in relay go test ./...
  step 'Test relay with race detector' run_in relay go test -race ./...
  step 'Vet relay' run_in relay go vet ./...
  step 'Scan relay vulnerabilities' run_in relay go run golang.org/x/vuln/cmd/govulncheck@v1.6.0 ./...

  if ((storage_ready == 0)); then
    return "$SKIP_STATUS"
  fi
}

job_protocol() {
  # network_v2_acceptance.sh strict runs Flutter owner selectors. Preflight
  # dart/flutter here so missing Linux SDK tools are classified as an
  # environment GAP by the job runner.
  need bash cargo go python3 protoc buf dart flutter || return "$SKIP_STATUS"
  step 'Compile-check Network V2 protos' protoc --proto_path=protocol \
    --descriptor_set_out="$LOG_DIR/network-v2-$RUN_ID.desc" \
    protocol/proto/relay/v2/relay_v2.proto \
    protocol/proto/network/v2/network.proto
  step 'Test Network V2 schema parity checker' dart run scripts/bash/contracts/check_network_v2_contract.dart --test
  step 'Run Network V2 schema parity check' dart run scripts/bash/contracts/check_network_v2_contract.dart
  step 'Run Relay V2 contract check' bash scripts/bash/contracts/relay_v2_contract.sh
  step 'Run strict Network V2 acceptance gate' bash scripts/bash/contracts/network_v2_acceptance.sh strict
  step 'buf lint' run_in protocol buf lint
  step 'buf breaking against frozen Relay V2' run_in protocol buf breaking . \
    --against '../.git#ref=6ec194bb3a66a748215d3abc11d6da84bd329619,subdir=protocol' \
    --path proto/relay/v2/relay_v2.proto
}

melos_exec() {
  local command="$1"
  shift
  dart run melos exec --concurrency "$MELOS_CONCURRENCY" --fail-fast "$@" -- "$command"
}

melos_feature_tests() {
  local exclusions=''
  if ((FEATURE_LOOPBACK_ENABLED == 0)); then
    # The protocol/policy tests use injected in-process boundaries. Only this
    # one test requires Flutter tester to bind a real loopback socket.
    exclusions=" ! -path 'test/services/mcp/mcp_http_server_native_test.dart'"
  fi
  local command="test_files=\$(find test -type f -name '*_test.dart'${exclusions} -print | sort);"
  command+=" timeout --signal=TERM --kill-after=20s $WORKSPACE_TEST_TIMEOUT"
  command+=" flutter test --no-pub --no-test-assets --concurrency $MELOS_TEST_CONCURRENCY \$test_files"
  dart run melos exec --concurrency "$MELOS_CONCURRENCY" --fail-fast "$@" -- "$command"
}

job_architecture() {
  need dart || return "$SKIP_STATUS"
  step 'Check agent documentation' dart run tool/check_agent_docs.dart
  step 'Test agent documentation checker' dart run test/tool/agent_docs_check_test.dart
  step 'Test CI workflow contract' dart run test/tool/ci_workflow_test.dart
  step 'Test CI production configuration' dart run test/tool/ci_production_config_test.dart
  step 'Check Dart file sizes and test roots' dart run tool/check_file_sizes.dart
  step 'Check telemetry contract generated' dart run tool/check_telemetry_contract_generated.dart
  step 'Test telemetry contract codegen' dart run test/tool/telemetry_contract_codegen_test.dart
  step 'Check architecture guard' dart run tool/architecture_check.dart
  step 'Check module dependencies' dart run tool/check_module_dependencies.dart
  step 'Check resource owners' dart run tool/check_resource_owners.dart
  step 'Check compatibility import inventory' dart run tool/compatibility_check.dart
  step 'Check duplicate implementations' dart run tool/duplicate_implementation_check.dart
}

job_sdk() {
  need dart || return "$SKIP_STATUS"
  step 'Format SDK packages' melos_exec 'dart format --output=none --set-exit-if-changed lib test' \
    --scope=network_sdk \
    --scope=network_transport \
    --scope=realtime_media \
    --scope=ssh_mobile_network_native
  step 'Analyze SDK packages' melos_exec 'flutter analyze --no-fatal-infos --no-pub' \
    --scope=network_sdk \
    --scope=network_transport \
    --scope=realtime_media \
    --scope=ssh_mobile_network_native
  step 'Test SDK packages' melos_exec "flutter test --no-pub --concurrency $MELOS_TEST_CONCURRENCY" \
    --scope=network_sdk \
    --scope=network_transport \
    --scope=realtime_media \
    --scope=ssh_mobile_network_native
}

job_lan_network_v2() {
  need dart flutter cargo || return "$SKIP_STATUS"

  # Keep this manifest explicit: a missing acceptance test is an implementation
  # failure, not a reason to silently fall back to the broad package suite.
  local -a feature_tests=(
    test/services/lan_peer_trust_v2_test.dart
    test/features/lan_native_peer_registry_v2_test.dart
    test/features/lan_network_v2_acceptance_matrix_test.dart
    test/features/network_incoming_transfer_host_test.dart
    test/services/lan_storage_service_test.dart
    test/services/lan_pairing_protocol_v2_test.dart
    test/services/lan_peer_trust_identity_v2_test.dart
    test/services/lan_peer_presentation_models_test.dart
    test/services/lan_native_transfer_coordinator_v2_test.dart
    test/services/lan_http_v2_route_test.dart
    test/services/lan_web_share_request_handler_test.dart
  )
  local -a sdk_tests=(
    test/network_facade_v2_refactor_test.dart
    test/network_sdk_contract_test.dart
    test/network_v2_contract_test.dart
    test/network_v2_facade_test.dart
  )
  local -a app_tests=(
    test/app/network_runtime_ownership_v2_test.dart
    test/services/network/network_identity_service_test.dart
    test/services/network/network_protocol_v2_codec_test.dart
    test/features/lan_share/lan_e2e_encryption_test.dart
    test/features/lan_share/lan_pairing_v2_contract_test.dart
    test/features/lan_share/lan_storage_safety_v2_test.dart
    test/features/lan_share/lan_runtime_restart_transfer_v2_test.dart
    test/services/lan_web_share_safety_test.dart
  )
  local web_share_tls_worker='tool/lan_web_share_tls_process.dart'
  local feature_test sdk_test app_test
  local missing=0
  for feature_test in "${feature_tests[@]}"; do
    if [[ ! -f "$ROOT_DIR/packages/features/feature_lan_share/$feature_test" ]]; then
      echo "MISSING LAN V2 acceptance test: packages/features/feature_lan_share/$feature_test"
      missing=1
    fi
  done
  for sdk_test in "${sdk_tests[@]}"; do
    if [[ ! -f "$ROOT_DIR/packages/infrastructure/network_sdk/$sdk_test" ]]; then
      echo "MISSING LAN V2 acceptance test: packages/infrastructure/network_sdk/$sdk_test"
      missing=1
    fi
  done
  for app_test in "${app_tests[@]}"; do
    if [[ ! -f "$ROOT_DIR/apps/ssh_mobile_full/$app_test" ]]; then
      echo "MISSING LAN V2 acceptance test: apps/ssh_mobile_full/$app_test"
      missing=1
    fi
  done
  if [[ ! -f "$ROOT_DIR/packages/features/feature_lan_share/$web_share_tls_worker" ]]; then
    echo "MISSING WebShare TLS process worker: packages/features/feature_lan_share/$web_share_tls_worker"
    missing=1
  fi
  if ((missing)); then
    return 1
  fi

  step 'Test LAN Share V2 trust/registry/pairing/route ownership' \
    run_in packages/features/feature_lan_share flutter test --no-pub --no-test-assets "${feature_tests[@]}"
  step 'Test Network SDK V2 explicit peer lifecycle' \
    run_in packages/infrastructure/network_sdk flutter test --no-pub --no-test-assets "${sdk_tests[@]}"
  step 'Test Full App Network V2 adapter' \
    run_in apps/ssh_mobile_full flutter test --no-pub --no-test-assets "${app_tests[@]}"
  # Keep the real TLS listener in an ordinary Dart VM process. The boundary
  # suite above uses in-memory requests; this worker owns bindSecure and has no
  # retry/skip path that could hide a native bind stall in flutter_tester.
  step 'Test WebShare TLS and production route handler in ordinary Dart VM' \
    run_in packages/features/feature_lan_share timeout --signal=TERM --kill-after=30s "$APP_TIMEOUT" \
      dart run "$web_share_tls_worker"
  step 'Test Native Network V2 restart and route authorization' \
    run_in native/network_core cargo test -p network-core --locked --lib two_runtimes -- --test-threads=1
  step 'Test Native Network V2 receiver restart transfer' \
    run_in native/network_core cargo test -p network-core --locked --lib \
      receiver_runtime_restart_restores_direct_trust_without_repairing -- --test-threads=1
  step 'Test Native Network V2 peer restart delivery' \
    run_in native/network_core cargo test -p network-core --locked --lib \
      peer_runtime_restart_replaces_session_and_keeps_e2ee_delivery -- --test-threads=1
  step 'Test Native Network V2 route authorization boundary' \
    run_in native/network_core cargo test -p network-core --locked --lib network_v2_route_auth -- --test-threads=1
}

job_core() {
  need dart || return "$SKIP_STATUS"
  step 'Format core packages' melos_exec 'dart format --output=none --set-exit-if-changed lib test' \
    --scope=app_core \
    --scope=app_ui \
    --scope=connection_core \
    --scope=ssh_core
  step 'Analyze core packages' melos_exec 'flutter analyze --no-fatal-infos --no-pub' \
    --scope=app_core \
    --scope=app_ui \
    --scope=connection_core \
    --scope=ssh_core
  step 'Test core packages' melos_exec "flutter test --no-pub --concurrency $MELOS_TEST_CONCURRENCY" \
    --scope=app_core \
    --scope=app_ui \
    --scope=connection_core \
    --scope=ssh_core
}

job_features() {
  need dart || return "$SKIP_STATUS"
  step 'Format feature packages' melos_exec 'dart format --output=none --set-exit-if-changed lib test' \
    --scope=feature_ai \
    --scope=feature_connection \
    --scope=feature_developer \
    --scope=feature_lan_share \
    --scope=feature_mcp \
    --scope=feature_monitoring \
    --scope=feature_playbook \
    --scope=feature_rag \
    --scope=feature_sftp \
    --scope=feature_system_admin \
    --scope=feature_terminal \
    --scope=feature_webview
  step 'Analyze feature packages' melos_exec 'flutter analyze --no-fatal-infos --no-pub' \
    --scope=feature_ai \
    --scope=feature_connection \
    --scope=feature_developer \
    --scope=feature_lan_share \
    --scope=feature_mcp \
    --scope=feature_monitoring \
    --scope=feature_playbook \
    --scope=feature_rag \
    --scope=feature_sftp \
    --scope=feature_system_admin \
    --scope=feature_terminal \
    --scope=feature_webview
  step 'Test feature packages' melos_feature_tests \
    --scope=feature_ai \
    --scope=feature_connection \
    --scope=feature_developer \
    --scope=feature_lan_share \
    --scope=feature_mcp \
    --scope=feature_monitoring \
    --scope=feature_playbook \
    --scope=feature_rag \
    --scope=feature_sftp \
    --scope=feature_system_admin \
    --scope=feature_terminal \
    --scope=feature_webview
}
