#!/usr/bin/env bash

# Full App test and build jobs. Sourced by full_test.sh; keep shared state in the aggregate.

job_app_static() {
  need dart flutter || return "$SKIP_STATUS"
  step 'Check generated app icons' bash -c 'cd apps/ssh_mobile_full && dart run tool/generate_app_icons.dart && git diff --exit-code -- assets android ios macos web windows/runner/resources/app_icon.ico'
  step 'Check Full App formatting' run_in apps/ssh_mobile_full dart format --output=none --set-exit-if-changed lib test tool
  step 'Check generated database code' bash -c 'cd apps/ssh_mobile_full && dart run build_runner clean && dart run build_runner build && git diff --exit-code -- lib/data/database/app_database.g.dart'
  step 'Security regression grep' bash -c 'cd apps/ssh_mobile_full && ! grep -R "SshIdentityCache" lib && ! grep -R "reconnectCredentials" lib && ! grep -R "privateKeyDigest" lib'
  step 'Analyze Full App' run_in apps/ssh_mobile_full flutter analyze --no-fatal-infos
}

collect_app_tests() {
  local -n output_array="$1"
  mapfile -d '' all_test_files < <(find "$ROOT_DIR/apps/ssh_mobile_full/test" -type f -name '*_test.dart' -print0 | sort -z)
  local test_file
  for test_file in "${all_test_files[@]}"; do
    test_file="${test_file#"$ROOT_DIR/apps/ssh_mobile_full/"}"
    case "$test_file" in
      test/features/startup/views/startup_screen_test.dart|test/screens/system_admin/system_admin_snapshot_tabs_test.dart|test/services/network/transfer_transport_test.dart|test/integration/client_backend/*)
        ;;
      *)
        output_array+=("$test_file")
        ;;
    esac
  done
}

partition_app_tests() {
  local -n input_array="$1"
  local shard="$2"
  local -n output_array="$3"
  local index candidate file_size target file_path
  local -a sorted_indices=()
  local -a shard_sizes=()
  for ((index = 0; index < APP_SHARD_COUNT; index++)); do
    shard_sizes+=(0)
  done
  # Flutter's --total-shards/--shard-index keeps every test path on each
  # command line and lets the test package discard work at runtime. The daily
  # no-coverage path splits the file list before invoking Flutter so each
  # process compiles only its own partition of the App suite. A size-balanced
  # greedy assignment keeps the slowest process from becoming the wall-clock
  # tail.
  mapfile -t sorted_indices < <(
    for index in "${!input_array[@]}"; do
      file_path="$ROOT_DIR/apps/ssh_mobile_full/${input_array[$index]}"
      printf '%s\t%s\n' "$(wc -c < "$file_path")" "$index"
    done | sort -nr | cut -f2
  )
  for index in "${sorted_indices[@]}"; do
    file_path="$ROOT_DIR/apps/ssh_mobile_full/${input_array[$index]}"
    file_size="$(wc -c < "$file_path")"
    target=0
    for ((candidate = 1; candidate < APP_SHARD_COUNT; candidate++)); do
      if ((shard_sizes[candidate] < shard_sizes[target])); then
        target="$candidate"
      fi
    done
    if ((target == shard)); then
      output_array+=("${input_array[$index]}")
    fi
    shard_sizes[target]=$((shard_sizes[target] + file_size))
  done
}

flutter_test_config_root() {
  local shard="$1"
  printf '%s/flutter-config-shard-%s\n' "$LOG_DIR" "$shard"
}

prepare_flutter_test_config() {
  local shard="$1" config_root
  config_root="$(flutter_test_config_root "$shard")"
  mkdir -p "$config_root"
  XDG_CONFIG_HOME="$config_root" env "${FLUTTER_LOCAL_TEST_ENV[@]}" \
    flutter config --build-dir "build/full-test-shard-$shard" >/dev/null
}

run_app_test_with_retry() {
  local shard="$1"
  local coverage_path="$2"
  shift 2
  local attempt status timeout_pid
  local -a coverage_args=()
  local flutter_config_root
  flutter_config_root="$(flutter_test_config_root "$shard")"
  prepare_flutter_test_config "$shard"
  if ((APP_COVERAGE_ENABLED)); then
    coverage_args=(--coverage --coverage-path "$coverage_path")
  fi
  for attempt in 1 2; do
    if ((APP_COVERAGE_ENABLED)); then
      rm -f "$coverage_path"
    fi
    printf 'Running App shard %s (attempt %s) with Flutter concurrency %s.\n' "$shard" "$attempt" "$FLUTTER_CONCURRENCY"
    timeout --signal=TERM --kill-after=30s "$APP_TIMEOUT" \
      env "XDG_CONFIG_HOME=$flutter_config_root" "${FLUTTER_LOCAL_TEST_ENV[@]}" flutter test --no-pub "${coverage_args[@]}" \
      --exclude-tags client-backend,native-loopback \
      --reporter compact --fail-fast --timeout 60s \
      --concurrency "$FLUTTER_CONCURRENCY" \
      "$@" &
    timeout_pid=$!
    if wait "$timeout_pid"; then
      return 0
    else
      status=$?
      # GNU timeout normally kills its process group, but Flutter can leave a
      # tester descendant re-parented after shutdown. Reap that whole group
      # before retrying, otherwise the retry can deadlock on inherited sockets.
      kill -- -"$timeout_pid" 2>/dev/null || true
      pkill -TERM -P "$timeout_pid" 2>/dev/null || true
      sleep 1
    fi
    if ((attempt == 2)); then
      return "$status"
    fi
    echo 'Flutter App shard failed or timed out; retrying once.'
  done
}

job_app_unit() {
  local shard="$1"
  need flutter || return "$SKIP_STATUS"
  local -a coverage_test_files=()
  local -a app_test_files=()
  local -a app_shard_args=()
  collect_app_tests coverage_test_files
  partition_app_tests coverage_test_files "$shard" app_test_files
  if ((${#app_test_files[@]} == 0)); then
    echo 'No Full App test files were discovered.'
    return 1
  fi

  local coverage_dir="$LOG_DIR/coverage/full-test-shard-$shard"
  mkdir -p "$coverage_dir"
  local flutter_config_root
  flutter_config_root="$(flutter_test_config_root "$shard")"
  local batch_size=10 batch=0 test_status=0 batch_coverage batch_end
  while ((batch * batch_size < ${#app_test_files[@]})); do
    batch_end=$(((batch + 1) * batch_size))
    batch_coverage="$coverage_dir/lcov-batch-$batch.info"
    if ((batch_end > ${#app_test_files[@]})); then batch_end=${#app_test_files[@]}; fi
    run_in apps/ssh_mobile_full run_app_test_with_retry "$shard-batch-$batch" "$batch_coverage" \
      "${app_test_files[@]:batch * batch_size:batch_end - batch * batch_size}"
    test_status=$?
    if ((test_status != 0)); then return "$test_status"; fi
    batch=$((batch + 1))
  done
  if ((APP_COVERAGE_ENABLED)); then
    : > "$coverage_dir/lcov.info"
    for batch_coverage in "$coverage_dir"/lcov-batch-*.info; do
      [[ -f "$batch_coverage" ]] || continue
      if [[ ! -s "$coverage_dir/lcov.info" ]]; then cp "$batch_coverage" "$coverage_dir/lcov.info"; else sed '/^TN:/d' "$batch_coverage" >> "$coverage_dir/lcov.info"; fi
    done
  fi

  local isolated_startup="$coverage_dir/isolated-startup-lcov.info"
  local isolated_system_admin="$coverage_dir/isolated-system-admin-lcov.info"
  local non_coverage_file='test/services/network/transfer_transport_test.dart'
  local -a startup_coverage_args=()
  local -a system_admin_coverage_args=()
  if ((APP_COVERAGE_ENABLED)); then
    rm -f "$isolated_startup" "$isolated_system_admin"
    startup_coverage_args=(--coverage --coverage-path "$isolated_startup")
    system_admin_coverage_args=(--coverage --coverage-path "$isolated_system_admin")
  fi
  step "Run isolated startup test for shard $shard" run_in apps/ssh_mobile_full timeout --signal=TERM --kill-after=30s "$APP_TIMEOUT" \
    env "XDG_CONFIG_HOME=$flutter_config_root" "${FLUTTER_LOCAL_TEST_ENV[@]}" flutter test --no-pub "${startup_coverage_args[@]}" --reporter compact --fail-fast \
    --timeout 60s --concurrency "$FLUTTER_CONCURRENCY" --total-shards "$APP_SHARD_COUNT" --shard-index "$shard" \
    test/features/startup/views/startup_screen_test.dart
  step "Run isolated system-admin test for shard $shard" run_in apps/ssh_mobile_full timeout --signal=TERM --kill-after=30s "$APP_TIMEOUT" \
    env "XDG_CONFIG_HOME=$flutter_config_root" "${FLUTTER_LOCAL_TEST_ENV[@]}" flutter test --no-pub "${system_admin_coverage_args[@]}" --reporter compact --fail-fast \
    --timeout 60s --concurrency "$FLUTTER_CONCURRENCY" --total-shards "$APP_SHARD_COUNT" --shard-index "$shard" \
    test/screens/system_admin/system_admin_snapshot_tabs_test.dart
  step "Run native transfer test for shard $shard" run_in apps/ssh_mobile_full timeout --signal=TERM --kill-after=30s "$APP_TIMEOUT" \
    env "XDG_CONFIG_HOME=$flutter_config_root" "${FLUTTER_LOCAL_TEST_ENV[@]}" flutter test --no-pub --reporter compact --fail-fast --timeout 60s --concurrency "$FLUTTER_CONCURRENCY" \
    --total-shards "$APP_SHARD_COUNT" --shard-index "$shard" "$non_coverage_file"
}

job_app_unit_0() { job_app_unit 0; }
job_app_unit_1() { job_app_unit 1; }
job_app_unit_2() { job_app_unit 2; }
job_app_unit_3() { job_app_unit 3; }

job_app_coverage() {
  need dart || return "$SKIP_STATUS"
  local -a coverage_args=()
  local -a source_args=(--source-root=lib)
  local shard isolated
  local coverage_base_ref="${FULL_TEST_COVERAGE_BASE_REF:-${CI_BASE_SHA:-${GITHUB_BASE_SHA:-${GITHUB_EVENT_BEFORE:-}}}}"
  if [[ -n "$coverage_base_ref" ]]; then
    source_args+=("--base-ref=$coverage_base_ref")
  fi
  for ((shard = 0; shard < APP_SHARD_COUNT; shard++)); do
    coverage_args+=("--file=$LOG_DIR/coverage/full-test-shard-$shard/lcov.info")
    for isolated in startup system-admin; do
      coverage_args+=("--file=$LOG_DIR/coverage/full-test-shard-$shard/isolated-$isolated-lcov.info")
    done
  done
  step 'Enforce Full App coverage (90% minimum)' run_in apps/ssh_mobile_full dart run tool/check_coverage.dart --minimum=90 "${coverage_args[@]}" "${source_args[@]}"
}

job_android() {
  need flutter || return "$SKIP_STATUS"
  local android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -n "$android_sdk" && ! -d "$android_sdk/platforms/android-36" ]]; then
    echo "ENVIRONMENT GAP: Flutter 3.47.0 requires $android_sdk/platforms/android-36; install platforms;android-36."
    return "$SKIP_STATUS"
  fi
  step 'Build Android debug APK' run_in apps/ssh_mobile_full flutter build apk --debug --no-pub
  step 'Test Android widget storage and per-file coverage' run_in apps/ssh_mobile_full/android \
    ./gradlew :android_server_widgets:verifyWidgetCoverage --no-daemon --console=plain
  step 'Compile Android widget device tests' run_in apps/ssh_mobile_full/android \
    ./gradlew :app:assembleDebugAndroidTest --no-daemon --console=plain
}
