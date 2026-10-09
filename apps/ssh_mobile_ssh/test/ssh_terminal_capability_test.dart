import 'dart:async';
import 'dart:convert';

import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:ssh_mobile_ssh/app/ssh_direct_session.dart';
import 'package:ssh_mobile_ssh/app/ssh_terminal_capability.dart';

void main() {
  test('open session streams output and closes the shell once', () async {
    final harness = _Harness();
    final sessionId = await harness.capability.openSession('connection-1');

    expect(sessionId, 'session-1');
    expect(harness.prompted, isTrue);
    expect(harness.shell.terminalType, 'xterm-256color');

    harness.shell.stdoutController.add(utf8.encode('hello'));
    harness.shell.stderrController.add(utf8.encode('err'));
    await Future<void>.delayed(Duration.zero);
    expect(harness.capability.getSession(sessionId!)!.outputText, 'helloerr');
    expect(harness.capability.getSession(sessionId)!.isConnected, isTrue);

    harness.capability.sendData(sessionId, 'ls\n');
    harness.capability.resizeTerminal(sessionId, 100, 40);
    expect(harness.shell.writes.single, utf8.encode('ls\n'));
    expect(harness.shell.width, 100);
    expect(harness.shell.height, 40);

    await harness.capability.disconnectSession(sessionId);
    expect(harness.capability.sessions, isEmpty);
    expect(harness.shell.closeCount, 1);
    expect(harness.session.closeCount, 1);

    await harness.capability.close();
    await harness.capability.close();
    expect(await harness.capability.openSession('connection-1'), isNull);
  });

  test('tmux launch writes an attach command', () async {
    final harness = _Harness(
      config: _config(launchMode: TerminalLaunchMode.tmux),
    );

    await harness.capability.openSession('connection-1', displayName: 'Build');

    expect(
      utf8.decode(harness.shell.writes.single),
      "exec tmux new-session -A -s 'build'\r",
    );
    expect(harness.capability.sessions.single.tmuxSessionName, 'build');
    expect(harness.shell.terminalType, 'xterm-256color');
    await harness.capability.close();
  });

  test('credential failures stay redacted and drop the session', () async {
    final capability = SshOnlyTerminalCapability(
      lookupConnection: (_) => _config(),
      openConnection:
          (
            config, {
            required onUnknownHostKey,
            required persistHostKeyTrust,
            credentials,
          }) async {
            throw Exception('password=hunter2');
          },
      confirmHostKey: (_) async => false,
      idFactory: () => 'session-1',
    );

    expect(await capability.openSession('connection-1'), isNull);
    expect(capability.sessions, isEmpty);
    expect(capability.errorMessage, 'SSH connection failed.');
    expect(capability.errorMessage, isNot(contains('hunter2')));
    await capability.close();
  });

  test('second window gets a unique display name', () async {
    final harness = _Harness();
    await harness.capability.openSession('connection-1');
    final secondShell = _FakeShell();
    harness.session = _FakeDirectSession(secondShell);
    harness.shell = secondShell;
    await harness.capability.openSession('connection-1');

    expect(
      harness.capability.sessions.map((session) => session.displayName),
      <String>['Server', 'Server 2'],
    );
    expect(harness.capability.renameSession('session-1', 'Server 2'), isFalse);
    expect(harness.capability.renameSession('session-1', 'Logs'), isTrue);
    expect(harness.capability.getSession('session-1')!.displayName, 'Logs');
    await harness.capability.close();
  });

  test('missing connection does not open a session', () async {
    final capability = SshOnlyTerminalCapability(
      lookupConnection: (_) => null,
      openConnection:
          (
            config, {
            required onUnknownHostKey,
            required persistHostKeyTrust,
            credentials,
          }) async => throw StateError('should not connect'),
      confirmHostKey: (_) async => true,
    );

    expect(await capability.openSession('missing'), isNull);
    expect(capability.errorMessage, 'Connection is unavailable.');
    await capability.close();
  });

  test('session controls keep history, font, and reconnect bounds', () async {
    final harness = _Harness(
      config: _config(terminalWidth: 0, terminalHeight: 0),
    );
    final events = <void>[];
    final subscription = harness.capability.changes.listen(events.add);
    final sessionId = await harness.capability.openSession(
      'connection-1',
      displayName: '   ',
    );

    expect(sessionId, 'session-1');
    expect(harness.capability.sessions.single.displayName, 'Server');
    expect(harness.session.width, 80);
    expect(harness.session.height, 24);
    expect(
      await harness.capability.loadSessionHistoryText(sessionId!),
      isEmpty,
    );
    expect(await harness.capability.loadSessionHistoryText('missing'), isEmpty);
    expect(harness.capability.getSession('missing'), isNull);

    harness.capability.setSessionFontSize(sessionId, 1);
    expect(
      harness.capability.getSession(sessionId)!.fontSize,
      SshSession.minTerminalFontSize,
    );
    harness.capability.setSessionFontSize(sessionId, 100);
    expect(
      harness.capability.getSession(sessionId)!.fontSize,
      SshSession.maxTerminalFontSize,
    );
    harness.capability.setSessionFontSize('missing', 12);
    harness.capability.sendData('missing', 'ls');
    harness.capability.sendData(sessionId, '');
    harness.capability.resizeTerminal(sessionId, 0, 24);
    expect(harness.shell.writes, isEmpty);

    expect(await harness.capability.ensureConnected('connection-1'), isTrue);
    expect(
      await harness.capability.ensureSessionConnected(
        sessionId,
        'connection-1',
      ),
      isTrue,
    );
    expect(harness.openCount, 1);

    harness.shell.doneCompleter.complete();
    await Future<void>.delayed(Duration.zero);
    expect(
      harness.capability.getSession(sessionId)!.state,
      SshConnectionState.disconnected,
    );

    final replacement = _FakeShell();
    harness.session = _FakeDirectSession(replacement);
    harness.shell = replacement;
    expect(
      await harness.capability.ensureSessionConnected(
        sessionId,
        'connection-1',
      ),
      isTrue,
    );
    expect(harness.openCount, 2);
    expect(
      await harness.capability.ensureSessionConnected(
        'missing',
        'connection-1',
      ),
      isFalse,
    );
    expect(events, isNotEmpty);

    await subscription.cancel();
    await harness.capability.disconnect();
    expect(harness.capability.sessions, isEmpty);
    await harness.capability.close();
  });

  test('reconnect failure stays redacted and keeps the window', () async {
    final harness = _Harness();
    final sessionId = await harness.capability.openSession('connection-1');
    harness.shell.doneCompleter.complete();
    await Future<void>.delayed(Duration.zero);
    harness.failNextOpen = Exception('private key material');

    expect(
      await harness.capability.ensureSessionConnected(
        sessionId!,
        'connection-1',
      ),
      isFalse,
    );
    expect(harness.capability.errorMessage, 'SSH connection failed.');
    expect(
      harness.capability.getSession(sessionId)!.state,
      SshConnectionState.error,
    );
    await harness.capability.close();
  });

  test('a closed capability drops a connection that finishes late', () async {
    final gate = Completer<SshDirectSession>();
    final session = _FakeDirectSession(_FakeShell());
    final capability = SshOnlyTerminalCapability(
      lookupConnection: (_) => _config(),
      openConnection:
          (
            config, {
            required onUnknownHostKey,
            required persistHostKeyTrust,
            credentials,
          }) => gate.future,
      confirmHostKey: (_) async => false,
      idFactory: () => 'session-1',
    );

    final opening = capability.openSession('connection-1');
    await Future<void>.delayed(Duration.zero);
    await capability.close();
    gate.complete(session);
    expect(await opening, isNull);
    expect(session.closeCount, 1);
  });

  test('windows hosts request the ms-terminal type', () async {
    final harness = _Harness(
      config: _config(serverPlatform: ServerPlatform.windows),
    );

    await harness.capability.openSession('connection-1');

    expect(harness.shell.terminalType, 'ms-terminal');
    await harness.capability.close();
  });

  test('public errors hide credential text', () {
    expect(
      sshPublicError(Exception('password=hunter2')),
      'SSH connection failed.',
    );
    expect(
      sshPublicError(StateError('direct connection refused')),
      contains('direct connection refused'),
    );
  });
}

