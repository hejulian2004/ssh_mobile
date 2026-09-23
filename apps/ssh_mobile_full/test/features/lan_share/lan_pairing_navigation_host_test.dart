import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:ssh_mobile/app/lan_share_feature_adapters.dart';
import 'package:ssh_mobile/services/app_settings.dart';

LanDiscoveredPeer _device(
  String id, {
  String alias = 'Peer',
  int port = 53317,
}) {
  return LanDiscoveredPeer(
    deviceId: id,
    alias: alias,
    ip: '192.168.1.20',
    controlPort: port,
    advertisedNativePort: null,
    deviceType: LanDeviceType.desktop,
    os: 'windows',
    lastSeen: DateTime.now(),
  );
}

LanPairingRequest _request({
  required String deviceId,
  required String sessionId,
  required bool isIncoming,
  String alias = 'Peer',
  int port = 53317,
  Duration lifetime = const Duration(minutes: 1),
}) {
  return LanPairingRequest(
    peer: LanPeerViewState(
      discovery: _device(deviceId, alias: alias, port: port),
    ),
    sessionId: sessionId,
    isIncoming: isIncoming,
    expiresAt: DateTime.now().add(lifetime),
  );
}

class _FakeTransferService extends Fake implements LanTransferService {
  @override
  Stream<LanDiscoveredPeer> get handshakeSuccessPeerStream =>
      const Stream.empty();
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
  final LanTransferService transferService = _FakeTransferService();

  @override
  Stream<LanPairingRequest> get pairingRequestStream => _requests.stream;

  @override
  Future<void> initialize() async {}

  @override
  LanPairingRequest? pairingRequestForSession(String sessionId) {
    final request = _latestRequests[sessionId];
    return request == null || request.isExpired ? null : request;
  }

