Last updated: 2026-10-29

# android_server_widgets

Android-only Flutter Plugin for an application-private, latest-sample server
monitoring cache. The Full App converts existing `feature_monitoring` samples
into this package's DTOs. Kotlin can read the cache without a Flutter Engine.
This phase provides the data bridge; desktop Widget presentation and instance
configuration are separate deliveries.

## Responsibility and public API

- Dart entry point: `package:android_server_widgets/android_server_widgets.dart`.
  `MonitoringWidgetSnapshotV1` normalizes metrics and timestamps;
  `MonitoringWidgetServer` contains only an internal connection ID and a safe
  display name. `MonitoringWidgetPlatform` is implemented by
  `MethodChannelMonitoringWidgets` on `ssh_mobile/android_server_widgets`.
- Native entry points: `MonitorSnapshotRepository` reads per-server snapshots
  and the safe directory. `AndroidServerWidgetsPlugin` binds the channel to
  application-private DataStore storage.
- The package depends on Flutter, Android DataStore and Kotlin coroutines. It
  has no dependency on Features, Connection Repository, SSH or the Network SDK.
  It starts no sampler, service, timer, automatic connection or runtime.

## Snapshot and storage contract

Schema V1 contains `connectionId`, `displayName`, `sampledAt`, CPU and memory
percentages, total network and disk byte rates, `effectiveIntervalMs`, and
`status`. There is one latest snapshot per server, with no history database.
Directory entries persist only ID and processed display name. Never pass or
persist endpoints, ports, usernames, credentials, tokens, host keys or complete
server configuration.

Percentages outside 0–100 and negative or non-finite rates become unknown.
Invalid sample times clear the readings. Timestamps use UTC epoch milliseconds;
the read-time stale threshold is `max(60 seconds, 3 × effectiveInterval)`.
`notConfigured`, `notStarted`, `waiting`, `active`, `stopped`, `failed` and `stale`
remain distinct. A five-minute interval stays valid for fifteen minutes.

IDs are limited to 128 ASCII letters, digits, hyphens or underscores. Display
names are redacted before truncating to 48 Unicode code points. The App also
removes the selected target's known host and username. Storage accepts at most
100 servers and bounds serialized input to 128 KiB. The cache is
`applicationContext.noBackupFilesDir/server-monitor-snapshots-v1.bin`, excluded
from Android backup. Corrupt, unreadable or unsupported stored data produces
safe no-data reads; failed writes report an error rather than substituting
in-memory persistence.

Each App writer begins a native session and sends increasing sequence numbers.
DataStore transactions reject replaced sessions and older writes. A full safe
directory prunes removed servers. Configuration cutoffs and import reset
invalidate cached observations. Starting a new writer retains the last useful
sample while preventing a previous monitoring run from being reported as live.

## Lifecycle owner

`AppRuntime` owns its `MonitoringWidgetAdapter` and cancels its borrowed monitor
listener and directory subscription before releasing the monitoring Module.
The adapter does not stop monitoring. The native channel's coroutine scope
belongs to the Flutter Engine and is cancelled on detach. The application's
single DataStore owner outlives an Engine and is released with the process;
Widget readers borrow it and never construct AppRuntime or SSH resources.

## Validation

From this package:

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub --coverage
dart run ../../../apps/ssh_mobile_full/tool/check_coverage.dart --minimum=90 --file=coverage/lcov.info --source-root=lib --all-sources --include=lib/src/ --details
```

From `apps/ssh_mobile_full/android`, use the host-native Gradle wrapper:

```sh
./gradlew :android_server_widgets:verifyWidgetCoverage --no-daemon --console=plain
```

On native Windows, invoke `./gradlew.bat` with the same arguments. JVM tests
cover normalization, wire decoding, serialization, actual DataStore persistence,
ordering, invalidation and safe storage failures. The coverage gate requires
90% line coverage per pure Kotlin source file. Host tests use the same-version
DataStore JVM artifact for Windows file replacement; Android builds retain the
Android artifact. Android storage behavior still needs device acceptance.
`AndroidServerWidgetsPlugin`
and `MonitorSnapshotStorage` are Flutter Engine/Android Context bindings;
their platform calls require Android device acceptance and are excluded from
the JVM line metric. Dart DTO and channel behavior have independent tests;
App bridge and lifecycle tests live in the Full App.
The Dart gate measures all implementation files under `lib/src/`; the public
`lib/android_server_widgets.dart` barrel only exports APIs and has no executable
behavior. Existing core-quality CI and its host-native script counterparts run
both the Dart coverage tests and this per-file gate.

Emulator acceptance must verify four real monitor metrics and their timestamp,
stop/failure transitions and process recreation with the existing sampler.
JVM fixtures do not establish Redmi K50/HyperOS or vivo X100/OriginOS behavior.
