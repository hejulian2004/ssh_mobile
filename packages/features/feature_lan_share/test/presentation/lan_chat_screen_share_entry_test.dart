import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  testWidgets('chat header starts screen share for an allowed peer', (
    tester,
  ) async {
    final port = _RecordingScreenSharePort(allowedPeerId: 'peer-1');
    final harness = _ChatHarness(screenSharePort: port);
    addTearDown(harness.dispose);

    await harness.pump(tester);

    expect(find.byIcon(Icons.screen_share_outlined), findsOneWidget);
    expect(find.byTooltip('Share screen'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.screen_share_outlined));
    await tester.pump();

    expect(port.startedPeers, ['peer-1']);
  });

  testWidgets('chat header hides screen share when the peer is not allowed', (
    tester,
  ) async {
    final harness = _ChatHarness(
      screenSharePort: _RecordingScreenSharePort(allowedPeerId: 'other-peer'),
    );
    addTearDown(harness.dispose);

    await harness.pump(tester);

    expect(find.byIcon(Icons.screen_share_outlined), findsNothing);
  });

  testWidgets('chat header reports a failed screen-share start', (
    tester,
  ) async {
    final harness = _ChatHarness(
      screenSharePort: _RecordingScreenSharePort(
        allowedPeerId: 'peer-1',
        startError: StateError('Screen sharing is unavailable for this peer.'),
      ),
    );
    addTearDown(harness.dispose);

    await harness.pump(tester);
    await tester.tap(find.byIcon(Icons.screen_share_outlined));
    await tester.pump();

    expect(
      find.textContaining('Screen sharing is unavailable for this peer.'),
      findsOneWidget,
    );
  });
}

final class _ChatHarness {
  _ChatHarness({required this.screenSharePort})
    : settings = FakeLanShareSettings(english: true) {
    viewModel = LanShareViewModel(
      discoveryService: FakeLanDiscoveryService(),
      securityService: _PairedSecurityService(),
      storageService: FakeLanStorageService(),
      transferService: _IdleTransferService(),
      historyDao: FakeLanHistoryDao(),
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
      ownsRuntime: false,
    );
  }

  final LanShareScreenSharePort screenSharePort;
  final FakeLanShareSettings settings;
  late final LanShareViewModel viewModel;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
          ChangeNotifierProvider<LanShareViewModel>.value(value: viewModel),
          Provider<LanShareScreenSharePort>.value(value: screenSharePort),
        ],
        child: const MaterialApp(
          home: LanChatScreen(
            targetDeviceId: 'peer-1',
            initialAlias: 'Remote Desktop',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  void dispose() {
    viewModel.dispose();
    settings.dispose();
  }
}

final class _PairedSecurityService extends Fake implements LanSecurityService {
  @override
  Future<bool> isDevicePaired(
    String deviceId, {
    String? ip,
    int? port,
    String? localDeviceId,
  }) async => true;
}

final class _IdleTransferService extends Fake implements LanTransferService {
  @override
  bool isWebSocketConnected(String deviceId) => false;
}

final class _RecordingScreenSharePort implements LanShareScreenSharePort {
  _RecordingScreenSharePort({required this.allowedPeerId, this.startError});

  final String allowedPeerId;
  final Object? startError;
  final List<String> startedPeers = <String>[];

  @override
  bool canShareWith(String peerId) => peerId == allowedPeerId;

  @override
  bool canReceiveScreenShareFrom(String peerId) => false;

  @override
  Future<void> startScreenShare(String peerId) async {
    startedPeers.add(peerId);
    final error = startError;
    if (error != null) throw error;
  }
}
