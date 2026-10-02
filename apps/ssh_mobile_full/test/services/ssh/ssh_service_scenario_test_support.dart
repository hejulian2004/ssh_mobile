// Shared scenario fixture for the responsibility-split SshService tests.
// Keeping platform overrides, background fakes, and connection wiring in one
// place lets the focused test files stay below the repository size gates.

import 'dart:async';
import 'dart:io';

import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

import '../../test_utils/test_storage_adapter.dart';

/// Owns the SshService scenario fixture and platform overrides.
final class SshServiceScenarioHarness {
  SshServiceScenarioHarness({this.appSettings});

  final AppSettings? appSettings;

  late TestStorageAdapter storage;
  late SshService ssh;
  late FakeBackgroundServicePlatform background;

  bool resolveServerANative = false;
  final Set<Future<void>> pendingConnects = <Future<void>>{};

  late Directory _supportDir;
  late FlutterBackgroundServicePlatform? _previousBackground;
  late PermissionHandlerPlatform? _previousPermission;
  late PathProviderPlatform? _previousPathProvider;
  late _StallingNativeConnector _nativeConnector;

  Future<void> setUp() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    _previousBackground = _tryReadBackgroundPlatform();
    _previousPermission = PermissionHandlerPlatform.instance;
    _previousPathProvider = PathProviderPlatform.instance;
    _supportDir = await Directory.systemTemp.createTemp('ssh_scenario_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(_supportDir.path);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    background = FakeBackgroundServicePlatform();
    FlutterBackgroundServicePlatform.instance = background;
    PermissionHandlerPlatform.instance = _GrantedPermissionPlatform();
    pendingConnects.clear();
    resolveServerANative = false;
    storage = TestStorageAdapter();
    await _addScenarioConnection(storage, 'server-a');
    await _addScenarioConnection(storage, 'server-b');
    _nativeConnector = _StallingNativeConnector();
    ssh = createTestSshService(
      storage,
      appSettings: appSettings,
      nativeStreamConnector: _nativeConnector,
      peerIdResolver: (config) {
        if (!config.id.startsWith('server-')) return null;
        final usesNative =
            defaultTargetPlatform != TargetPlatform.android ||
            (config.id == 'server-a' && resolveServerANative);
        return usesNative ? 'peer-${config.id}' : null;
      },
    );
  }

  Future<void> tearDown() async {
    await _nativeConnector.closeAll();
    for (final pending in pendingConnects) {
      try {
        await pending;
      } catch (_) {
        // The fixture stream aborts the stalled handshake.
      }
    }
    await ssh.close();
    await storage.shutdown();
    storage.dispose();
    await background.dispose();
    final previousB = _previousBackground;
    if (previousB != null) {
      FlutterBackgroundServicePlatform.instance = previousB;
    }
    final previousP = _previousPermission;
    if (previousP != null) {
      PermissionHandlerPlatform.instance = previousP;
    }
    final previousPath = _previousPathProvider;
    if (previousPath != null) {
      PathProviderPlatform.instance = previousPath;
    }
    debugDefaultTargetPlatformOverride = null;
    await _deleteSupportDirectory();
  }

  Future<void> _deleteSupportDirectory() async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (!await _supportDir.exists()) return;
        await _supportDir.delete(recursive: true);
        return;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        if (attempt < 4) {
          await Future<void>.delayed(Duration(milliseconds: 10 << attempt));
        }
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Future<void> waitForConnecting(String sessionId) => waitUntil(
    () => ssh.getSession(sessionId)?.state == SshConnectionState.connecting,
  );

  Future<void> waitForInvocation(String method) =>
      waitUntil(() => background.invocations.contains(method));

