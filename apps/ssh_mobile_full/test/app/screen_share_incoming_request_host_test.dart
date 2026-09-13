import 'dart:async';
import 'dart:convert';

import 'package:feature_lan_share/feature_lan_share.dart' as lan;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import 'package:ssh_mobile/app/app_runtime.dart';
import 'package:ssh_mobile/app/screen_share_incoming_request_host.dart';
import 'package:ssh_mobile/app/screen_share_peer_arbitration.dart';
import 'package:ssh_mobile/app/screen_share_route_scope.dart';
import 'package:ssh_mobile/app/navigation/app_route_contributions.dart';

import 'support/app_runtime_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RuntimeHarness harness;
  late AppRuntime runtime;
  late FakeNetworkRuntime network;
  late FakeCommandGateway commandGateway;

  setUp(() async {
    commandGateway = FakeCommandGateway();
    network = FakeNetworkRuntime();
    harness = await newRuntimeHarness(
      networkRuntime: network,
      disposeLogger: false,
      startPendingInitialization: false,
    );
    runtime = await harness.createFuture;
    network.realtimeGateway = RuntimeNetworkRealtimeGateway(commandGateway);
  });

  testWidgets('active replacement ignores stale route completion', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final arbitration = AppScreenSharePeerArbitrationRegistry();
    final installedOperations = <String>[];
    final disposedOperations = <String>[];
    const claimRealtimeIds = <String>[
      '00112233445566778899aabbccddee11',
      '00112233445566778899aabbccddee22',
    ];
    var cleanedUp = false;
    Future<void> cleanUp() async {
      if (cleanedUp) return;
      cleanedUp = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugPrint = debugPrintSynchronously;
      await commandGateway.close();
    }

    addTearDown(cleanUp);
    await _mountHost(
      tester: tester,
      runtime: runtime,
      commandGateway: commandGateway,
      arbitration: arbitration,
      navigatorKey: navigatorKey,
      routeBuilder: (arguments) {
        installedOperations.add(arguments.operationId!);
        return _ControlledScreenShareRoute(
          arguments: arguments,
          onDisposed: (operationId) => disposedOperations.add(operationId!),
        );
      },
    );
    _installCommandAutomation(
      commandGateway,
      claimRealtimeIds: claimRealtimeIds,
      sharedSessionIds: const <String, String>{
        '00112233445566778899aabbccddee11': 'ffeeddccbbaa99887766554433221100',
        '00112233445566778899aabbccddee22': '11223344556677889900aabbccddeeff',
      },
      stopRealtimeIds: const <String>[
        '00112233445566778899aabbccddee11',
        '00112233445566778899aabbccddee22',
      ],
    );
    final discardBaseline = commandGateway.countCommands(
      'realtime-discard-incoming',
    );
    final claimBaseline = commandGateway.countCommands(
      'realtime-claim-incoming',
    );
    final now = DateTime.now().toUtc();

    await _emitOffer(
      tester,
      commandGateway,
      realtimeId: '00112233445566778899aabbccddee11',
      sharedSessionInstanceId: 'ffeeddccbbaa99887766554433221100',
      operationId: 'operation-z',
      bindingExpiry: now.add(const Duration(seconds: 30)),
    );
    await tester.tap(find.text('Accept'));
    await _settle(tester);
    expect(
      commandGateway.countCommands('realtime-claim-incoming') - claimBaseline,
      1,
    );
    expect(installedOperations, <String>['operation-z']);

    // operation-a wins over operation-z for the same initiator. A's route is
    // popped, but its navigation completion must not touch B's Host owner.
    await _emitOffer(
      tester,
      commandGateway,
      realtimeId: '00112233445566778899aabbccddee22',
      sharedSessionInstanceId: '11223344556677889900aabbccddeeff',
      operationId: 'operation-a',
      bindingExpiry: now.add(const Duration(seconds: 30)),
    );
    await _settle(tester);
    expect(disposedOperations, contains('operation-z'));
    expect(find.text('Incoming screen-share request'), findsOneWidget);

    // A worse candidate cannot replace B or invalidate its expiry timer.
    await _emitOffer(
      tester,
      commandGateway,
      realtimeId: '00112233445566778899aabbccddee33',
      sharedSessionInstanceId: '223344556677889900aabbccddeeff00',
      operationId: 'operation-z',
      bindingExpiry: now.add(const Duration(seconds: 30)),
    );
    await _settle(tester);
    expect(find.text('Incoming screen-share request'), findsOneWidget);
    expect(
      commandGateway.countCommands('realtime-discard-incoming') -
          discardBaseline,
      1,
    );

    await tester.tap(find.text('Accept'));
    await _settle(tester);
    expect(
      commandGateway.countCommands('realtime-claim-incoming') - claimBaseline,
      2,
    );
    expect(installedOperations, <String>['operation-z', 'operation-a']);
    await cleanUp();
  });

  testWidgets('accept resolution is not duplicated by expiry', (tester) async {
    final arbitration = AppScreenSharePeerArbitrationRegistry();
    final claimRelease = Completer<void>();
    var claimCount = 0;
    var discardBaseline = 0;
    var cleanedUp = false;
    Future<void> cleanUp() async {
      if (cleanedUp) return;
      cleanedUp = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugPrint = debugPrintSynchronously;
      await commandGateway.close();
    }

    addTearDown(cleanUp);
    await _mountHost(
      tester: tester,
      runtime: runtime,
      commandGateway: commandGateway,
      arbitration: arbitration,
      routeBuilder: (arguments) =>
          _ControlledScreenShareRoute(arguments: arguments, onDisposed: (_) {}),
    );
    commandGateway.commandCompletion = (commandId) async {
      if (commandId.startsWith('realtime-claim-incoming')) {
        claimCount++;
        await claimRelease.future;
        commandGateway.emitEvent(
          _realtimeStateEvent(
            realtimeId: '00112233445566778899aabbccddee44',
            sharedSessionInstanceId: '3344556677889900aabbccddeeff0011',
          ),
        );
        return true;
      }
      if (commandId.startsWith('realtime-stop')) {
        commandGateway.emitEvent(
          _realtimeStateEvent(
            realtimeId: '00112233445566778899aabbccddee44',
            sharedSessionInstanceId: '3344556677889900aabbccddeeff0011',
            state: 4,
            revision: 2,
          ),
        );
      }
      return true;
    };
    discardBaseline = commandGateway.countCommands('realtime-discard-incoming');
    await _emitOffer(
      tester,
      commandGateway,
      realtimeId: '00112233445566778899aabbccddee44',
      sharedSessionInstanceId: '3344556677889900aabbccddeeff0011',
      operationId: 'operation-accept-expiry',
      bindingExpiry: DateTime.now().toUtc().add(const Duration(seconds: 1)),
    );
    await tester.tap(find.text('Accept'));
    await _settle(tester);
    expect(claimCount, 1);

    await tester.pump(const Duration(seconds: 2));
    await _settle(tester);
    expect(claimCount, 1);
    expect(
      commandGateway.countCommands('realtime-discard-incoming') -
          discardBaseline,
      0,
    );
    expect(find.text('Incoming screen-share request'), findsOneWidget);

    claimRelease.complete();
    await _settle(tester);
    expect(claimCount, 1);
    expect(find.text('Incoming screen-share request'), findsNothing);
    await cleanUp();
  });

  testWidgets('reject resolution is not duplicated by expiry', (tester) async {
    final arbitration = AppScreenSharePeerArbitrationRegistry();
    final rejectRelease = Completer<void>();
    var rejectCount = 0;
    String? rejectCommandId;
    var discardBaseline = 0;
    var cleanedUp = false;
    Future<void> cleanUp() async {
      if (cleanedUp) return;
      cleanedUp = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugPrint = debugPrintSynchronously;
      await commandGateway.close();
    }

    addTearDown(cleanUp);
    await _mountHost(
      tester: tester,
      runtime: runtime,
      commandGateway: commandGateway,
      arbitration: arbitration,
    );
    commandGateway.commandCompletion = (commandId) async {
      if (!commandId.startsWith('realtime-reject-incoming')) return true;
      rejectCount++;
      rejectCommandId = commandId;
      await rejectRelease.future;
      return false;
    };
    discardBaseline = commandGateway.countCommands('realtime-discard-incoming');
    await _emitOffer(
      tester,
      commandGateway,
      realtimeId: '00112233445566778899aabbccddee55',
      sharedSessionInstanceId: '4455667788990011aabbccddeeff0011',
      operationId: 'operation-reject-expiry',
      bindingExpiry: DateTime.now().toUtc().add(const Duration(seconds: 1)),
    );
    await tester.tap(find.text('Reject'));
    await _settle(tester);
    expect(rejectCount, 1);

    await tester.pump(const Duration(seconds: 2));
    await _settle(tester);
    expect(rejectCount, 1);
    expect(
      commandGateway.countCommands('realtime-discard-incoming') -
          discardBaseline,
      0,
    );
    expect(find.text('Incoming screen-share request'), findsOneWidget);

    commandGateway.emitCommandResult(rejectCommandId!);
    await _settle(tester);
    expect(find.text('Incoming screen-share request'), findsNothing);
    rejectRelease.complete();
    await _settle(tester);

    // The completed terminal path released the exact arbitration tuple.
    await _emitOffer(
      tester,
      commandGateway,
      realtimeId: '00112233445566778899aabbccddee66',
      sharedSessionInstanceId: '5566778899001122aabbccddeeff0011',
      operationId: 'operation-new',
      bindingExpiry: DateTime.now().toUtc().add(const Duration(seconds: 5)),
    );
    expect(find.text('Incoming screen-share request'), findsOneWidget);
    await cleanUp();
  });

  testWidgets(
    'a losing incoming intent does not invalidate the current expiry owner',
    (tester) async {
      final arbitration = AppScreenSharePeerArbitrationRegistry();
      var cleanedUp = false;
      Future<void> cleanUp() async {
        if (cleanedUp) return;
        cleanedUp = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugPrint = debugPrintSynchronously;
        await commandGateway.close();
      }

      addTearDown(cleanUp);
      await _mountHost(
        tester: tester,
        runtime: runtime,
        commandGateway: commandGateway,
        arbitration: arbitration,
      );
      final now = DateTime.now().toUtc();
      await _emitOffer(
        tester,
        commandGateway,
        realtimeId: '00112233445566778899aabbccddee11',
        sharedSessionInstanceId: 'ffeeddccbbaa99887766554433221100',
        operationId: 'operation-a',
        bindingExpiry: now.add(const Duration(seconds: 1)),
      );
      expect(find.text('Incoming screen-share request'), findsOneWidget);

      // The deterministic comparator makes operation-z lose to operation-a.
      await _emitOffer(
        tester,
        commandGateway,
        realtimeId: '00112233445566778899aabbccddee22',
        sharedSessionInstanceId: '11223344556677889900aabbccddeeff',
        operationId: 'operation-z',
        bindingExpiry: now.add(const Duration(seconds: 5)),
      );
      expect(find.text('Incoming screen-share request'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1100));
      expect(find.text('Incoming screen-share request'), findsNothing);
      await cleanUp();
    },
  );
}