  void emit(LanPairingRequest request) {
    _latestRequests[request.sessionId] = request;
    _requests.add(request);
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  @override
  bool get hasListeners => _listeners.isNotEmpty;

  Future<void> close() => _requests.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LanPairingNavigationQueue', () {
    test(
      'merges a different-session incoming request into the active peer',
      () {
        final queue = LanPairingNavigationQueue();
        final outgoing = _request(
          deviceId: 'peer-a',
          sessionId: 'outgoing-session',
          isIncoming: false,
          alias: 'Old alias',
        );
        final incoming = _request(
          deviceId: 'peer-a',
          sessionId: 'incoming-session',
          isIncoming: true,
          alias: 'Resolved alias',
          port: 62001,
          lifetime: const Duration(minutes: 2),
        );

        expect(queue.add(outgoing), LanPairingNavigationDecision.open);
        expect(queue.add(incoming), LanPairingNavigationDecision.updateActive);

        final active = queue.activeRequest!;
        expect(active.sessionId, outgoing.sessionId);
        expect(active.isIncoming, isTrue);
        expect(active.peer.displayAlias, 'Resolved alias');
        expect(active.peer.discovery!.controlPort, 62001);
        expect(active.expiresAt, incoming.expiresAt);
        expect(queue.pendingCount, 0);
      },
    );

    test('an outgoing duplicate cannot downgrade an incoming active role', () {
      final queue = LanPairingNavigationQueue();
      queue.add(
        _request(
          deviceId: 'peer-a',
          sessionId: 'incoming-session',
          isIncoming: true,
        ),
      );

      queue.add(
        _request(
          deviceId: 'peer-a',
          sessionId: 'outgoing-session',
          isIncoming: false,
        ),
      );

      expect(queue.activeRequest!.isIncoming, isTrue);
    });

    test('queues other peers in FIFO order without overwriting them', () {
      final queue = LanPairingNavigationQueue();
      queue.add(
        _request(deviceId: 'peer-a', sessionId: 'session-a', isIncoming: false),
      );
      queue.add(
        _request(deviceId: 'peer-b', sessionId: 'session-b', isIncoming: false),
      );
      queue.add(
        _request(deviceId: 'peer-c', sessionId: 'session-c', isIncoming: false),
      );
      queue.add(
        _request(
          deviceId: 'peer-b',
          sessionId: 'session-b-incoming',
          isIncoming: true,
        ),
      );

      expect(queue.pendingCount, 2);
      expect(queue.completeActive()!.peer.peerId, 'peer-b');
      expect(queue.activeRequest!.isIncoming, isTrue);
      expect(queue.completeActive()!.peer.peerId, 'peer-c');
      expect(queue.completeActive(), isNull);
    });

    test('ignores already expired requests', () {
      final queue = LanPairingNavigationQueue();
      final expired = _request(
        deviceId: 'peer-a',
        sessionId: 'expired',
        isIncoming: true,
        lifetime: const Duration(seconds: -1),
      );

      expect(queue.add(expired), LanPairingNavigationDecision.ignored);
      expect(queue.activeRequest, isNull);
    });
  });

  testWidgets(
    'incoming role emitted before screen subscription reaches active page',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final viewModel = _FakeLanShareViewModel();
      final navigatorKey = GlobalKey<NavigatorState>();
      final appSettings = AppSettings();
      final settings = AppLanShareSettingsAdapter(appSettings);
      addTearDown(() {
        settings.dispose();
        appSettings.dispose();
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ListenableProvider<LanShareViewModel>.value(value: viewModel),
            ListenableProvider<LanShareSettingsPort>.value(value: settings),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
            builder: (context, child) => LanPairingNavigationHost(
              navigatorKey: navigatorKey,
              child: child ?? const SizedBox.shrink(),
            ),
            home: const Scaffold(body: Text('Home')),
          ),
        ),
      );

      viewModel.emit(
        _request(
          deviceId: 'peer-a',
          sessionId: 'outgoing-session',
          isIncoming: false,
          alias: 'Outgoing peer',
        ),
      );
      // Emit synchronously before the pushed route builds and subscribes.
      viewModel.emit(
        _request(
          deviceId: 'peer-a',
          sessionId: 'incoming-session',
          isIncoming: true,
          alias: 'Incoming peer',
          port: 62001,
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));

      final screen = tester.widget<LanPairingScreen>(
        find.byType(LanPairingScreen),
      );
      expect(screen.sessionId, 'outgoing-session');
      expect(screen.isIncomingRequest, isTrue);
      expect(screen.initialAlias, 'Incoming peer');
      expect(find.text('安全配对请求'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await viewModel.close();
    },
  );

  testWidgets('manual dialog pop and pairing request share one turn', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final viewModel = _FakeLanShareViewModel();
    final navigatorKey = GlobalKey<NavigatorState>();
    final appSettings = AppSettings();
    final settings = AppLanShareSettingsAdapter(appSettings);
    addTearDown(() async {
      settings.dispose();
      appSettings.dispose();
      await viewModel.close();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareViewModel>.value(value: viewModel),
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) => LanPairingNavigationHost(
            navigatorKey: navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('open-manual-dialog'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    content: TextButton(
                      key: const ValueKey('manual-connect'),
                      onPressed: () {
                        Navigator.pop(dialogContext);
                        viewModel.emit(
                          _request(
                            deviceId: 'peer-manual',
                            sessionId: 'manual-session',
                            isIncoming: true,
                          ),
                        );
                      },
                      child: const Text('Connect'),
                    ),
                  ),
                ),
                child: const Text('Manual'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-manual-dialog')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('manual-connect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.byType(LanPairingScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(LanPairingScreen), findsOneWidget);
    expect(
      tester.widget<LanPairingScreen>(find.byType(LanPairingScreen)).sessionId,
      'manual-session',
    );
  });

  testWidgets('scanner route pop and pairing request share one turn', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final viewModel = _FakeLanShareViewModel();
    final navigatorKey = GlobalKey<NavigatorState>();
    final appSettings = AppSettings();
    final settings = AppLanShareSettingsAdapter(appSettings);
    addTearDown(() async {
      settings.dispose();
      appSettings.dispose();
      await viewModel.close();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareViewModel>.value(value: viewModel),
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) => LanPairingNavigationHost(
            navigatorKey: navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('open-scanner'),
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const LanQrScannerScreen(),
                  ),
                ),
                child: const Text('Scan'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-scanner')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LanQrScannerScreen), findsOneWidget);
    navigatorKey.currentState!.pop<void>();
    viewModel.emit(
      _request(deviceId: 'peer-qr', sessionId: 'qr-session', isIncoming: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.byType(LanPairingScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(LanPairingScreen), findsOneWidget);
    expect(
      tester.widget<LanPairingScreen>(find.byType(LanPairingScreen)).sessionId,
      'qr-session',
    );
  });

  testWidgets('mergeable requests emitted in one turn open one route', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final viewModel = _FakeLanShareViewModel();
    final navigatorKey = GlobalKey<NavigatorState>();
    final appSettings = AppSettings();
    final settings = AppLanShareSettingsAdapter(appSettings);
    addTearDown(() async {
      settings.dispose();
      appSettings.dispose();
      await viewModel.close();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareViewModel>.value(value: viewModel),
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) => LanPairingNavigationHost(
            navigatorKey: navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );

    viewModel.emit(
      _request(
        deviceId: 'peer-a',
        sessionId: 'outgoing-session',
        isIncoming: false,
      ),
    );
    viewModel.emit(
      _request(
        deviceId: 'peer-a',
        sessionId: 'incoming-session',
        isIncoming: true,
        alias: 'Merged peer',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.byType(LanPairingScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(LanPairingScreen), findsOneWidget);
    final screen = tester.widget<LanPairingScreen>(
      find.byType(LanPairingScreen),
    );
    expect(screen.sessionId, 'outgoing-session');
    expect(screen.isIncomingRequest, isTrue);
    expect(screen.initialAlias, 'Merged peer');
  });

  testWidgets('reciprocal invitation preserves a PIN already being typed', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final viewModel = _FakeLanShareViewModel();
    final navigatorKey = GlobalKey<NavigatorState>();
    final appSettings = AppSettings();
    final settings = AppLanShareSettingsAdapter(appSettings);
    addTearDown(() {
      settings.dispose();
      appSettings.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareViewModel>.value(value: viewModel),
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) => LanPairingNavigationHost(
            navigatorKey: navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );

    viewModel.emit(
      _request(
        deviceId: 'peer-a',
        sessionId: 'outgoing-session',
        isIncoming: false,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField), '123456');

    viewModel.emit(
      _request(
        deviceId: 'peer-a',
        sessionId: 'incoming-session',
        isIncoming: true,
        alias: 'Updated peer',
      ),
    );
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    final screen = tester.widget<LanPairingScreen>(
      find.byType(LanPairingScreen),
    );
    expect(field.controller?.text, '123456');
    expect(screen.isIncomingRequest, isTrue);
    expect(screen.initialAlias, 'Updated peer');

    await tester.pumpWidget(const SizedBox.shrink());
    await viewModel.close();
  });
}