  Future<void> waitUntil(bool Function() condition) async {
    for (var attempt = 0; attempt < 200; attempt++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Timed out waiting for SSH fixture state.');
  }
}

Future<void> pumpEventLoop() => Future<void>.delayed(Duration.zero);

FlutterBackgroundServicePlatform? _tryReadBackgroundPlatform() {
  try {
    return FlutterBackgroundServicePlatform.instance;
  } on Object {
    return null;
  }
}

Future<void> _addScenarioConnection(
  TestStorageAdapter storage,
  String id,
) async {
  await storage.connectionRepository.addConnection(
    ConnectionConfig(
      id: id,
      name: id,
      host: '198.51.100.10',
      username: 'fixture-user',
      hostKeyFingerprint: 'SHA256:fixture',
    ),
  );
  await storage.credentialRepository.saveCredentials(
    connectionId: id,
    password: 'fixture-password',
  );
}

final class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.supportPath);

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => supportPath;

  @override
  Future<String?> getTemporaryPath() async => supportPath;
}

/// Native connector that resolves a peer but fails open immediately.
final class ThrowingNativeConnector
    implements ssh_core.SshNativeStreamConnector {
  final List<String> openedPeerIds = <String>[];

  @override
  Future<ssh_core.SshNativeStream> open({
    required String peerId,
    String service = ssh_core.kSshNativeStreamService,
    String? traceId,
  }) {
    openedPeerIds.add(peerId);
    throw StateError('fixture native stream open failed');
  }

  @override
  Future<void> closeAll() async {}
}

final class FakeBackgroundServicePlatform
    extends FlutterBackgroundServicePlatform {
  final Map<String, StreamController<Map<String, dynamic>?>> _events = {};
  final List<String> invocations = <String>[];
  final List<({String method, Map<String, dynamic>? args})> invocationRecords =
      <({String method, Map<String, dynamic>? args})>[];
  bool running = false;
  int stopRequests = 0;

  @override
  Future<bool> configure({
    required IosConfiguration iosConfiguration,
    required AndroidConfiguration androidConfiguration,
  }) async => true;

  @override
  Future<bool> start() async {
    running = true;
    return true;
  }

  @override
  Future<bool> isServiceRunning() async => running;

  @override
  void invoke(String method, [Map<String, dynamic>? args]) {
    invocations.add(method);
    invocationRecords.add((method: method, args: args));
    if (method == 'stopService') {
      stopRequests++;
      running = false;
      emit('sshServiceStopped', const <String, dynamic>{});
    }
  }

  @override
  Stream<Map<String, dynamic>?> on(String method) {
    return _events
        .putIfAbsent(
          method,
          () => StreamController<Map<String, dynamic>?>.broadcast(sync: true),
        )
        .stream;
  }

  void emit(String method, Map<String, dynamic> data) {
    _events[method]?.add(data);
  }

  Future<void> dispose() async {
    await Future.wait<void>(
      _events.values.map((controller) => controller.close()),
    );
  }
}

final class _GrantedPermissionPlatform extends PermissionHandlerPlatform {
  @override
  Future<PermissionStatus> checkPermissionStatus(Permission permission) async {
    return PermissionStatus.granted;
  }

  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    return <Permission, PermissionStatus>{
      for (final permission in permissions)
        permission: PermissionStatus.granted,
    };
  }
}

final class _StallingNativeConnector
    implements ssh_core.SshNativeStreamConnector {
  final Set<_StallingNativeStream> _streams = <_StallingNativeStream>{};

  @override
  Future<ssh_core.SshNativeStream> open({
    required String peerId,
    String service = ssh_core.kSshNativeStreamService,
    String? traceId,
  }) async {
    final stream = _StallingNativeStream();
    _streams.add(stream);
    return stream;
  }

  @override
  Future<void> closeAll() async {
    for (final stream in _streams.toList(growable: false)) {
      stream.destroy();
    }
  }
}

final class _StallingNativeStream implements ssh_core.SshNativeStream {
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast(sync: true);
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) throw StateError('fixture stream is closed');
  }

  @override
  Future<void> close() async => destroy();

  @override
  void destroy() {
    if (_closed) return;
    _closed = true;
    unawaited(_incoming.close());
    _done.complete();
  }
}
