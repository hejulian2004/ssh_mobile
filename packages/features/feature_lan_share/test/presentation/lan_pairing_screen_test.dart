import 'dart:async';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:provider/provider.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  testWidgets('one verified PIN stays on the pairing page', (tester) async {
    final harness = _PairingHarness();
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
    final harness = _PairingHarness();
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

  testWidgets('handshake success opens chat for the waiting device', (
    tester,
  ) async {
    final harness = _PairingHarness();
    addTearDown(harness.dispose);
    await harness.pump(tester);

    harness.transfer.emitHandshake(_peer);
    await tester.pump();
    // Predictive-back keeps the outgoing route mounted for 450ms.
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(LanChatScreen), findsOneWidget);
    expect(find.byType(LanPairingScreen), findsNothing);
  });
}

final _peer = LanDiscoveredPeer(
  deviceId: 'peer-1',
  alias: 'Windows PC',
  ip: '192.168.1.20',
  controlPort: 53317,
  os: 'windows',
  lastSeen: DateTime.utc(2026, 9, 29),
);

final class _PairingHarness {
  _PairingHarness() : settings = FakeLanShareSettings(english: true) {
    transfer = _ScriptedTransfer();
    viewModel = _ScriptedViewModel(transfer: transfer);
  }

  final FakeLanShareSettings settings;
  late final _ScriptedTransfer transfer;
  late final _ScriptedViewModel viewModel;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
          ListenableProvider<LanShareViewModel>.value(value: viewModel),
        ],
        child: MaterialApp(
          home: LanPairingScreen(
            targetDeviceId: 'peer-1',
            initialAlias: 'Windows PC',
            sessionId: 'session-1',
          ),
        ),
      ),
    );
    await tester.pump();
  }

  void dispose() {
    viewModel.disposeListeners();
    settings.dispose();
  }
}

final class _ScriptedTransfer extends Fake implements LanTransferService {
  final StreamController<LanDiscoveredPeer> _handshake =
      StreamController<LanDiscoveredPeer>.broadcast();
  final StreamController<LanPairingDirectionNotice> _directions =
      StreamController<LanPairingDirectionNotice>.broadcast();
  LanPairingDirectionNotice? notice;

  @override
  Stream<LanDiscoveredPeer> get handshakeSuccessPeerStream => _handshake.stream;

  @override
  Stream<LanPairingDirectionNotice> get pairingDirectionStream =>
      _directions.stream;

  @override
  LanPairingDirectionNotice? pairingDirectionFor(String peerId) => notice;

  void emitDirection(LanPairingDirectionNotice next) {
    notice = next;
    _directions.add(next);
  }

  void emitHandshake(LanDiscoveredPeer peer) => _handshake.add(peer);

  Future<void> close() async {
    await _handshake.close();
    await _directions.close();
  }
}

final class _ScriptedViewModel extends Fake implements LanShareViewModel {
  _ScriptedViewModel({required this.transfer});

  final _ScriptedTransfer transfer;
  final Set<VoidCallback> _listeners = {};
  final FakeLanDiscoveryService discovery = FakeLanDiscoveryService();
  int authCalls = 0;
  NetworkResult<LanPairingHandshakeProgress> nextResult = const NetworkSuccess(
    LanPairingHandshakeProgress.waitingForPeer,
  );

  @override
  LanTransferService get transferService => transfer;

  @override
  LanDiscoveryService get discoveryService => discovery;

  @override
  LanSecurityService get securityService => _PinSecurity();

  @override
  Stream<LanPairingRequest> get pairingRequestStream => const Stream.empty();

  @override
  LanPairingRequest? pairingRequestForSession(String sessionId) => null;

  @override
  LanPeerViewState? peerStateFor(String deviceId) {
    return LanPeerViewState(discovery: _peer);
  }

  @override
  List<LanMessage> get history => const [];

  @override
  bool isDeviceConnected(String deviceId) => false;

  @override
  Future<bool> isDevicePaired(
    String deviceId, {
    String? ip,
    int? port,
    String? localDeviceId,
  }) async => true;

  @override
  Future<NetworkResult<LanPairingHandshakeProgress>> authenticateDevice(
    LanDiscoveredPeer device,
    String pin, {
    bool isInitiator = true,
  }) async {
    authCalls++;
    if (nextResult case NetworkSuccess<LanPairingHandshakeProgress>(
      data: LanPairingHandshakeProgress.waitingForPeer,
    )) {
      transfer.notice = const LanPairingDirectionNotice(
        peerId: 'peer-1',
        outboundVerified: true,
        inboundVerified: false,
      );
    }
    return nextResult;
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  @override
  bool get hasListeners => _listeners.isNotEmpty;

  void disposeListeners() {
    _listeners.clear();
    unawaited(transfer.close());
  }
}

final class _PinSecurity extends Fake implements LanSecurityService {
  @override
  String getOrGenerate6DigitPin() => '654321';

  @override
  int get pinSecondsRemaining => 60;
}
