Last updated: 2026-10-29

# android_server_widgets

Android-only Flutter Plugin for the native server monitoring AppWidget and its
application-private latest-sample cache. The Full App converts existing
`feature_monitoring` samples into this package's DTOs. Jetpack Glance reads the
cache and renders without a Flutter Engine.

## Responsibility and public API

- Dart entry point: `package:android_server_widgets/android_server_widgets.dart`.
  `MonitoringWidgetSnapshotV1` normalizes metrics and timestamps;
  `MonitoringWidgetServer` contains only an internal connection ID and a safe
  display name. `MonitoringWidgetPlatform` is implemented by
  `MethodChannelMonitoringWidgets` on `ssh_mobile/android_server_widgets`.
- Native entry points: `MonitorSnapshotRepository` reads per-server snapshots
  and the safe directory. `AndroidServerWidgetsPlugin` binds the channel to
  application-private DataStore storage.
- `ServerMonitorWidgetReceiver` registers the standard Android AppWidget;
  `WidgetConfigurationActivity` selects a server from the safe native directory.
  `WidgetInstanceRepository` owns the separate `appWidgetId → connectionId`
  mapping. `WidgetStateMapper` formats four metrics, status and absolute sample
  time independently of Android views.
- `MonitoringWidgetNavigationChannel` delivers bounded cold/warm navigation
  hints. The App checks its current Connection directory before navigating.
- The package depends on Flutter, Android DataStore and Kotlin coroutines. It
  has no dependency on Features, Connection Repository, SSH or the Network SDK.
  It starts no sampler, service, timer, automatic connection or runtime.

## Home-screen Widget

Add SSH Mobile from the launcher's standard Widgets picker, then select a server.
An empty directory offers to open SSH Mobile to add a connection. Configuration
starts cancelled and reports success only after persisting the chosen instance
and requesting its first Glance update. Cancelling changes no instance mapping.

Responsive layouts cover compact 2×2 and expanded 4×2 home-screen grids. These
are launcher grid descriptions; the layouts respond to actual available dp.
Both show CPU, memory, total network throughput, total disk I/O and sample time;
the expanded layout also shows CPU/memory progress. They follow system light or
dark mode. Names may truncate; metrics remain visible with larger fonts.

Each instance selects its own server. Deleting an instance removes only its
mapping and never stops monitoring or removes another instance's data. Import
reset invalidates old mappings; a removed server shows an explicit removed
state. Configuration and rendering only read the safe native cache.

Clicking opens the existing Flutter client through a private native launch
Activity. The App route host waits for startup and validates the ID again;
missing servers return to the home route. Intent hints never start SSH,
monitoring or a remote action.

After a successful snapshot write, the native dispatcher explicitly updates
Glance instances mapped to changed servers. Its pure planner coalesces ordinary
sample redraws to at least fifteen seconds; initial/state/name/removal changes
request an immediate redraw. DataStore persistence alone is not a redraw.
Android may delay background execution. The Widget always shows an absolute
last-sample time and cached data, without promising a live SSH session.
An active Glance composition observes safe snapshot and instance-mapping Flows;
it does not capture the first state for the lifetime of a Worker. Glance owns
and cancels those collections with the composition. Each collection applies the
same fifteen-second ordinary-sample budget, so observation cannot bypass the
dispatcher. A later existing data event publishes the newest eligible sample;
status, first-sample, name and removal changes remain immediate. Inactive
Widgets still need the explicit update request. Observation does not create a
polling timer.
The same composition owns an application configuration callback. Font scale and
night-mode changes replace its copied configuration context, so an already-live
Worker recomposes responsive variants instead of retaining old sp dimensions.
Disposal unregisters that callback; there is no process-global UI observer.

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

Instance mappings use the separate private
`server-monitor-widget-instances-v1.bin` file, also excluded from backup and
bounded to 100 instances. It contains IDs only. Widget deletion, catalog reset,
and Android restore callbacks use their own explicit mapping lifecycle.

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
`AndroidServerWidgetsPlugin`, `MonitorSnapshotStorage`, `WidgetUpdateDispatcher`,
`ServerMonitorWidget`, `ServerMonitorWidgetReceiver`, `WidgetConfigurationActivity`
and `WidgetLaunchActivity` bind Android Context, lifecycle, Glance RemoteViews or
Activity calls. Their platform calls require Android device acceptance and are
excluded from the JVM line metric. State mapping, refresh planning, navigation
inbox, instance persistence and serialization remain in the per-file JVM gate.
Dart DTO and channel behavior have independent tests;
App bridge and lifecycle tests live in the Full App.
The Dart gate measures all implementation files under `lib/src/`; the public
`lib/android_server_widgets.dart` barrel only exports APIs and has no executable
behavior. Existing core-quality CI and its host-native script counterparts run
both the Dart coverage tests and this per-file gate.

Emulator acceptance must verify four real monitor metrics and their timestamp,
stop/failure transitions and process recreation with the existing sampler.
JVM fixtures do not establish Redmi K50/HyperOS or vivo X100/OriginOS behavior.

### Independent Android fixture

The Full App's `test/android/widget_fixture/WidgetInstrumentation.kt` runs against
an installed debug App and its test APK. CI compiles it with
`:app:assembleDebugAndroidTest`; this is not a claim that a device ran it.
The runner requires an empty fixture-only native server/mapping directory and
refuses to replace existing data. It seeds local synthetic readings exclusively
in test code; it does not connect to a real server or start monitoring.

```sh
adb -s <development-emulator> shell am force-stop com.example.ssh_mobile
adb -s <development-emulator> shell am instrument -w com.example.ssh_mobile.test/com.example.ssh_mobile.test.WidgetInstrumentation
```

The fixture checks provider discovery, native configuration cancel/select,
compact/expanded cached rendering, the 130 dp minimum at font scale 2,
larger-font night rendering, instance
isolation/deletion and launching the existing Flutter Activity. It captures
only its synthetic host views to the App's external cache, including
`widget-fixture-compact.png`, `widget-fixture-compact-minimum-large-font.png`,
`widget-fixture-expanded-mid-grid.png` and `widget-fixture-expanded-large-night.png`.
The 260 dp expanded case also checks both progress bars. The active composition
must retain its CPU reading through the fifteen-second ordinary-sample budget,
then display the next persisted sample and an immediate failure/recovery state.
Device font scale and night mode are
temporarily changed on the selected development emulator and restored in cleanup.
It runs cached rendering before opening any Flutter Activity. This complements
the Dart route tests; it does not establish warm/cold route UI behavior on both
target launchers, real SSH metrics, reboot/Doze behavior or real-device power use.

If the instrumentation process itself crashes, restore the emulator's recorded
font/night preferences first. The test-only runner accepts `-e cleanupOnly true`
for recovery; it refuses any server or instance entry outside its fixed
`widget-fixture-a`/`widget-fixture-b` fixtures before deleting its owned host and
records. Recovery is a separate operation and does not count as a test pass.
The independent `-e restoreBoundaryOnly true` probe is emulator-only and checks
that an invalid restore cannot escape the asynchronous Receiver or change maps.

Physical-device runs use a separately installed test variant with application ID
`com.example.ssh_mobile.widget_test` and the runner argument
`-e preserveSystemConfiguration true`. This mode refuses the regular App ID and
tests every content size at the device's current font scale and night mode;
it never writes or restores global display settings. Its result and PNG names
record the actual tested configuration. Emulator default mode retains the
explicit font-scale-2 and night-mode cases. Isolated test data does not replace
the existing client's connections, credentials, settings or cache.
