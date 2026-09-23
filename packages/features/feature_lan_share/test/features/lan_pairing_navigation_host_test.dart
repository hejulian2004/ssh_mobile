import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import '../fakes/lan_share_test_fakes.dart';

LanDiscoveredPeer _device(String id) {
  return LanDiscoveredPeer(
    deviceId: id,
    alias: 'Peer $id',
    ip: '192.168.1.20',
    controlPort: 53317,
    advertisedNativePort: null,
    deviceType: LanDeviceType.desktop,
    os: 'windows',
    lastSeen: DateTime.now(),
  );
}

LanPairingRequest _request(String sessionId) {
  return LanPairingRequest(
    peer: LanPeerViewState(discovery: _device('peer-a')),
    sessionId: sessionId,
    isIncoming: true,
    expiresAt: DateTime.now().add(const Duration(minutes: 1)),
  );
}

class _FakeLanShareViewModel extends Fake implements LanShareViewModel {
  final StreamController<LanPairingRequest> _requests =
      StreamController<LanPairingRequest>.broadcast(sync: true);
  final Map<String, LanPairingRequest> _latestRequests = {};
  final Set<VoidCallback> _listeners = {};

  @override
  final LanSecurityService securityService = LanSecurityService(
    appOwnedX25519PrivateSeed: Uint8List(32),
  );

  @override
  final LanTransferService transferService = FakeLanTransferService();

  @override
  Stream<LanPairingRequest> get pairingRequestStream => _requests.stream;

  @override
  Future<void> initialize() async {}

  @override
  LanPairingRequest? pairingRequestForSession(String sessionId) {
    final request = _latestRequests[sessionId];
    return request == null || request.isExpired ? null : request;
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  @override
  bool get hasListeners => _listeners.isNotEmpty;

  Future<void> close() => _requests.close();
}

final class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '/tmp/lan_share_test_documents';

  @override
  Future<String?> getTemporaryPath() async => '/tmp/lan_share_test_tmp';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform originalPathProvider;
  late FakeLanShareSettings settings;
  late _FakeLanShareViewModel viewModel;
  late LanShareDatabase database;
  late LanReceiverCoordinator coordinator;

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform();
    settings = FakeLanShareSettings();
    viewModel = _FakeLanShareViewModel();
    database = LanShareDatabase.forTesting(NativeDatabase.memory());
    coordinator = LanReceiverCoordinator(
      appSettings: settings,
      logger: FakeLanShareLogger(),
      dataProtection: FakeLanShareDataProtection(),
      networkIdentity: FakeLanShareIdentity(),
      networkAccess: FakeLanShareNetworkAccessPort(),
      bootstrapClient: FakeLanShareBootstrapClient(),
      historyRepository: LanShareHistoryRepository(database),
      networkRuntime: FakeLanShareNetworkRuntime(),
      transferServiceOverride: FakeLanTransferService(),
      discoveryServiceOverride: FakeLanDiscoveryService(),
      initializeNetwork: false,
    );
    await coordinator.ensureInitialized();
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPathProvider;
    await viewModel.close();
    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });

  testWidgets(
    'subscribes to the coordinator pairing stream and opens the route',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ListenableProvider<LanShareSettingsPort>.value(value: settings),
            ListenableProvider<LanShareViewModel>.value(value: viewModel),
            ChangeNotifierProvider<LanReceiverCoordinator>.value(
              value: coordinator,
            ),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
            builder: (context, child) => LanPairingNavigationHost(
              navigatorKey: navigatorKey,
              child: child ?? const SizedBox.shrink(),
            ),
            home: const Scaffold(body: Text('home')),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      coordinator.publishPairingRequest(_request('session-1'));
      // The stream callback schedules navigation after the current frame.
      // Pump bounded frames without settling the pairing screen's radar animation.
      for (var frame = 0; frame < 5; frame++) {
        if (navigatorKey.currentState!.canPop()) break;
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The scheduler pushes after a frame; build the newly-added route.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.takeException(), isNull);
      expect(navigatorKey.currentState!.canPop(), isTrue);
      expect(find.byType(LanShareFeatureScope), findsOneWidget);
      final screen = tester.widget<LanPairingScreen>(
        find.byType(LanPairingScreen),
      );
      expect(screen.sessionId, 'session-1');
      expect(screen.isIncomingRequest, isTrue);
      expect(screen.initialAlias, 'Peer peer-a');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
