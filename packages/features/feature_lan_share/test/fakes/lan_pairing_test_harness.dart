import 'dart:async';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:provider/provider.dart';

import 'lan_share_test_fakes.dart';

final pairingTestPeer = LanDiscoveredPeer(
  deviceId: 'peer-1',
  alias: 'Windows PC',
  ip: '192.168.1.20',
  controlPort: 53317,
  os: 'windows',
  lastSeen: DateTime.utc(2026, 9, 29),
);

final class LanPairingTestHarness {
  LanPairingTestHarness() : settings = FakeLanShareSettings(english: true) {
    transfer = ScriptedPairingTransfer();
    viewModel = ScriptedPairingViewModel(transfer: transfer);
  }

  final FakeLanShareSettings settings;
  late final ScriptedPairingTransfer transfer;
  late final ScriptedPairingViewModel viewModel;

  Future<void> pump(
    WidgetTester tester, {
    LanDiscoveredPeer? initialPeer,
  }) async {
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
            initialPeer: initialPeer,
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

final class ScriptedPairingTransfer extends Fake implements LanTransferService {
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

  @override
  Future<void> close() async {
    await _handshake.close();
    await _directions.close();
  }
}

final class ScriptedPairingViewModel extends Fake implements LanShareViewModel {
  ScriptedPairingViewModel({required this.transfer});

  final ScriptedPairingTransfer transfer;
  final Set<VoidCallback> _listeners = {};
  final FakeLanDiscoveryService discovery = FakeLanDiscoveryService();
  int authCalls = 0;
  int cancelCalls = 0;
  Future<NetworkResult<LanPairingHandshakeProgress>>? pendingResult;

  @override
  void cancelPairingAuthentication(String peerId) => cancelCalls++;
  bool exposePeerState = true;
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
    if (!exposePeerState) return null;
    return LanPeerViewState(discovery: pairingTestPeer);
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
    if (pendingResult != null) return pendingResult!;
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
