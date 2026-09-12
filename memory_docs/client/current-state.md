> Last updated: 2026-09-12

# Client Current State

`apps/ssh_mobile_full/` is the complete maintained application;
`apps/ssh_mobile_terminal/` validates the minimal Terminal-only dependency crop.
Owners are Core (app/UI/Telemetry/Connection), Features (Connection, Terminal,
SFTP, Monitoring, System Administration, LAN Share, Playbook, RAG, MCP, AI,
WebView, Developer), and App-scoped SSH infrastructure. Legacy Full App paths
remain only for consumers listed in the [compatibility inventory](../../docs/architecture/COMPATIBILITY_MIGRATION_INVENTORY.md);
new code belongs in the owning package.

Feature/Core persistence is split by owner. No shared business DB exists and a
production DB-open failure never falls back to memory. Telemetry uses isolated
`DriftTelemetryStorage` at `${supportDirectory}/telemetry.sqlite`; transactional
FIFO overflow evicts only `synced`, preserving `pending` and `rejected`.
New recording is gated by valid Relay enrollment; when that gate is closed no
new event row or record-cache write is issued. `uploadEnabled=false` pauses
uploads but does not disable local recording.
Network runtime/public contracts route to the [SDK domain](../sdk/current-state.md)
even when AppRuntime creates the facade.

## Screen-share flow

The Full App exposes screen sharing as a secondary action on trusted online LAN
peer cards and as a global incoming request host. Outgoing flow selects an
App-issued route-scoped source token, creates a valid 32-character lowercase
hex Realtime ID, waits only for Negotiating identity, then lets the Feature
send REQUEST. Incoming Dart metadata is published only after native pairs an
authenticated Offer with the complete typed REQUEST. Accept pre-registers the
SDK responder before native claim/Answer, seeds the original REQUEST once, sends
ACCEPT immediately, and gates viewer/capture on Connected plus matching
generation/shared-session identity. Route cleanup is role-aware and never stops
App Runtime.

## Validation

Local aggregate CI is user-opt-in; when requested, run the host-native root
script. Otherwise use the owning App/package focused gates:

```bash
cd apps/ssh_mobile_full
flutter analyze
flutter test
```

The periodic Client Network V2 gate is separate:

```bash
bash scripts/bash/coverage/client_coverage.sh --no-bootstrap
```

It covers the App-owned Network V2 boundary, not all UI. A WSL Flutter VM
Service failure may use a working `CLIENT_FLUTTER_BIN` and documented
`SSH_MOBILE_DISABLE_DART_PROFILING=1` workaround in
[`docs/COVERAGE_POLICY.md`](../../docs/COVERAGE_POLICY.md); ordinary test pass is
not coverage pass. Coverage remains 90%, including the independent-test rule for
new hand-written production files.

## Windows boundary

WSL owns Linux validation. Native Windows is a separate platform check or Client
coverage fallback when WSL Flutter cannot start, and does not turn a WSL gap into
a pass. Keep the WSL and native Windows checkouts independent and synchronize
them only through Git; do not edit the Windows-mounted tree as if it were the
WSL worktree. Use native PowerShell 7, pinned Flutter 3.47.0/Dart 3.13.0 and Rust
1.97.1 MSVC, configured by
[`configure_windows_toolchain.ps1`](../../scripts/powershell/platform/configure_windows_toolchain.ps1)
with explicit `-FlutterRoot`; keep PATH/TEMP/TMP/Cargo/Rustup/cache/build paths
isolated. A deliberate WSL interop invocation may call native PowerShell for a
Windows checkout test, but it must preserve the same checkout/toolchain/cache
boundary and must not turn shared files into a synchronization mechanism.
`-PersistUserPath` is the only user-PATH mutation; native coverage clears
inherited WSL `TMPDIR`.

Windows MSI uses the same native PowerShell/path boundary and native SDK temp
directory. `-SuppressIceValidation` is only an explicit host-gap escape hatch;
normal hosts keep ICE enabled.

## Native Windows client/MSI checklist

From a native checkout in `pwsh.exe`, use placeholders `<native-repo>`,
`<flutter-root>`, and `<native-temp>`:

1. Configure and bootstrap:

   ```powershell
   Set-Location '<native-repo>'
   . .\scripts\powershell\platform\configure_windows_toolchain.ps1 -FlutterRoot '<flutter-root>' -TempRoot '<native-temp>'
   & '<flutter-root>\bin\flutter.bat' pub get
   ```

   Keep this process for remaining commands; omit `-TempRoot` only for the
   default native temp.
2. Run the App Network V2 coverage selection and 90% check:

   ```powershell
   Set-Location '<native-repo>\apps\ssh_mobile_full'
   & '<flutter-root>\bin\flutter.bat' test --no-pub --no-test-assets --coverage --coverage-path '<native-temp>\client-windows-lcov.info' --reporter expanded test/services/network/network_protocol_v2_codec_test.dart test/services/network/transfer_transport_test.dart test/app/realtime_feature_adapters_test.dart test/app/app_runtime_test.dart
   & '<flutter-root>\bin\dart.bat' run tool/check_coverage.dart --minimum=90 --details --file='<native-temp>\client-windows-lcov.info' --include=lib/services/network/
   ```

3. Build MSI from repository root:

   ```powershell
   Set-Location '<native-repo>'
   & .\scripts\powershell\platform\build_windows_msi.ps1 -Flutter '<flutter-root>\bin\flutter.bat' -Version '1.0.0'
   ```

   It runs `flutter build windows`, stages output, and writes
   `build\windows_msi\out\SSH_Mobile_Windows_v<version>_setup.msi`, downloading
   WiX 3.14.1 if needed. If ICE fails with `LGHT0217`, use
   `-SuppressIceValidation`, record the gap, and perform structural validation;
   normal hosts keep ICE.
4. Without system-wide install, decompile/extract with WiX `dark.exe`:

   ```powershell
   & '<wix-root>\dark.exe' -nologo -x '<native-temp>\msi-dark' -o '<native-temp>\SSH_Mobile_Windows.wxs' '<native-repo>\build\windows_msi\out\SSH_Mobile_Windows_v1.0.0_setup.msi'
   ```

   Require exit 0, generated WXS, non-empty extracted files, and non-zero MSI
   size/hash. Do not reuse WSL temp/cache; inspect/stop only workflow-owned
   processes.
