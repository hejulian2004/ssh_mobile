> Last updated: 2026-10-23

# Android diagnostic collection

The launcher runs a debug App using the explicit ADB serial. Dart defines carry
the run ID to the App; its diagnostic sink resolves its own private cache path.
Flutter and Rust write separate instance files under
`cache/agent-observability/<run_id>`.

The host uses only `adb -s <serial> exec-out run-as <package>` to list/read that
run's marked diagnostic files. It adds collection timestamps, handles rotation
and retries incomplete final records. Instance IDs distinguish App restarts.
No root, shared-storage export, port mapping or global logcat is required.

A disconnected/unauthorized device, non-debuggable installation, missing run
directory, failed read or deduplication capacity limit produces pending/GAP.
Reconnect and inspect summary again; absence of collected errors is not success.
Host `stop` closes its Flutter launcher and finishes collection. Device-side
retention is Android cache retention; host `clean` never deletes App data.
