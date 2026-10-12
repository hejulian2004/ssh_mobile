import 'dart:async';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

import '../fakes/lan_pairing_test_harness.dart';

void main() {
  testWidgets(
    'PIN connection disables input and allows termination without late navigation',
    (tester) async {
      final harness = LanPairingTestHarness();
      addTearDown(harness.dispose);
      final pending = Completer<NetworkResult<LanPairingHandshakeProgress>>();
      harness.viewModel.pendingResult = pending.future;
      await harness.pump(tester);
      await tester.enterText(find.byType(TextField), '123456');
      final confirm = find.widgetWithText(ElevatedButton, '确认配对');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pump();
      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(harness.viewModel.authCalls, 1);
      final terminate = find.text('Terminate');
      await tester.ensureVisible(terminate);
      await tester.tap(terminate);
      await tester.pump();
      expect(harness.viewModel.cancelCalls, 1);
      pending.complete(
        const NetworkSuccess(LanPairingHandshakeProgress.paired),
      );
      harness.transfer.emitHandshake(pairingTestPeer);
      await tester.pump();
      expect(find.byType(LanChatScreen), findsNothing);
    },
  );
}
