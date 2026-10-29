Last updated: 2026-10-29

# android_server_widgets maintenance contract

- Own the Android-only Flutter Plugin, versioned safe snapshot DTO/channel,
  Kotlin latest-sample repository and application-private DataStore cache.
  Also owns standard Glance presentation, native configuration, per-instance
  bindings and the native navigation hint; Feature business stays in the App.
- Depend only on public Flutter/platform libraries. Never depend on
  `feature_monitoring`, `ConnectionRepository`, SSH or Network SDK; App Shell
  supplies safe directory entries and converted snapshots through public APIs.
- Never store IP/host, port, SSH username, password, private key, token, host key,
  full server configuration, remote output or a monitoring history. Bound the
  directory, IDs, names, collections and serialized input before allocation.
  Revalidate channel data on Kotlin ingress as well as in Dart.
- A sample's timestamp and the monitoring state are separate. Invalid metrics
  stay unknown. Read-time expiry uses absolute time and the effective interval;
  never manufacture live data or replace it with demonstration values.
- AppRuntime owns the App writer; a newer native writer session invalidates an
  older Engine. Persist writes transactionally with monotonic sequence checks.
  Prune removed servers and invalidate replaced/imported configurations. A
  failed write must remain a failure; corrupt/unreadable storage reads as safe
  no data, never an alternate in-memory persistence backend.
- Flutter Engine detach cancels only channel work. The application-private
  DataStore owner survives Engine recreation; borrowers never close it. Do not
  create an SSH sampler, AppRuntime, NetworkRuntime, foreground service,
  WakeLock, reconnect loop or periodic Timer here.
- No business logic in MainActivity. Platform wrappers emit bounded error codes
  without arguments, exception details, paths or private data. New behavior uses
  deterministic independent tests before implementation; production files stay
  below 500 lines through responsibility-based decomposition.
- Glance reads persisted snapshots without Flutter. Use actual responsive dp,
  keep four metrics and absolute sample time visible, and follow system theme.
  Rendering must never construct an AppRuntime or connect to a server.
  Glance composition owns both DataStore Flow collections and the native
  configuration callback; cancel/unregister them on composition disposal.
  Font-scale changes must recompose live responsive variants, without a Timer
  or a process-global UI observer.
- Persist only the selected ID for each real Widget instance. Cancellation does
  not configure it; deletion removes only that mapping. Revalidate the safe
  directory on save and the App's current Connection directory on navigation.
  Imported configuration invalidates old selections. A click is a navigation
  hint only and never authorizes a connection, command or monitoring start.
- A persisted snapshot requires an explicit Glance update. Use the pure refresh
  planner for targeted fifteen-second sample coalescing and immediate state,
  first-sample, name and deletion updates. Active Flow collection applies the
  same budget, publishing on the next existing data event; no polling loop.

## Required checks

Run package format/analyze/Dart tests and the Gradle
`:android_server_widgets:verifyWidgetCoverage` gate from the Full App Android
project. New Dart and pure Kotlin production files require independent tests
and at least 90% file line coverage. Engine/Context platform glue is excluded
only with the README's device-validation reason. Keep App dependency, workspace,
manifest, CI scopes and owner/dependency documentation synchronized. Run
architecture, module-dependency, resource-owner, compatibility, file-size and
documentation checks after boundary changes, then `git diff --check`. Report
Android emulator and real-device evidence separately from JVM/Dart results.
