// LAN Share Module 生命周期测试。
//
// 测试重点是配置关闭时不会启动接收器，以及 Module 会关闭自己拥有的
// 数据库资源；网络、身份和日志均使用受控的 Port 假实现。

import 'package:app_core/app_core.dart';
import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';

void main() {
  test(
    'disabled receiver initializes without starting network services',
    () async {
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final networkAccess = _FakeNetworkAccessPort();
      final networkRuntime = _FakeNetworkRuntime();
      const addressSelector = LanShareSingleCandidateLocalAddressSelection();
      final module = LanShareModule(
        receiverEnabled: false,
        databaseFactory: () => database,
      );

      await module.register(
        ModuleContext.fromMap({
          LanShareSettingsPort: _FakeSettings(),
          LanShareLoggerPort: _FakeLogger(),
          LanShareDataProtectionPort: _FakeDataProtection(),
          LanShareNetworkIdentityPort: _FakeIdentity(),
          LanShareNetworkAccessPort: networkAccess,
          LanShareLocalAddressSelectionPort: addressSelector,
          BootstrapClient: _FakeBootstrapClient(),
          NetworkRuntime: networkRuntime,
        }),
      );
      await module.initialize();
      expect(module.state, ModuleState.initialized);
      expect(module.database, same(database));
      expect(
        module.coordinator.localAddressSelectionPort,
        same(addressSelector),
      );

      await module.activate();
      expect(module.state, ModuleState.active);
      expect(module.receiverEnabled, isFalse);
      expect(networkAccess.borrowCalls, 0);
      expect(networkRuntime.ensureCalls, 0);

      await module.deactivate();
      expect(module.state, ModuleState.inactive);
      await module.dispose();
      expect(module.state, ModuleState.disposed);
      expect(() => module.database, throwsStateError);
    },
  );

  test('module requires registration before opening its database', () async {
    final module = LanShareModule(databaseFactory: LanShareDatabase.new);

    await expectLater(module.initialize(), throwsStateError);
    expect(module.state, ModuleState.registered);
  });
}

final class _FakeBootstrapClient implements BootstrapClient {
  @override
  Future<SdkResult<BootstrapMetadata>> probe(Uri endpoint) async =>
      const SdkSuccess(BootstrapMetadata(protocolVersion: 2));

  @override
  Future<SdkResult<DeviceEnrollment>> enroll(
    Uri endpoint,
    EnrollmentRequest request,
  ) async => SdkSuccess(
    DeviceEnrollment(
      deviceId: request.deviceId,
      relayCredential: 'fake',
      expiresAt: DateTime.utc(2030),
      serverTime: DateTime.utc(2029),
      protocolVersion: 2,
    ),
  );

  @override
  Future<SdkResult<DeviceEnrollment>> refresh(
    Uri endpoint,
    RefreshRequest request,
  ) async => SdkSuccess(
    DeviceEnrollment(
      deviceId: request.deviceId,
      relayCredential: 'fake-refreshed',
      expiresAt: DateTime.utc(2030),
      serverTime: DateTime.utc(2029),
      protocolVersion: 2,
    ),
  );
}

final class _FakeSettings extends ChangeNotifier
    implements LanShareSettingsPort {
  @override
  LanShareLanguage get language => LanShareLanguage.zh;

  @override
  bool get isEnglish => false;

  @override
  LanShareStrings get strings => const _FakeStrings();

  @override
  String get lanDeviceId => 'test-device';

  @override
  String get lanDeviceAlias => 'Test Device';

  @override
  String get relayEndpoint => '';

  @override
  String get relayHost => '';

  @override
  int get relayPort => 443;

  @override
  bool get receiverEnabled => true;

  @override
  Future<void> ensureLanIdentity() async {}

  @override
  Future<void> setLanDeviceAlias(String alias) async {}

  @override
  Future<void> setRelayEndpoint(String endpoint) async {}

  @override
  Future<void> setRelayServer({
    required String host,
    required int port,
  }) async {}
}

final class _FakeStrings implements LanShareStrings {
  const _FakeStrings();

  @override
  bool get isEnglish => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => '';
}

final class _FakeLogger implements LanShareLoggerPort {
  @override
  void info(String message, {String? details}) {}

  @override
  void warning(String message, {String? details}) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}

final class _FakeDataProtection implements LanShareDataProtectionPort {
  @override
  Future<String> encryptString(String value) async => 'encrypted:$value';

  @override
  Future<String> decryptString(String value) async =>
      value.startsWith('encrypted:') ? value.substring(10) : value;

  @override
  bool isEncrypted(String value) => value.startsWith('encrypted:');
}

final class _FakeIdentity implements LanShareNetworkIdentityPort {
  @override
  Future<LanShareNetworkIdentityMaterial> loadOrCreate() async =>
      LanShareNetworkIdentityMaterial(
        privateSeed: Uint8List(32),
        publicKey: Uint8List(32),
        x25519PrivateSeed: Uint8List(32),
        x25519PublicKey: Uint8List(32),
      );
}

final class _FakeNetworkAccessPort implements LanShareNetworkAccessPort {
  int borrowCalls = 0;

  @override
  Future<NetworkFacade?> borrowFacade() async {
    borrowCalls++;
    return null;
  }
}

final class _FakeNetworkRuntime implements NetworkRuntime {
  int ensureCalls = 0;
  bool disposed = false;

  @override
  NetworkRuntimeState get state =>
      disposed ? NetworkRuntimeState.disposed : NetworkRuntimeState.idle;

  @override
  NetworkRuntimeDiagnostics get diagnostics => NetworkRuntimeDiagnostics(
    state: state,
    activeConnections: 0,
    nativeHandles: 0,
    readyCapabilities: const <NetworkCapability>[],
  );

  @override
  Future<void> ensureCapability(NetworkCapability capability) async {
    ensureCalls++;
  }

  @override
  Future<NetworkCommandGateway> openCommandGateway() async =>
      throw UnsupportedError('fake runtime has no command gateway');

  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() async =>
      throw UnsupportedError('fake runtime has no realtime gateway');

  @override
  bool isCapabilityReady(NetworkCapability capability) => false;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