Future<void> _mountHost({
  required WidgetTester tester,
  required AppRuntime runtime,
  required FakeCommandGateway commandGateway,
  required AppScreenSharePeerArbitrationRegistry arbitration,
  GlobalKey<NavigatorState>? navigatorKey,
  Widget Function(AppScreenShareRouteArguments arguments)? routeBuilder,
}) async {
  final key = navigatorKey ?? GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: key,
      routes: routeBuilder == null
          ? const <String, WidgetBuilder>{}
          : <String, WidgetBuilder>{
              AppShellRouteNames.screenShare: (context) {
                final arguments =
                    ModalRoute.of(context)!.settings.arguments!
                        as AppScreenShareRouteArguments;
                return routeBuilder(arguments);
              },
            },
      home: AppScreenShareIncomingRequestHost(
        runtime: runtime,
        navigatorKey: key,
        screenSharePort: const _TestScreenSharePort(),
        arbitration: arbitration,
        child: const ColoredBox(color: Colors.white),
      ),
    ),
  );
  final now = DateTime.now().toUtc();
  final warmupRealtimeId = '00112233445566778899aabbccddee00';
  await runtime.realtimeClient.discardIncomingOffer(
    _testOffer(
      realtimeId: warmupRealtimeId,
      sharedSessionInstanceId: 'ffeeddccbbaa99887766554433221100',
      operationId: 'host-test-warmup-operation',
      offerId: 'host-test-warmup',
      claimToken: 'host-test-warmup-token',
      bindingExpiry: now.add(const Duration(seconds: 5)),
    ),
  );
  await _settle(tester);
  expect(commandGateway.commands, isNotEmpty);
}

