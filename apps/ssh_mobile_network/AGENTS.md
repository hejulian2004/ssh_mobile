最新更新时间：2026-10-09

# Network-transfer App Guidelines

- This App hosts the Network Transfer page from `feature_lan_share`. It owns
  one `NetworkRuntime`, LAN settings, network identity, data protection, and
  the control-plane HTTP executor. `LanShareModule` owns `lan_share.db`.
- Do not copy Full App services. `NativeNetworkService` remains the only
  production `SessionClient` and stays in `apps/ssh_mobile_full/`. This App's
  `LanShareNetworkAccessPort.borrowFacade` returns null, so native file
  transfer and the relay data plane are not available here.
- `NetworkTransportAppRuntime` is the App Scope owner. The root State is an
  awaitable, idempotent exit owner. It removes the route first, then disposes
  the module, settings, runtime, and logger. The Feature must not dispose the
  runtime.
- `create` enables the LAN receiver. The receiver may ensure only
  `NetworkCapability.runtime`. Do not enable QUIC, WebSocket Relay, or
  Realtime from this shell, and do not call `NetworkFacade.start`.
- Screen share is fail-closed. Do not import `feature_screen_share`.
- Local IPv4 selection uses `LanShareSingleCandidateLocalAddressSelection`.
- Use only public package entry points. Do not import `ssh_core`,
  `feature_terminal`, `feature_connection`, `feature_sftp`, `feature_ai`,
  `feature_screen_share`, `dartssh2`, or `ssh_mobile_full`.
- Identity and data-protection keys use `network_app_*_v1` names. Do not reuse
  Full App secure-storage keys.

## Validation for code changes

`flutter pub deps`, `flutter analyze`, and `flutter test` (package-local;
local aggregate CI remains user-opt-in). Dependency output for this package
must contain `feature_lan_share`, `network_sdk`, and `network_transport`, and
must not contain `ssh_core`, `feature_terminal`, `feature_connection`,
`feature_sftp`, `feature_ai`, `feature_screen_share`, or `dartssh2`.

`lib/main.dart` and `NetworkAppBootstrap.run` are process-entry exclusions.
`NetworkTransportAppRuntime.create` and `FlutterNetworkSecretStore` are
platform-entry exclusions: they bind secure storage and the platform LAN
database. Tests use `NetworkTransportAppRuntime.open` with an in-memory
secret store and `LanShareDatabase.forTesting`. Widget tests place the
feature's existing inherited `LanShareViewModel` above the app so the page
renders without starting mDNS or UDP. Those tests do not wait for receiver
close after the pairing host initializes services. The non-widget close test
covers that release. Do not add a test-only hook to execute `main` or
`create`, and do not add one to replace that view model.
