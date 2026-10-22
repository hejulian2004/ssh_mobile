import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  testWidgets('WebShare dialog content remains usable on a short viewport', (
    tester,
  ) async {
    final settings = FakeLanShareSettings();
    final viewModel = LanShareViewModel(
      discoveryService: FakeLanDiscoveryService(
        activeWebShare: true,
        shareUrl: 'https://192.168.1.100:53319/?pin=123456',
      ),
      securityService: FakeLanSecurityService(),
      storageService: FakeLanStorageService(),
      transferService: FakeLanTransferService(),
      historyDao: FakeLanHistoryDao(),
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
      ownsRuntime: false,
    );
    addTearDown(() {
      viewModel.dispose();
      settings.dispose();
    });

    tester.view.physicalSize = const Size(400, 350);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: WebShareDialogContent(
              vm: viewModel,
              strings: settings.strings,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(WebShareDialogContent), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'LanManualAddDialog allows text input, pops with result, and survives exit transition',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await LanManualAddDialog.show(
                    context,
                    title: 'Connect to Device',
                    description: 'Please enter target address',
                    hint: 'IP address, IP:Port',
                    cancelLabel: 'Cancel',
                    confirmLabel: 'Connect',
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.byType(LanManualAddDialog), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), '192.168.1.120:53317');
      await tester.pump();

      // Tap confirm button
      await tester.tap(find.text('Connect'));
      // Pump during the route exit transition while dialog widgets are still in tree
      await tester.pump(const Duration(milliseconds: 50));
      // Simulate rebuild/metrics change during exit animation
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(result, '192.168.1.120:53317');
      expect(find.byType(LanManualAddDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('LanManualAddDialog cancels or submits via Enter cleanly', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await LanManualAddDialog.show(
                  context,
                  title: 'Connect to Device',
                  description: 'Please enter target address',
                  hint: 'IP address, IP:Port',
                  cancelLabel: 'Cancel',
                  confirmLabel: 'Connect',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    // 1. Cancel
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(result, isNull);

    // 2. Submit via keyboard action
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  10.0.0.1:8080  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(result, '10.0.0.1:8080');
    expect(tester.takeException(), isNull);
  });
}
