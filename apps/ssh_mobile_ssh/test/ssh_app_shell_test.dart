import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:drift/native.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:ssh_mobile_ssh/app/ssh_app.dart';
import 'package:ssh_mobile_ssh/app/ssh_app_ports.dart';
import 'package:ssh_mobile_ssh/app/ssh_app_runtime.dart';
import 'package:ssh_mobile_ssh/app/ssh_direct_session.dart';
import 'package:ssh_mobile_ssh/app/ssh_host_key_dialog.dart';
import 'package:ssh_mobile_ssh/app/ssh_terminal_capability.dart';

void main() {
  testWidgets('home opens an editor and reports a redacted connect failure', (
    tester,
  ) async {
    final repository = _MemoryConnections(<ConnectionConfig>[_server()]);
    final app = await _pumpApp(
      tester,
      repository: repository,
      openConnection:
          (
            config, {
            required onUnknownHostKey,
            required persistHostKeyTrust,
            credentials,
          }) async {
            throw Exception('password=hunter2');
          },
    );

    expect(find.text('Server'), findsOneWidget);
    expect(find.text('user@example.test:22'), findsOneWidget);

    await tester.tap(find.text('Server'));
    await tester.pump();
    expect(find.text('SSH connection failed.'), findsOneWidget);
    expect(find.textContaining('hunter2'), findsNothing);

    await tester.tap(find.byTooltip('编辑'));
    await tester.pump();
    await tester.pump();
    expect(find.text('编辑连接'), findsWidgets);

    await app.stop(tester);
  });

  testWidgets('home shows an empty list and the add route', (tester) async {
    final app = await _pumpApp(
      tester,
      repository: _MemoryConnections(const []),
    );

    expect(find.text('还没有连接'), findsOneWidget);
    await tester.tap(find.text('添加连接'));
    await tester.pump();
    await tester.pump();
    expect(find.text('连接名称'), findsWidgets);
    await app.stop(tester);
  });

  testWidgets('home hides a repository failure', (tester) async {
    final repository = _MemoryConnections(const [], failLoad: true);
    final app = await _pumpApp(tester, repository: repository);

    expect(find.text('无法读取连接'), findsOneWidget);
    expect(find.textContaining('db closed'), findsNothing);
    await app.stop(tester);
  });

  testWidgets('routes reject unknown pages and open terminal feature pages', (
    tester,
  ) async {
    final repository = _MemoryConnections(<ConnectionConfig>[_server()]);
    final app = await _pumpApp(tester, repository: repository);
    final navigator = app.runtime.navigatorKey.currentState!;

    final missing = navigator.pushNamed('/missing');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('页面不存在'), findsOneWidget);
    navigator.pop();
    await missing;
    await tester.pump();

    final invalidTerminal = navigator.pushNamed(
      TerminalRouteNames.terminal,
      arguments: <String, Object>{'id': 1},
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('页面不存在'), findsOneWidget);
    navigator.pop();
    await invalidTerminal;
    await tester.pump();

    final terminal = navigator.pushNamed(
      TerminalRouteNames.terminal,
      arguments: <String, String>{
        'id': 'connection-1',
        'sessionId': 'session-1',
      },
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TerminalScreen), findsOneWidget);
    navigator.pop();
    await terminal;
    await tester.pump();

    final history = navigator.pushNamed(TerminalRouteNames.history);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TerminalHistoryScreen), findsOneWidget);
    navigator.pop();
    await history;
    await tester.pump();

    final windows = navigator.pushNamed(
      TerminalRouteNames.windows,
      arguments: 'connection-1',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TerminalWindowsScreen), findsOneWidget);
    navigator.pop();
    await windows;
    await tester.pump();

    final edit = navigator.pushNamed(ConnectionRouteNames.edit, arguments: 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AddEditScreen), findsOneWidget);
    navigator.pop();
    await edit;
    await tester.pump();

    final windowsByMap = navigator.pushNamed(
      TerminalRouteNames.windows,
      arguments: <String, String>{'connectionId': 'connection-1'},
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester
          .widget<TerminalWindowsScreen>(find.byType(TerminalWindowsScreen))
          .connectionId,
      'connection-1',
    );
    navigator.pop();
    await windowsByMap;
    await tester.pump();

    await app.stop(tester);
  });

  testWidgets(
    'home separates connections and reloads after the editor returns',
    (tester) async {
      final repository = _MemoryConnections(
        <ConnectionConfig>[
          _server(),
          _server(id: 'connection-2', name: 'Other', host: 'other.test'),
        ],
        afterRefresh: <ConnectionConfig>[
          _server(),
          _server(id: 'connection-2', name: 'Other', host: 'other.test'),
          _server(id: 'connection-3', name: 'Saved', host: 'saved.test'),
        ],
      );
      final app = await _pumpApp(tester, repository: repository);

      expect(find.text('Server'), findsOneWidget);
      expect(find.text('Other'), findsOneWidget);
      expect(find.text('user@other.test:22'), findsOneWidget);
      expect(find.byType(Divider), findsOneWidget);
      expect(repository.loadCount, 1);

      await tester.tap(find.byTooltip('编辑').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AddEditScreen), findsOneWidget);
      app.runtime.navigatorKey.currentState!.pop('saved');
      await tester.pump();
      await tester.pump();

      expect(repository.loadCount, 2);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('user@saved.test:22'), findsOneWidget);
      await app.stop(tester);
    },
  );

  testWidgets('visible page rejects an unknown host key', (tester) async {
    final app = await _pumpApp(
      tester,
      repository: _MemoryConnections(const []),
    );
    final request = SshHostKeyPromptRequest(
      connectionId: 'connection-1',
      connectionName: 'Server',
      host: 'example.test',
      port: 22,
      username: 'user',
      algorithm: 'ssh-ed25519',
      fingerprint: 'aa:bb',
    );

    final pending = app.runtime.hostKeyPrompts.confirm(request);
    await tester.pump();
    expect(find.text('信任主机密钥'), findsOneWidget);
    expect(find.textContaining('user@example.test:22'), findsOneWidget);
    expect(find.textContaining('aa:bb'), findsOneWidget);
    expect(find.textContaining('password'), findsNothing);
    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(await pending, isFalse);

    await app.stop(tester);
  });

  testWidgets('exit and a missing navigator reject host key trust', (
    tester,
  ) async {
    final app = await _pumpApp(
      tester,
      repository: _MemoryConnections(const []),
    );
    final request = SshHostKeyPromptRequest(
      connectionId: 'connection-1',
      connectionName: 'Server',
      host: 'example.test',
      port: 22,
      username: 'user',
      algorithm: 'ssh-ed25519',
      fingerprint: 'aa:bb',
    );

    final shutdown = app.state.shutdown();
    await tester.pump();
    expect(await app.runtime.hostKeyPrompts.confirm(request), isFalse);
    await shutdown;
    expect(app.runtime.isDisposed, isTrue);

    final exit = app.state.didRequestAppExit();
    await tester.pump();
    expect(await exit, AppExitResponse.exit);
  });

  testWidgets('detached lifecycle releases the runtime', (tester) async {
    final app = await _pumpApp(
      tester,
      repository: _MemoryConnections(const []),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();

    expect(app.runtime.isDisposed, isTrue);
  });
}

