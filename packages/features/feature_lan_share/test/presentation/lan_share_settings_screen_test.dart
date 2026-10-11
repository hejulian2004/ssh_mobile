import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  testWidgets('settings screen renders inside the Feature provider scope', (
    tester,
  ) async {
    final settings = FakeLanShareSettings();
    final viewModel = _createViewModel(settings);
    addTearDown(() {
      viewModel.dispose();
      settings.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
          ChangeNotifierProvider<LanShareViewModel>.value(value: viewModel),
        ],
        child: const MaterialApp(home: LanShareSettingsScreen()),
      ),
    );
    // Avoid waiting on the app-wide frame scheduler.  The settings screen is
    // intentionally mounted without activating the receiver, so one initial
    // frame plus a bounded transition interval is all this test needs.
    await _pumpSettingsRoute(tester);

    expect(find.byType(LanShareSettingsScreen), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings screen opens the route-scoped Relay editor', (
    tester,
  ) async {
    final settings = FakeLanShareSettings();
    final viewModel = _createViewModel(settings);
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final coordinator = LanReceiverCoordinator(
      appSettings: settings,
      logger: FakeLanShareLogger(),
      dataProtection: FakeLanShareDataProtection(),
      networkIdentity: FakeLanShareIdentity(),
      networkAccess: FakeLanShareNetworkAccessPort(),
      bootstrapClient: FakeLanShareBootstrapClient(),
      historyRepository: LanShareHistoryRepository(database),
      networkRuntime: FakeLanShareNetworkRuntime(),
      initializeNetwork: false,
    );
    var coordinatorClosed = false;
    addTearDown(() async {
      if (!coordinatorClosed) {
        await coordinator.close().timeout(const Duration(seconds: 2));
      }
      await database.dispose();
      viewModel.dispose();
      settings.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
          ChangeNotifierProvider<LanShareViewModel>.value(value: viewModel),
          ChangeNotifierProvider<LanReceiverCoordinator>.value(
            value: coordinator,
          ),
        ],
        child: const MaterialApp(home: LanShareSettingsScreen()),
      ),
    );
    await _pumpSettingsRoute(tester);

    await tester.tap(find.byIcon(Icons.hub_outlined));
    await _pumpSettingsRoute(tester);

    expect(find.byType(TextField), findsNWidgets(3));
    expect(tester.takeException(), isNull);

    // Close the route before teardown so its controllers and listeners are
    // detached before the shared coordinator/database are released.
    await tester.tap(find.byType(TextButton).last);
    await _pumpSettingsRoute(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await coordinator.close().timeout(const Duration(seconds: 2));
    coordinatorClosed = true;
  });

  testWidgets(
    'settings screen renames device alias cleanly without controller lifecycle error',
    (tester) async {
      final settings = FakeLanShareSettings();
      final viewModel = _createViewModel(settings);
      addTearDown(() {
        viewModel.dispose();
        settings.dispose();
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ListenableProvider<LanShareSettingsPort>.value(value: settings),
            ChangeNotifierProvider<LanShareViewModel>.value(value: viewModel),
          ],
          child: const MaterialApp(home: LanShareSettingsScreen()),
        ),
      );
      await _pumpSettingsRoute(tester);

      await tester.tap(find.byIcon(Icons.drive_file_rename_outline_rounded));
      await _pumpSettingsRoute(tester);

      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'My New Device');
      await tester.tap(find.text(settings.strings.save));
      await tester.pump(const Duration(milliseconds: 50));
      await _pumpSettingsRoute(tester);

      expect(tester.takeException(), isNull);
      expect(settings.lanDeviceAlias, 'My New Device');
    },
  );
}

Future<void> _pumpSettingsRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

LanShareViewModel _createViewModel(FakeLanShareSettings settings) =>
    LanShareViewModel(
      discoveryService: FakeLanDiscoveryService(),
      securityService: FakeLanSecurityService(),
      storageService: FakeLanStorageService(),
      transferService: FakeLanTransferService(),
      historyDao: FakeLanHistoryDao(),
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
      ownsRuntime: false,
    );
