import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart' as lan;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import 'package:ssh_mobile/app/screen_share_incoming_request_host.dart';
import 'package:ssh_mobile/app/screen_share_peer_arbitration.dart';

import 'support/app_runtime_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a losing incoming intent does not invalidate the current expiry owner',
    (tester) async {
      final commandGateway = FakeCommandGateway();
      final network = FakeNetworkRuntime(
        realtimeGateway: RuntimeNetworkRealtimeGateway(commandGateway),
      );
      final harness = await newRuntimeHarness(
        networkRuntime: network,
        disposeLogger: false,
        startPendingInitialization: false,
      );
      final runtime = await harness.createFuture;
      final navigatorKey = GlobalKey<NavigatorState>();
      final arbitration = AppScreenSharePeerArbitrationRegistry();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await runtime.dispose();
        await harness.close();
        await commandGateway.close();
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: AppScreenShareIncomingRequestHost(
            runtime: runtime,
            navigatorKey: navigatorKey,
            screenSharePort: const _TestScreenSharePort(),
            arbitration: arbitration,
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      );

      final warmup = runtime.realtimeClient.createSession(
        realtimeId: '00112233445566778899aabbccddee00',
        peerId: 'peer-a',
      );
      // Opening the lazy realtime gateway is enough to install the backend
      // event subscription. Keep the command-result round trip out of this
      // Host-only regression; AppRuntime disposal force-cleans the helper
      // session if its start remains pending.
      unawaited(warmup.start());
      await tester.pump();

      final now = DateTime.now().toUtc();
      commandGateway.emitEvent(
        _incomingOfferEvent(
          realtimeId: '00112233445566778899aabbccddee11',
          sharedSessionInstanceId: 'ffeeddccbbaa99887766554433221100',
          operationId: 'operation-a',
          bindingExpiry: now.add(const Duration(milliseconds: 250)),
        ),
      );
      await tester.pump();
      expect(find.text('Incoming screen-share request'), findsOneWidget);

      // The deterministic comparator makes operation-z lose to operation-a.
      // The losing callback must not advance the Host epoch or cancel A's
      // timer.
      commandGateway.emitEvent(
        _incomingOfferEvent(
          realtimeId: '00112233445566778899aabbccddee22',
          sharedSessionInstanceId: '11223344556677889900aabbccddeeff',
          operationId: 'operation-z',
          bindingExpiry: now.add(const Duration(seconds: 5)),
        ),
      );
      await tester.pump();
      expect(find.text('Incoming screen-share request'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Incoming screen-share request'), findsNothing);
    },
  );
}

final class _TestScreenSharePort implements lan.LanShareScreenSharePort {
  const _TestScreenSharePort();

  @override
  bool canReceiveScreenShareFrom(String peerId) => peerId == 'peer-a';

  @override
  bool canShareWith(String peerId) => false;

  @override
  Future<void> startScreenShare(String peerId) async {}
}

Uint8List _incomingOfferEvent({
  required String realtimeId,
  required String sharedSessionInstanceId,
  required String operationId,
  required DateTime bindingExpiry,
}) {
  final now = DateTime.now().toUtc();
  final request = NativeNetworkProtocol.encodeScreenShareConsent(
    NativeScreenShareConsent(
      schemaVersion: 2,
      operationId: operationId,
      realtimeId: realtimeId,
      sharedSessionInstanceId: sharedSessionInstanceId,
      issuedAtMs: now.millisecondsSinceEpoch,
      expiresAtMs: now.add(const Duration(seconds: 2)).millisecondsSinceEpoch,
      decision: NativeScreenShareConsentDecision.request,
      senderPeerId: 'peer-a',
      purpose: NativeScreenShareConsentPurpose.screenShare,
      media: NativeScreenShareMediaKind.screenVideo,
      requiresAcceptance: true,
      actionRevision: 1,
    ),
  );
  final offer = <int>[
    ..._bytesField(1, utf8.encode('offer-$operationId')),
    ..._bytesField(2, utf8.encode('claim-$operationId')),
    ..._bytesField(3, utf8.encode(realtimeId)),
    ..._bytesField(4, utf8.encode('peer-a')),
    ..._bytesField(5, utf8.encode(sharedSessionInstanceId)),
    ..._varintField(6, bindingExpiry.millisecondsSinceEpoch),
    ..._bytesField(7, request),
  ];
  return Uint8List.fromList(_eventFrame(34, offer));
}

List<int> _eventFrame(int eventField, List<int> payload) => <int>[
  ..._bytesField(1, utf8.encode('screen-share-host-test')),
  ..._varintField(2, DateTime.now().millisecondsSinceEpoch),
  ..._varintField(3, 2),
  ..._bytesField(eventField, payload),
];

List<int> _varintField(int fieldNumber, int value) => <int>[
  ..._varint(fieldNumber << 3),
  ..._varint(value),
];

List<int> _bytesField(int fieldNumber, List<int> value) => <int>[
  ..._varint((fieldNumber << 3) | 2),
  ..._varint(value.length),
  ...value,
];

List<int> _varint(int value) {
  final bytes = <int>[];
  var remaining = value;
  do {
    final next = remaining & 0x7f;
    remaining >>= 7;
    bytes.add(remaining == 0 ? next : next | 0x80);
  } while (remaining != 0);
  return bytes;
}