Future<void> _emitOffer(
  WidgetTester tester,
  FakeCommandGateway commandGateway, {
  required String realtimeId,
  required String sharedSessionInstanceId,
  required String operationId,
  required DateTime bindingExpiry,
}) async {
  commandGateway.emitEvent(
    _incomingOfferEvent(
      realtimeId: realtimeId,
      sharedSessionInstanceId: sharedSessionInstanceId,
      operationId: operationId,
      bindingExpiry: bindingExpiry,
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester, {int passes = 8}) async {
  for (var index = 0; index < passes; index++) {
    await tester.pump();
    await tester.idle();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
  }
}

void _installCommandAutomation(
  FakeCommandGateway commandGateway, {
  required List<String> claimRealtimeIds,
  required Map<String, String> sharedSessionIds,
  List<String> stopRealtimeIds = const <String>[],
  Completer<void>? claimGate,
  bool claimGateAccepted = true,
  Completer<void>? rejectGate,
}) {
  var claimIndex = 0;
  var stopIndex = 0;
  commandGateway.commandCompletion = (commandId) async {
    if (commandId.startsWith('realtime-claim-incoming')) {
      final realtimeId = claimRealtimeIds[claimIndex++];
      commandGateway.emitEvent(
        _realtimeStateEvent(
          realtimeId: realtimeId,
          sharedSessionInstanceId: sharedSessionIds[realtimeId]!,
        ),
      );
      if (claimGate != null && claimIndex == 1) {
        await claimGate.future;
        commandGateway.emitCommandResult(
          commandId,
          accepted: claimGateAccepted,
        );
        return false;
      }
      return true;
    }
    if (commandId.startsWith('realtime-reject-incoming') &&
        rejectGate != null) {
      await rejectGate.future;
      commandGateway.emitCommandResult(commandId);
      return false;
    }
    if (commandId.startsWith('realtime-stop') &&
        stopIndex < stopRealtimeIds.length) {
      commandGateway.emitEvent(
        _realtimeStateEvent(
          realtimeId: stopRealtimeIds[stopIndex++],
          sharedSessionInstanceId:
              sharedSessionIds[stopRealtimeIds[stopIndex - 1]]!,
          state: 4,
          revision: 2,
        ),
      );
    }
    return true;
  };
}

RealtimeIncomingSessionOffer _testOffer({
  required String realtimeId,
  required String sharedSessionInstanceId,
  required String operationId,
  required DateTime bindingExpiry,
  required String offerId,
  required String claimToken,
}) {
  final now = DateTime.now().toUtc();
  return RealtimeIncomingSessionOffer(
    offerId: offerId,
    claimToken: claimToken,
    realtimeId: realtimeId,
    authenticatedPeerId: 'peer-a',
    sharedSessionInstanceId: sharedSessionInstanceId,
    bindingExpiresAt: bindingExpiry,
    request: RealtimeConsent(
      operationId: operationId,
      realtimeId: realtimeId,
      sharedSessionInstanceId: sharedSessionInstanceId,
      issuedAt: now,
      expiresAt: now.add(const Duration(seconds: 2)),
      decision: RealtimeConsentDecision.request,
      senderPeerId: 'peer-a',
      actionRevision: 1,
    ),
  );
}

Uint8List _realtimeStateEvent({
  required String realtimeId,
  required String sharedSessionInstanceId,
  String peerId = 'peer-a',
  int state = 1,
  int revision = 1,
  int generation = 1,
}) => Uint8List.fromList(
  _eventFrame(21, <int>[
    ..._bytesField(1, utf8.encode(realtimeId)),
    ..._bytesField(2, utf8.encode(peerId)),
    ..._varintField(3, state),
    ..._varintField(4, revision),
    ..._varintField(6, generation),
    ..._bytesField(7, utf8.encode(sharedSessionInstanceId)),
  ]),
);

final class _ControlledScreenShareRoute extends StatefulWidget {
  const _ControlledScreenShareRoute({
    required this.arguments,
    required this.onDisposed,
  });

  final AppScreenShareRouteArguments arguments;
  final void Function(String? operationId) onDisposed;

  @override
  State<_ControlledScreenShareRoute> createState() =>
      _ControlledScreenShareRouteState();
}

final class _ControlledScreenShareRouteState
    extends State<_ControlledScreenShareRoute> {
  @override
  void dispose() {
    widget.onDisposed(widget.arguments.operationId);
    final lease = widget.arguments.sessionLease;
    if (lease != null) unawaited(lease.stopAndRelease());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Text('screen-share-route-${widget.arguments.operationId}'),
    ),
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
