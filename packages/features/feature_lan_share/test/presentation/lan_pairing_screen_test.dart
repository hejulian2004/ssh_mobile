import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

import '../fakes/lan_pairing_test_harness.dart';

void main() {
  testWidgets('one verified PIN stays on the pairing page', (tester) async {
    final harness = LanPairingTestHarness();
    addTearDown(harness.dispose);

    await harness.pump(tester);
    harness.transfer.emitDirection(
      const LanPairingDirectionNotice(
        peerId: 'peer-1',
        outboundVerified: false,
        inboundVerified: true,
      ),
    );
    await tester.pump();

    expect(find.byType(LanPairingScreen), findsOneWidget);
    expect(find.byType(LanChatScreen), findsNothing);
    expect(
      find.text(
        'The other device entered this PIN. Enter the PIN shown on that device.',
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), '123456');
    await tester.ensureVisible(find.text('确认配对'));
    await tester.tap(find.text('确认配对'));
    await tester.pump();

    expect(harness.viewModel.authCalls, 1);
    expect(find.byType(LanChatScreen), findsNothing);
    expect(
      find.text(
        'Your entry is confirmed. Waiting for the other device to enter this PIN.',
      ),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('123456'), findsOneWidget);
  });

  testWidgets('chat opens after both PIN directions are verified', (
    tester,
  ) async {
    final harness = LanPairingTestHarness();
    addTearDown(harness.dispose);
    await harness.pump(tester);

    harness.viewModel.nextResult = const NetworkSuccess(
      LanPairingHandshakeProgress.paired,
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), '123456');
    final button = find.widgetWithText(ElevatedButton, '确认配对');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    // Predictive-back keeps the outgoing route mounted for 450ms.
    await tester.pump(const Duration(milliseconds: 500));

    expect(harness.viewModel.authCalls, 1);
    expect(find.byType(LanChatScreen), findsOneWidget);
    expect(find.byType(LanPairingScreen), findsNothing);
  });

  testWidgets('network timeout is not shown as an incorrect PIN', (
    tester,
  ) async {
    final harness = LanPairingTestHarness();
    harness.viewModel.nextResult = const NetworkFailure(
      NetworkError(
        code: NetworkErrorCode.timeout,
        message: 'LAN operation timed out.',
        operation: NetworkOperation.sendHandshake,
      ),
    );
    addTearDown(harness.dispose);
    await harness.pump(tester);

    await tester.enterText(find.byType(TextField), '123456');
    final button = find.widgetWithText(ElevatedButton, '确认配对');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();

    expect(
      find.text(
        'Pairing timed out. Check that both devices are on the same Wi-Fi.',
      ),
      findsOneWidget,
    );
    expect(find.text('Incorrect PIN code'), findsNothing);
  });

  testWidgets(
    'pairing uses the active invitation endpoint before discovery catches up',
    (tester) async {
      final harness = LanPairingTestHarness();
      harness.viewModel.exposePeerState = false;
      addTearDown(harness.dispose);

      await harness.pump(tester, initialPeer: pairingTestPeer);
      await tester.enterText(find.byType(TextField), '123456');
      final button = find.widgetWithText(ElevatedButton, '确认配对');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();

      expect(harness.viewModel.authCalls, 1);
      expect(find.byType(LanPairingScreen), findsOneWidget);
    },
  );

  testWidgets('handshake success opens chat for the waiting device', (
    tester,
  ) async {
    final harness = LanPairingTestHarness();
    addTearDown(harness.dispose);
    await harness.pump(tester);

    harness.transfer.emitHandshake(pairingTestPeer);
    await tester.pump();
    // Predictive-back keeps the outgoing route mounted for 450ms.
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(LanChatScreen), findsOneWidget);
    expect(find.byType(LanPairingScreen), findsNothing);
  });
}