final class _Harness {
  _Harness({ConnectionConfig? config}) : config = config ?? _config() {
    shell = _FakeShell();
    session = _FakeDirectSession(shell);
    var next = 1;
    capability = SshOnlyTerminalCapability(
      lookupConnection: (_) => this.config,
      openConnection:
          (
            config, {
            required onUnknownHostKey,
            required persistHostKeyTrust,
            credentials,
          }) async {
            openCount++;
            final failure = failNextOpen;
            if (failure != null) {
              failNextOpen = null;
              throw failure;
            }
            expect(persistHostKeyTrust, isTrue);
            expect(credentials, isNull);
            final accepted = await onUnknownHostKey?.call(
              SshHostKeyPromptRequest(
                connectionId: config.id,
                connectionName: config.name,
                host: config.host,
                port: config.port,
                username: config.username,
                algorithm: 'ssh-ed25519',
                fingerprint: 'aa:bb',
              ),
            );
            prompted = accepted == true;
            return session;
          },
      confirmHostKey: (_) async => true,
      idFactory: () => 'session-${next++}',
    );
  }

  final ConnectionConfig config;
  late _FakeShell shell;
  late _FakeDirectSession session;
  late final SshOnlyTerminalCapability capability;
  bool prompted = false;
  int openCount = 0;
  Object? failNextOpen;
}

ConnectionConfig _config({
  TerminalLaunchMode launchMode = TerminalLaunchMode.ssh,
  ServerPlatform serverPlatform = ServerPlatform.linux,
  int terminalWidth = 80,
  int terminalHeight = 24,
}) {
  return ConnectionConfig(
    id: 'connection-1',
    name: 'Server',
    host: 'example.test',
    username: 'user',
    launchMode: launchMode,
    serverPlatform: serverPlatform,
    terminalWidth: terminalWidth,
    terminalHeight: terminalHeight,
  );
}

final class _FakeShell implements SshDirectShell {
  final StreamController<List<int>> stdoutController =
      StreamController<List<int>>();
  final StreamController<List<int>> stderrController =
      StreamController<List<int>>();
  final doneCompleter = Completer<void>();
  final writes = <List<int>>[];
  int? width;
  int? height;
  String? terminalType;
  int closeCount = 0;

  @override
  Stream<List<int>> get stdout => stdoutController.stream;

  @override
  Stream<List<int>> get stderr => stderrController.stream;

  @override
  Future<void> get done => doneCompleter.future;

  @override
  void write(List<int> data) => writes.add(List<int>.of(data));

  @override
  void resizeTerminal(int width, int height) {
    this.width = width;
    this.height = height;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}

final class _FakeDirectSession implements SshDirectSession {
  _FakeDirectSession(this.shell);

  final _FakeShell shell;
  int closeCount = 0;

  @override
  Future<SshDirectShell> openShell({
    required int width,
    required int height,
    required String terminalType,
  }) async {
    shell.terminalType = terminalType;
    this.width = width;
    this.height = height;
    return shell;
  }

  int? width;
  int? height;

  @override
  Future<void> close() async {
    closeCount++;
  }
}