Future<_AppHandle> _pumpApp(
  WidgetTester tester, {
  required _MemoryConnections repository,
  SshDirectConnector? openConnection,
}) async {
  final logger = AppLoggerImpl();
  final capability = SshOnlyTerminalCapability(
    lookupConnection: repository.getConnection,
    openConnection:
        openConnection ??
        (
          config, {
          required onUnknownHostKey,
          required persistHostKeyTrust,
          credentials,
        }) async => _IdleSession(),
    confirmHostKey: (_) async => false,
    idFactory: () => 'session-1',
  );
  final manager = _FakeSshSessionManager(capability);
  final module = TerminalModule(
    databaseFactory: () => TerminalDatabase.forTesting(NativeDatabase.memory()),
  );
  await module.register(ModuleContext.fromMap({SshSessionManager: manager}));
  await module.initialize();
  await module.activate();
  final navigatorKey = GlobalKey<NavigatorState>();
  final runtime = SshOnlyAppRuntime.forTesting(
    logger: logger,
    navigatorKey: navigatorKey,
    hostKeyPrompts: SshHostKeyPromptGateway(),
    sshSessionManager: manager,
    terminalCapability: capability,
    terminalModule: module,
    settings: SshOnlySettings(),
    shortcuts: SshOnlyShortcuts(),
    connections: SshOnlyConnections(
      repository: repository,
      terminal: capability,
      navigatorKey: navigatorKey,
    ),
    terminalLogger: SshOnlyLogger(logger),
    connectionViewModel: ConnectionViewModel(
      connectionRepository: repository,
      credentialRepository: _MemoryCredentials(),
      hostKeyRepository: _MemoryHostKeys(),
      runtimePort: SshOnlyRuntimePort(capability),
      verificationPort: SshOnlyVerificationPort(
        (
          config, {
          required onUnknownHostKey,
          required persistHostKeyTrust,
          credentials,
        }) async => _IdleSession(),
      ),
    ),
    uiAdapter: SshConnectionUiAdapter(logger),
    connectionRepository: repository,
  );
  final key = GlobalKey<SshOnlyAppState>();
  await tester.pumpWidget(SshOnlyApp(key: key, runtime: runtime));
  await tester.pump();
  return _AppHandle(runtime, key.currentState!);
}

