import 'dart:async';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:feature_lan_share/src/features/lan_share/views/widgets/lan_share_self_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_ui/app_ui.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  testWidgets(
    'self bar keeps automatic and manual address selection distinct',
    (tester) async {
      var selects = 0;
      var refreshes = 0;
      for (final custom in <String?>[null, '192.0.2.2']) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LanSelfDeviceInfoBar(
                alias: 'Local',
                strings: FakeLanShareStrings(),
                interfaces: Future.value({
                  '192.0.2.1': 'adapter-a',
                  '192.0.2.2': 'adapter-b',
                }),
                customIp: custom,
                selection: const LanShareLocalAddressSelected(
                  LanShareLocalIpv4Candidate(
                    address: '192.0.2.1',
                    interfaceName: 'adapter-a',
                    interfaceIndex: 1,
                  ),
                ),
                refreshing: false,
                onSelect: () => selects++,
                onRefresh: () => refreshes++,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.textContaining('active', findRichText: true),
          findsOneWidget,
        );
        await tester.tap(
          find.textContaining('This Device', findRichText: true),
        );
        await tester.pump();
        await tester.tap(find.byIcon(Icons.refresh_rounded));
        await tester.pump();
      }
      expect(selects, 2);
      expect(refreshes, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'self bar shows loading and disables refresh while work is pending',
    (tester) async {
      final pending = Completer<Map<String, String>>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LanSelfDeviceInfoBar(
              alias: 'Local',
              strings: FakeLanShareStrings(english: false),
              interfaces: pending.future,
              refreshing: true,
              onSelect: () {},
              onRefresh: () => fail('Refresh must be disabled'),
            ),
          ),
        ),
      );
      expect(find.textContaining('获取中', findRichText: true), findsOneWidget);
      expect(find.byType(AppLoadingIndicator), findsOneWidget);
      pending.complete({});
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
