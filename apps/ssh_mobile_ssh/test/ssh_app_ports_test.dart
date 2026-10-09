import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:ssh_mobile_ssh/app/ssh_app_ports.dart';
import 'package:ssh_mobile_ssh/app/ssh_direct_session.dart';
import 'package:ssh_mobile_ssh/app/ssh_host_key_dialog.dart';
import 'package:ssh_mobile_ssh/app/ssh_terminal_capability.dart';

void main() {
  test('settings and shortcuts stay in memory', () async {
    final settings = SshOnlySettings();
    var notices = 0;
    settings.addListener(() => notices++);
    settings.toggleTheme();
    await settings.setTerminalThemeId('contrast');
    await settings.setTerminalFontFamily('Consolas');

    expect(settings.isDarkMode, isTrue);
    expect(settings.terminalThemeId, 'contrast');
    expect(settings.terminalFontFamily, 'Consolas');
    expect(notices, 3);

    final shortcuts = SshOnlyShortcuts();
    final original = shortcuts.quickCommandIds;
    await shortcuts.recordUse('tab');
    await shortcuts.reorderCommands(<String>['enter', 'tab']);
    expect(shortcuts.orderVersion, 1);
    expect(shortcuts.quickCommandIds, <String>['enter', 'tab']);
    await shortcuts.setQuickCommandIds(<String>['esc']);
    expect(shortcuts.quickCommandIds, <String>['esc']);
    await shortcuts.resetQuickCommandIds();
    expect(shortcuts.quickCommandIds, original);
    await shortcuts.addCustomCommand('Top', 'top');
    expect(shortcuts.customCommands.single.label, 'Top');
    expect(shortcuts.sortByUsage(shortcuts.customCommands).single.code, 'top');
    await shortcuts.removeCustomCommand(shortcuts.customCommands.single.id);
    expect(shortcuts.customCommands, isEmpty);
  });

  test(
    'connection port forwards lookup, sessions, and a missing navigator',
    () async {
      final repository = _MemoryConnections(<ConnectionConfig>[_config()]);
      final capability = _capability(repository);
      final connections = SshOnlyConnections(
        repository: repository,
        terminal: capability,
        navigatorKey: GlobalKey<NavigatorState>(),
      );

      expect(connections.getConnection('missing'), isNull);
      expect(connections.getConnection('connection-1')!.host, 'example.test');
      expect(connections.defaultDisplayNameForConnection('missing'), 'missing');
      expect(
        await connections.openSession('connection-1', displayName: 'Logs'),
        'session-1',
      );
      await connections.openConnectionEditor('connection-1');
      expect(capability.sessions.single.displayName, 'Logs');
      await capability.close();
    },
  );

  test(
    'runtime port counts and closes only the requested connection',
    () async {
      final capability = _capability(
        _MemoryConnections(<ConnectionConfig>[_config()]),
      );
      final port = SshOnlyRuntimePort(capability);
      final sessionId = await port.openTerminalSession('connection-1', 'Logs');

      expect(sessionId, 'session-1');
      expect(await port.activeWindowCount('connection-1'), 1);
      expect(port.errorMessage, isNull);
      await port.cleanupConnectionResources('connection-1');
      expect(await port.activeWindowCount('connection-1'), 0);
      expect(capability.sessions, isEmpty);
      await capability.close();
    },
  );

  test('logger and save failure omit credential text', () {
    final logger = AppLoggerImpl();
    final terminalLogger = SshOnlyLogger(logger);
    terminalLogger.info('opened');
    terminalLogger.warning('slow');
    terminalLogger.error('closed', error: StateError('socket'));
    SshConnectionUiAdapter(logger).logSaveFailure(
      error: Exception('password=hunter2'),
      stackTrace: StackTrace.empty,
      config: _config(),
    );
    SshConnectionUiAdapter(logger).logSaveFailure(
      error: StateError('disk full'),
      stackTrace: StackTrace.empty,
      config: null,
    );

    final records = logger.buffer.oldestFirst;
    expect(records.map((record) => record.message), <String>[
      'opened',
      'slow',
      'closed',
      'Connection save failed',
      'Connection save failed',
    ]);
    expect(records.every((record) => record.source == 'ssh_app'), isTrue);
    expect(records[3].error, 'SSH connection failed.');
    expect(records[3].details, 'connection=Server host=example.test:22');
    expect('${records[3].error}'.contains('hunter2'), isFalse);
    expect(records[4].details, isNull);
    expect(records[4].error, contains('disk full'));
  });

  testWidgets('host key dialog rejects and trusts without a password field', (
    tester,
  ) async {
    final gateway = SshHostKeyPromptGateway();
    final request = SshHostKeyPromptRequest(
      connectionId: 'connection-1',
      connectionName: 'Server',
      host: 'example.test',
      port: 22,
      username: 'user',
      algorithm: 'ssh-ed25519',
      fingerprint: 'aa:bb',
    );
    expect(await gateway.confirm(request), isFalse);

    bool? result;
    bool? adapted;
    final adapter = SshConnectionUiAdapter(AppLoggerImpl());
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Column(
              children: [
                TextButton(
                  onPressed: () async {
                    result = await showSshHostKeyDialog(
                      context: context,
                      name: request.connectionName,
                      host: request.host,
                      port: request.port,
                      username: request.username,
                      algorithm: request.algorithm,
                      fingerprint: request.fingerprint,
                    );
                  },
                  child: const Text('open'),
                ),
                TextButton(
                  onPressed: () async {
                    adapted = await adapter.confirmHostKey(
                      context,
                      ConnectionHostKeyPrompt(
                        connectionId: request.connectionId,
                        connectionName: request.connectionName,
                        host: request.host,
                        port: request.port,
                        username: request.username,
                        algorithm: request.algorithm,
                        fingerprint: request.fingerprint,
                      ),
                    );
                  },
                  child: const Text('adapt'),
                ),
              ],
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    expect(find.text('信任主机密钥'), findsOneWidget);
    expect(find.textContaining('user@example.test:22'), findsOneWidget);
    expect(find.textContaining('password'), findsNothing);
    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(result, isFalse);

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.tap(find.text('信任'));
    await tester.pump();
    expect(result, isTrue);

    await tester.tap(find.text('adapt'));
    await tester.pump();
    await tester.tap(find.text('信任'));
    await tester.pump();
    expect(adapted, isTrue);

    gateway.prompt = (_) async => true;
    expect(await gateway.confirm(request), isTrue);
  });

  testWidgets('connection editor uses the app navigator', (tester) async {
    final key = GlobalKey<NavigatorState>();
    final connections = SshOnlyConnections(
      repository: _MemoryConnections(const []),
      terminal: _capability(_MemoryConnections(const [])),
      navigatorKey: key,
    );
    final seen = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        home: const SizedBox.shrink(),
        onGenerateRoute: (settings) {
          seen.add(settings.name!);
          return MaterialPageRoute<void>(builder: (_) => Text(settings.name!));
        },
      ),
    );

    final adding = connections.openConnectionEditor('new', isNew: true);
    await tester.pump();
    key.currentState!.pop();
    await adding;
    await tester.pump();
    final editing = connections.openConnectionEditor('connection-1');
    await tester.pump();

    expect(seen, <String>[ConnectionRouteNames.add, ConnectionRouteNames.edit]);
    key.currentState!.pop();
    await editing;
  });
}

ConnectionConfig _config() {
  return ConnectionConfig(
    id: 'connection-1',
    name: 'Server',
    host: 'example.test',
    username: 'user',
  );
}

SshOnlyTerminalCapability _capability(ConnectionRepository repository) {
  return SshOnlyTerminalCapability(
    lookupConnection: repository.getConnection,
    openConnection:
        (
          config, {
          required onUnknownHostKey,
          required persistHostKeyTrust,
          credentials,
        }) async => _IdleSession(),
    confirmHostKey: (_) async => true,
    idFactory: () => 'session-1',
  );
}

final class _IdleSession implements SshDirectSession {
  @override
  Future<void> close() async {}

  @override
  Future<SshDirectShell> openShell({
    required int width,
    required int height,
    required String terminalType,
  }) async {
    return _IdleShell();
  }
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