final class _AppHandle {
  _AppHandle(this.runtime, this.state);

  final SshOnlyAppRuntime runtime;
  final SshOnlyAppState state;

  Future<void> stop(WidgetTester tester) async {
    final pending = state.shutdown();
    await tester.pump();
    await pending;
  }
}

ConnectionConfig _server({
  String id = 'connection-1',
  String name = 'Server',
  String host = 'example.test',
}) {
  return ConnectionConfig(id: id, name: name, host: host, username: 'user');
}

final class _IdleSession implements SshDirectSession {
  @override
  Future<void> close() async {}

  @override
  Future<SshDirectShell> openShell({
    required int width,
    required int height,
    required String terminalType,
  }) async => _IdleShell();
}

final class _IdleShell implements SshDirectShell {
  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  void resizeTerminal(int width, int height) {}

  @override
  void write(List<int> data) {}
}

final class _FakeSshSessionManager implements SshSessionManager {
  _FakeSshSessionManager(this.terminalCapability);

  @override
  final SshTerminalCapability terminalCapability;

  @override
  bool get initialized => true;

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<SshSessionLease> acquire({
    required String sessionId,
    required Future<SshSession> Function() create,
  }) {
    throw UnsupportedError('unused');
  }

  @override
  Future<void> close() async {}
}

final class _MemoryConnections implements ConnectionRepository {
  _MemoryConnections(
    List<ConnectionConfig> connections, {
    this.failLoad = false,
    this.afterRefresh,
  }) : _connections = List<ConnectionConfig>.of(connections);

  final List<ConnectionConfig> _connections;
  final List<ConnectionConfig>? afterRefresh;
  final bool failLoad;
  var loadCount = 0;

  @override
  List<ConnectionConfig> get connections =>
      List<ConnectionConfig>.unmodifiable(_connections);

  @override
  Future<void> initialize() async {}

  @override
  Future<List<ConnectionConfig>> loadConnections() async {
    loadCount += 1;
    if (failLoad) throw StateError('db closed');
    final replacement = afterRefresh;
    if (replacement != null && loadCount > 1) {
      _connections
        ..clear()
        ..addAll(replacement);
    }
    return connections;
  }

  @override
  Future<void> addConnection(ConnectionConfig config) async {}

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
