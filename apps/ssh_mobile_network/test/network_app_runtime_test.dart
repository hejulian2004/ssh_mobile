import 'dart:ui' show AppExitResponse;

import 'package:app_core/app_core.dart';
import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:provider/provider.dart';
import 'package:ssh_mobile_network/app/network_app.dart';
import 'package:ssh_mobile_network/app/network_app_runtime.dart';
import 'package:ssh_mobile_network/lan/network_lan_keys.dart';

import 'support/memory_secret_store.dart';

void main() {
  test('runtime releases the logger when network dispose fails', () async {
    final logger = AppLoggerImpl();
    final network = _FakeNetworkRuntime(
      closeError: StateError('injected network close failure'),
    );
    final runtime = await _open(logger: logger, network: network);

    await expectLater(runtime.dispose(), throwsA(isA<StateError>()));

    expect(network.disposeCount, 1);
    expect(runtime.module.state, ModuleState.disposed);
    expect(logger.isDisposed, isTrue);
    expect(identical(runtime.dispose(), runtime.dispose()), isTrue);
  });

  test('database open failure still releases the runtime', () async {
    final logger = AppLoggerImpl();
    final network = _FakeNetworkRuntime();

    await expectLater(
      _open(
        logger: logger,
        network: network,
        databaseFactory: () => throw StateError('db open failed'),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'db open failed',
        ),
      ),
    );

    expect(network.disposeCount, 1);
    expect(logger.isDisposed, isTrue);
  });

  test('corrupt identity does not open the LAN database', () async {
    final secrets = MemorySecretStore()
      ..values[NetworkLanStorageKeys.ed25519Seed] = 'abcd';
    var opened = false;

    await expectLater(
      NetworkTransportAppRuntime.open(
        logger: AppLoggerImpl(),
        networkRuntime: _FakeNetworkRuntime(),
        secrets: secrets,
        module: LanShareModule(
          receiverEnabled: false,
          databaseFactory: () {
            opened = true;
            return LanShareDatabase.forTesting(NativeDatabase.memory());
          },
        ),
        executor: const _UnusedExecutor(),
      ),
      throwsA(isA<StateError>()),
    );

    expect(opened, isFalse);
    expect(secrets.values[NetworkLanStorageKeys.ed25519Seed], 'abcd');
  });

  test('dispose releases the module before the runtime', () async {
    final network = _FakeNetworkRuntime();
    final runtime = await _open(network: network);
    network.onDispose = () {
      expect(runtime.module.state, ModuleState.disposed);
    };

    await runtime.dispose();

    expect(network.disposeCount, 1);
    expect(await runtime.networkAccess.borrowFacade(), isNull);
    expect(
      runtime.localAddressSelection,
      isA<LanShareSingleCandidateLocalAddressSelection>(),
    );
  });

  test('initialized inactive receiver closes', () async {
    final runtime = await _open();
    await runtime.module.coordinator.ensureInitialized();

    await runtime.module.coordinator.close();
    await runtime.dispose();

    expect(runtime.isDisposed, isTrue);
  });

  testWidgets('network app shows the network transfer page', (tester) async {
    final network = _FakeNetworkRuntime();
    final runtime = await _open(network: network);
    final key = GlobalKey<NetworkTransportAppState>();
    final viewModel = _quietViewModel(runtime);
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      _hostedPage(
        viewModel: viewModel,
        app: NetworkTransportApp(key: key, runtime: runtime),
      ),
    );
    await tester.pump();

    expect(find.byType(LanShareScreen), findsOneWidget);
    expect(find.byType(NetworkIncomingTransferHost), findsOneWidget);
    expect(find.byType(LanPairingNavigationHost), findsOneWidget);
    expect(find.text('网络传输'), findsWidgets);
    expect(find.text('设备列表'), findsWidgets);
    expect(find.text('传输历史'), findsWidgets);
    expect(find.text('启动运行时'), findsNothing);
    expect(network.requested, isEmpty);
    expect(tester.takeException(), isNull);

    final first = key.currentState!.shutdown();
    final second = key.currentState!.shutdown();
    expect(identical(first, second), isTrue);
    await tester.pump();

    expect(find.byType(LanShareScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('exit request unmounts the page', (tester) async {
    final runtime = await _open();
    final key = GlobalKey<NetworkTransportAppState>();
    final viewModel = _quietViewModel(runtime);
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(
      _hostedPage(
        viewModel: viewModel,
        app: NetworkTransportApp(key: key, runtime: runtime),
      ),
    );
    await tester.pump();

    final pending = key.currentState!.didRequestAppExit();
    await tester.pump();

    expect(find.byType(LanShareScreen), findsNothing);
    expect(pending, isA<Future<AppExitResponse>>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('detached lifecycle unmounts through dispose', (tester) async {
    final runtime = await _open();
    final viewModel = _quietViewModel(runtime);
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(
      _hostedPage(
        viewModel: viewModel,
        app: NetworkTransportApp(runtime: runtime),
      ),
    );
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pumpWidget(const SizedBox.shrink());

    expect(tester.takeException(), isNull);
  });
}

/// The feature scope uses an ancestor view model when one exists.
///
/// Production leaves that ancestor empty, so the coordinator creates the page
/// model and the screen starts discovery. Tests supply a quiet model so the
/// page can render without binding mDNS or UDP. The pairing host still
/// initializes the real receiver services; waiting for their close under the
/// widget tester does not return, so release is covered by the non-widget
/// close test.
Widget _hostedPage({
  required LanShareViewModel viewModel,
  required NetworkTransportApp app,
}) {
  return ChangeNotifierProvider<LanShareViewModel>.value(
    value: viewModel,
    child: app,
  );
}

LanShareViewModel _quietViewModel(NetworkTransportAppRuntime runtime) {
  return LanShareViewModel(
    discoveryService: _QuietDiscovery(),
    securityService: _UnusedSecurity(),
    storageService: _UnusedStorage(),
    transferService: _UnusedTransfer(),
    historyDao: _UnusedHistory(),
    appSettings: runtime.settings,
    dataProtection: runtime.protection,
    logger: runtime.loggerPort,
    ownsRuntime: false,
  );
}

Future<NetworkTransportAppRuntime> _open({
  AppLoggerImpl? logger,
  _FakeNetworkRuntime? network,
  LanShareDatabase Function()? databaseFactory,
}) {
  return NetworkTransportAppRuntime.open(
    logger: logger ?? AppLoggerImpl(),
    networkRuntime: network ?? _FakeNetworkRuntime(),
    secrets: MemorySecretStore(),
    module: LanShareModule(
      receiverEnabled: false,
      databaseFactory:
          databaseFactory ??
          () => LanShareDatabase.forTesting(NativeDatabase.memory()),
    ),
    executor: const _UnusedExecutor(),
  );
}

final class _UnusedExecutor implements SdkRequestExecutor {
  const _UnusedExecutor();

  @override
  Future<SdkResponse> execute(SdkRequest request) {
    throw StateError('this test does not send a control request');
  }
}

final class _QuietDiscovery extends Fake implements LanDiscoveryService {
  @override
  bool get isScanning => false;

  @override
  bool get isWebShareActive => false;

  @override
  String? get webShareUrl => null;

  @override
  String? get customIp => null;

  @override
  LanShareLocalAddressSelectionResult? get webShareAddressSelectionResult =>
      null;

  @override
  String get currentDeviceId => 'network-app-test';

  @override
  String get currentDeviceAlias => '本机';

  @override
  Future<NetworkResult<void>> startDiscovery() async =>
      const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> stopDiscovery() async =>
      const NetworkSuccess<void>(null);
}

final class _UnusedSecurity extends Fake implements LanSecurityService {}

final class _UnusedStorage extends Fake implements LanStorageService {}

final class _UnusedTransfer extends Fake implements LanTransferService {}

final class _UnusedHistory extends Fake implements LanHistoryDao {}

final class _FakeNetworkRuntime implements NetworkRuntime {
  _FakeNetworkRuntime({this.closeError});

  final Object? closeError;
  void Function()? onDispose;
  final requested = <NetworkCapability>[];
  int disposeCount = 0;
  NetworkRuntimeState _state = NetworkRuntimeState.idle;

  @override
  NetworkRuntimeState get state => _state;

  @override
  NetworkRuntimeDiagnostics get diagnostics => NetworkRuntimeDiagnostics(
    state: _state,
    activeConnections: 0,
    nativeHandles: 0,
    readyCapabilities: const [],
  );

  @override
  Future<void> ensureCapability(NetworkCapability capability) async {
    requested.add(capability);
  }

  @override
  bool isCapabilityReady(NetworkCapability capability) => false;

  @override
  Future<NetworkCommandGateway> openCommandGateway() {
    throw UnsupportedError('this page does not open a command gateway');
  }

  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() {
    throw UnsupportedError('this page does not open a realtime gateway');
  }

  @override
  Future<void> dispose() async {
    onDispose?.call();
    disposeCount++;
    _state = NetworkRuntimeState.disposed;
    final error = closeError;
    if (error != null) throw error;
  }
}
