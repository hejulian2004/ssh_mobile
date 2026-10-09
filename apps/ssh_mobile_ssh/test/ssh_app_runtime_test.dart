import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:drift/native.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:ssh_mobile_ssh/app/ssh_app.dart';
import 'package:ssh_mobile_ssh/app/ssh_app_ports.dart';
import 'package:ssh_mobile_ssh/app/ssh_app_runtime.dart';
import 'package:ssh_mobile_ssh/app/ssh_direct_session.dart';
import 'package:ssh_mobile_ssh/app/ssh_host_key_dialog.dart';
import 'package:ssh_mobile_ssh/app/ssh_terminal_capability.dart';

void main() {
  test('runtime releases later owners after an SSH close failure', () async {
    final logger = AppLoggerImpl();
    var openedAfterDispose = false;
    final capability = SshOnlyTerminalCapability(
      lookupConnection: (_) => ConnectionConfig(
        id: 'connection-1',
        name: 'Server',
        host: 'example.test',
        username: 'user',
      ),
      openConnection:
          (
            config, {
            required onUnknownHostKey,
            required persistHostKeyTrust,
            credentials,
          }) async {
            openedAfterDispose = true;
            return _ClosableSession(() {});
          },
      confirmHostKey: (_) async => false,
    );
    final manager = _FakeSshSessionManager(
      capability,
      closeError: StateError('injected SSH close failure'),
    );
    final runtime = _runtime(
      logger: logger,
      capability: capability,
      manager: manager,
    );

    await expectLater(runtime.dispose(), throwsA(isA<StateError>()));
    expect(manager.closeCount, 1);
    expect(await capability.openSession('connection-1'), isNull);
    expect(openedAfterDispose, isFalse);
    expect(logger.isDisposed, isTrue);
    expect(identical(runtime.dispose(), runtime.dispose()), isTrue);
  });

  test('verification returns candidate trust without persisting it', () async {
    var persist = true;
    var closed = false;
    final trustedAt = DateTime.utc(2026, 1, 2);
    final port = SshOnlyVerificationPort((
      config, {
      required onUnknownHostKey,
      required persistHostKeyTrust,
      credentials,
    }) async {
      persist = persistHostKeyTrust;
      expect(credentials?.password, 'secret');
      expect(credentials?.privateKey, isNull);
      config.hostKeyAlgorithm = 'ssh-ed25519';
      config.hostKeyFingerprint = 'aa:bb';
      config.hostKeyTrustedAt = trustedAt;
      return _ClosableSession(() => closed = true);
    });
    final config = ConnectionConfig(
      id: 'connection-1',
      name: 'Server',
      host: 'example.test',
      username: 'user',
    );

    final result = await port.verify(
      config,
      password: 'secret',
      privateKey: null,
    );

    expect(persist, isFalse);
    expect(closed, isTrue);
    expect(result.algorithm, 'ssh-ed25519');
    expect(result.fingerprint, 'aa:bb');
    expect(result.trustedAt, trustedAt);
  });

  test(
    'verification maps an unknown host key and keeps trust unpersisted',
    () async {
      SshHostKeyConfirmation? seen;
      var persist = true;
      final port = SshOnlyVerificationPort((
        config, {
        required onUnknownHostKey,
        required persistHostKeyTrust,
        credentials,
      }) async {
        seen = onUnknownHostKey;
        persist = persistHostKeyTrust;
        expect(credentials?.privateKey, 'not-a-key');
        return _ClosableSession(() {});
      });

      final result = await port.verify(
        ConnectionConfig(
          id: 'connection-1',
          name: 'Server',
          host: 'example.test',
          username: 'user',
        ),
        password: null,
        privateKey: 'not-a-key',
        onUnknownHostKey: (prompt) async => prompt.fingerprint == 'aa:bb',
      );

      final accepted = await seen?.call(
        const SshHostKeyPromptRequest(
          connectionId: 'connection-1',
          connectionName: 'Server',
          host: 'example.test',
          port: 22,
          username: 'user',
          algorithm: 'ssh-ed25519',
          fingerprint: 'aa:bb',
        ),
      );
      expect(accepted, isTrue);
      expect(persist, isFalse);
      expect(result.algorithm, isNull);
      expect(result.fingerprint, isNull);
    },
  );

  testWidgets('SSH app widget owner exposes an idempotent exit barrier', (
    tester,
  ) async {
    final logger = AppLoggerImpl();
    final capability = SshOnlyTerminalCapability(
      lookupConnection: (_) => null,
      openConnection:
          (
            config, {
            required onUnknownHostKey,
            required persistHostKeyTrust,
            credentials,
          }) async => throw StateError('unused'),
      confirmHostKey: (_) async => false,
    );
    final manager = _FakeSshSessionManager(capability);
    final module = TerminalModule(
      databaseFactory: () =>
          TerminalDatabase.forTesting(NativeDatabase.memory()),
    );
    await module.register(ModuleContext.fromMap({SshSessionManager: manager}));
    await module.initialize();
    await module.activate();
    final repository = _MemoryConnections([
      ConnectionConfig(
        id: 'connection-1',
        name: 'Server',
        host: 'example.test',
        username: 'user',
      ),
    ]);
    final runtime = _runtime(
      logger: logger,
      capability: capability,
      manager: manager,
      module: module,
      repository: repository,
    );
    final key = GlobalKey<SshOnlyAppState>();

    await tester.pumpWidget(SshOnlyApp(key: key, runtime: runtime));
    await tester.pump();

    expect(find.text('Server'), findsOneWidget);
    expect(find.text('user@example.test:22'), findsOneWidget);

    final first = key.currentState!.shutdown();
    final second = key.currentState!.shutdown();
    expect(identical(first, second), isTrue);
    await tester.pump();
    await first;
    expect(runtime.isDisposed, isTrue);
    expect(manager.closeCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

SshOnlyAppRuntime _runtime({
  required AppLoggerImpl logger,
  required SshOnlyTerminalCapability capability,
  required _FakeSshSessionManager manager,
  TerminalModule? module,
  ConnectionRepository? repository,
}) {
  final connections = repository ?? _MemoryConnections(const []);
  final credentials = _MemoryCredentials();
  final hostKeys = _MemoryHostKeys();
  final navigatorKey = GlobalKey<NavigatorState>();
  return SshOnlyAppRuntime.forTesting(
    logger: logger,
    navigatorKey: navigatorKey,
    hostKeyPrompts: SshHostKeyPromptGateway(),
    sshSessionManager: manager,
    terminalCapability: capability,
    terminalModule: module ?? TerminalModule(),
    settings: SshOnlySettings(),
    shortcuts: SshOnlyShortcuts(),
    connections: SshOnlyConnections(
      repository: connections,
      terminal: capability,
      navigatorKey: navigatorKey,
    ),
    terminalLogger: SshOnlyLogger(logger),
    connectionViewModel: ConnectionViewModel(
      connectionRepository: connections,
      credentialRepository: credentials,
      hostKeyRepository: hostKeys,
      runtimePort: SshOnlyRuntimePort(capability),
      verificationPort: SshOnlyVerificationPort(
        (
          config, {
          required onUnknownHostKey,
          required persistHostKeyTrust,
          credentials,
        }) async => throw StateError('unused'),
      ),
    ),
    uiAdapter: SshConnectionUiAdapter(logger),
    connectionRepository: connections,
  );
}

final class _ClosableSession implements SshDirectSession {
  _ClosableSession(this.onClose);

  final void Function() onClose;

  @override
  Future<void> close() async {
    onClose();
  }

  @override
  Future<SshDirectShell> openShell({
    required int width,
    required int height,
    required String terminalType,
  }) {
    throw UnsupportedError('verification does not open a shell');
  }
}

final class _FakeSshSessionManager implements SshSessionManager {
  _FakeSshSessionManager(this.terminalCapability, {this.closeError});

  @override
  final SshTerminalCapability terminalCapability;

  final Object? closeError;
  int closeCount = 0;

  @override
  bool get initialized => true;

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<SshSessionLease> acquire({
    required String sessionId,
    required Future<SshSession> Function() create,
  }) {
    throw UnsupportedError('This lifecycle test does not acquire a lease.');
  }

  @override
  Future<void> close() async {
    closeCount++;
    final error = closeError;
    if (error != null) throw error;
  }
}

final class _MemoryConnections implements ConnectionRepository {
  _MemoryConnections(List<ConnectionConfig> connections)
    : _connections = List<ConnectionConfig>.of(connections);

  final List<ConnectionConfig> _connections;

  @override
  List<ConnectionConfig> get connections =>
      List<ConnectionConfig>.unmodifiable(_connections);

  @override
  Future<void> initialize() async {}

  @override
  Future<List<ConnectionConfig>> loadConnections() async => connections;

  @override
  Future<void> addConnection(ConnectionConfig config) async {
    _connections.add(config);
  }

  @override
  Future<void> updateConnection(ConnectionConfig config) async {}

  @override
  Future<void> deleteConnection(String id) async {}

  @override
  Future<void> deleteConnections(List<String> ids) async {}

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {}

  @override
  ConnectionConfig? getConnection(String id) {
    for (final config in _connections) {
      if (config.id == id) return config;
    }
    return null;
  }
}

final class _MemoryCredentials implements CredentialRepository {
  @override
  Future<void> deleteCredentials(String connectionId) async {}

  @override
  Future<String?> getPassword(String connectionId) async => null;

  @override
  Future<String?> getPrivateKey(String connectionId) async => null;

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {}
}

final class _MemoryHostKeys implements HostKeyRepository {
  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {}
}
