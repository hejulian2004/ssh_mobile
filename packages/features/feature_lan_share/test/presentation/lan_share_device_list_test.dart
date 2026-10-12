import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:provider/provider.dart';
import 'package:app_ui/app_ui.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  testWidgets(
    'device page offers termination while its invitation is connecting',
    (tester) async {
      final vm = _ViewModel();
      final settings = _Settings();
      addTearDown(vm.dispose);
      addTearDown(settings.dispose);
      await _pump(tester, vm, settings);
      vm.startConnecting('new');
      await tester.pump();
      await tester.tap(find.text('New phone'));
      expect(vm.pairingRequests, isEmpty);
      expect(find.text('Connecting…'), findsOneWidget);
      await tester.tap(find.text('Terminate'));
      await tester.pump();
      expect(vm.cancelled, ['new']);
      expect(find.text('Connecting…'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'history keeps existing sessions and deletion separate from unpair',
    (tester) async {
      final vm = _ViewModel();
      final settings = _Settings();
      addTearDown(vm.dispose);
      addTearDown(settings.dispose);
      vm.messages.addAll([
        _message('paired', route: NetworkRouteType.quicDirect),
        _message(
          'archived',
          incoming: true,
          alias: 'Archived phone',
          route: NetworkRouteType.relay,
        ),
        _message('outgoing', alias: 'Test Device'),
        _message('named', alias: 'Named peer'),
        _message('new'),
        _message(''),
      ]);
      await _pump(tester, vm, settings);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.text('Archived phone'), findsOneWidget);
      expect(find.text('Device'), findsOneWidget);
      expect(find.text('Named peer'), findsOneWidget);
      expect(find.textContaining('Direct'), findsOneWidget);
      await tester.tap(find.text('Archived phone'));
      await tester.pump();
      expect(find.text('Offline'), findsWidgets);
      await tester.tap(find.text('New phone'));
      await tester.pump();
      expect(vm.pairingRequests, ['new']);
      final phoneCard = find.ancestor(
        of: find.text('Phone'),
        matching: find.byType(AppSectionCard),
      );
      await tester.tap(
        find.descendant(
          of: phoneCard,
          matching: find.byIcon(Icons.expand_more_rounded),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: phoneCard,
          matching: find.byIcon(Icons.close_rounded),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: phoneCard,
          matching: find.byIcon(Icons.expand_more_rounded),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: phoneCard,
          matching: find.byIcon(Icons.delete_forever_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(vm.clearedChats, isEmpty);
      await tester.tap(
        find.descendant(
          of: phoneCard,
          matching: find.byIcon(Icons.delete_forever_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(vm.clearedChats, ['paired']);
      expect(vm.forgotten, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'page long press confirms unpair and removes the selected device only',
    (tester) async {
      final vm = _ViewModel();
      final settings = _Settings();
      addTearDown(vm.dispose);
      addTearDown(settings.dispose);
      await _pump(tester, vm, settings);
      expect(find.text('Phone'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      await tester.longPress(find.text('Phone'));
      await tester.pumpAndSettle();
      expect(find.text('Unpair this device?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(vm.forgotten, isEmpty);
      await tester.longPress(find.text('Phone'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unpair'));
      await tester.pumpAndSettle();
      expect(vm.forgotten, ['paired']);
      expect(find.text('Phone'), findsNothing);
      expect(find.text('New phone'), findsOneWidget);
      await tester.tap(find.text('New phone'));
      await tester.pump();
      expect(vm.pairingRequests, ['new']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed unpair preserves the card and displays a recoverable message',
    (tester) async {
      final vm = _ViewModel()..failUnpair = true;
      final settings = _Settings();
      addTearDown(vm.dispose);
      addTearDown(settings.dispose);
      await _pump(tester, vm, settings);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unpair'));
      await tester.pumpAndSettle();
      expect(find.text('Phone'), findsOneWidget);
      expect(find.text('Unable to unpair. Try again.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('empty list scanning and stopped layouts remain usable', (
    tester,
  ) async {
    final vm = _ViewModel()
      ..peers.clear()
      ..isScanning = false
      ..failScan = true
      ..lastScanError = const NetworkError(
        code: NetworkErrorCode.ioError,
        message: 'Scan unavailable',
        operation: NetworkOperation.startDiscovery,
      );
    final settings = _Settings();
    addTearDown(vm.dispose);
    addTearDown(settings.dispose);
    await _pump(tester, vm, settings);
    expect(find.text('Rescan'), findsOneWidget);
    vm.failScan = false;
    await tester.tap(find.text('Rescan'));
    await tester.pump();
    expect(vm.startCalls, 2);
    await tester.tap(find.byIcon(Icons.sync_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Radar stopped'), findsWidgets);
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pump();
    expect(find.byType(AppLoadingIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _pump(
  WidgetTester tester,
  _ViewModel vm,
  _Settings settings,
) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<LanShareViewModel>.value(value: vm),
        ListenableProvider<LanShareSettingsPort>.value(value: settings),
      ],
      child: const MaterialApp(home: LanShareScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

final class _Strings extends Fake implements LanShareStrings {
  @override
  bool get isEnglish => true;
  @override
  String get cancel => 'Cancel';
  @override
  String get delete => 'Delete';
  @override
  String get lanShareClearChatHistory => 'Clear chat history';
  @override
  String get lanRouteDirect => 'Direct';
  @override
  String get lanRouteRelay => 'Relay';
  @override
  String get lanShare => 'Network transfer';
  @override
  String get lanShareDeviceList => 'Devices';
  @override
  String get lanShareTransferHistory => 'History';
  @override
  String get lanShareOnline => 'Online';
  @override
  String get lanShareOffline => 'Offline';
  @override
  String get lanShareNoDevices => 'No devices';
  @override
  String get lanShareRadarStoppedHint => 'Radar stopped';
  @override
  dynamic noSuchMethod(Invocation invocation) => '';
}

final class _Settings extends ChangeNotifier implements LanShareSettingsPort {
  @override
  final LanShareStrings strings = _Strings();
  @override
  bool get isEnglish => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ViewModel extends ChangeNotifier implements LanShareViewModel {
  final Set<String> connecting = {};
  final List<String> cancelled = [];
  void startConnecting(String peerId) {
    connecting.add(peerId);
    notifyListeners();
  }

  @override
  bool isPairingConnecting(String peerId) => connecting.contains(peerId);
  @override
  void cancelPairingConnection(String peerId) {
    cancelled.add(peerId);
    connecting.remove(peerId);
    notifyListeners();
  }

  final List<LanPeerViewState> peers = [
    LanPeerViewState(
      trust: LanPeerTrustRecord(
        deviceId: 'paired',
        certificateFingerprint: 'a' * 64,
        inboundAccessToken: 'inbound',
        outboundAccessToken: 'outbound',
        x25519PublicKey: Uint8List(32),
        networkIdentityPublicKey: Uint8List(32),
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: true,
          relay: false,
        ),
        createdAt: DateTime.utc(2026),
      ),
      savedAlias: 'Phone',
      lastOnlineAt: DateTime.utc(2026),
    ),
    LanPeerViewState(
      discovery: LanDiscoveredPeer(
        deviceId: 'new',
        alias: 'New phone',
        ip: '192.0.2.5',
        controlPort: 53317,
        os: 'android',
        lastSeen: DateTime.utc(2026),
      ),
    ),
  ];
  final List<String> forgotten = [];
  final List<String> pairingRequests = [];
  final List<String> clearedChats = [];
  final List<LanMessage> messages = [];
  bool failUnpair = false;
  bool failScan = false;
  @override
  NetworkError? lastScanError;
  int startCalls = 0;
  @override
  bool isScanning = true;
  @override
  List<LanPeerViewState> get peerStates => peers;
  @override
  List<LanMessage> get history => messages;
  @override
  LanPeerViewState? peerStateFor(String id) {
    for (final peer in peers) {
      if (peer.peerId == id) return peer;
    }
    return null;
  }

  @override
  bool isDeviceConnected(String id) => peerStateFor(id)?.isOnline == true;
  @override
  Future<bool> isDevicePaired(String id) async =>
      peerStateFor(id)?.isTrusted == true;
  @override
  Future<void> clearChatHistory(String id) async {
    clearedChats.add(id);
    messages.removeWhere(
      (message) =>
          (message.isIncoming ? message.senderId : message.receiverId) == id,
    );
    notifyListeners();
  }

  @override
  LanDiscoveryService get discoveryService => _discovery;
  final _discovery = FakeLanDiscoveryService();
  @override
  bool get isWebShareActive => false;
  @override
  String? get customIp => null;
  @override
  LanShareLocalAddressSelectionResult? get webShareAddressSelectionResult =>
      null;
  @override
  LanShareSettingsPort get appSettings => _Settings();
  @override
  Future<NetworkResult<void>> startScanning() async {
    startCalls++;
    if (failScan) return NetworkFailure(lastScanError!);
    lastScanError = null;
    isScanning = true;
    notifyListeners();
    return const NetworkSuccess(null);
  }

  @override
  Future<NetworkResult<void>> stopScanning() async {
    isScanning = false;
    notifyListeners();
    return const NetworkSuccess(null);
  }

  @override
  Future<NetworkResult<void>> requestPairing(LanDiscoveredPeer peer) async {
    pairingRequests.add(peer.deviceId);
    return const NetworkSuccess(null);
  }

  @override
  Future<NetworkResult<void>> forgetDevice(String id) async {
    if (failUnpair) {
      return const NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'Unpair failed',
          operation: NetworkOperation.removePeer,
        ),
      );
    }
    forgotten.add(id);
    peers.removeWhere((peer) => peer.peerId == id);
    notifyListeners();
    return const NetworkSuccess(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LanMessage _message(
  String otherId, {
  bool incoming = false,
  String alias = 'Local',
  NetworkRouteType? route,
}) => LanMessage(
  id: 'message-$otherId',
  senderId: incoming ? otherId : 'test-device',
  senderAlias: alias,
  receiverId: incoming ? 'test-device' : otherId,
  payloadType: LanPayloadType.text,
  textContent: 'hello',
  routeType: route,
  createdAt: DateTime.utc(2026, 10, 12),
  isIncoming: incoming,
);
