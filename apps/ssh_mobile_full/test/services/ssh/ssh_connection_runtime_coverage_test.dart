import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connection_core/connection_core.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/core/services/ssh_client_factory.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/app_log_service.dart';

import '../../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storage;
  late _FakeSshClientFactory factory;
  late SshService ssh;
  late Directory supportDirectory;
  late PathProviderPlatform previousPathProvider;
  late List<_ManualTimer> timers;

  setUp(() async {
    // The process logger outlives each fixture; drain before switching its path.
    await AppLogService.instance.pendingWrites;
    AppLogService.instance.resetLogFileForTesting();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    previousPathProvider = PathProviderPlatform.instance;
    supportDirectory = await Directory.systemTemp.createTemp('ssh-runtime-');
    PathProviderPlatform.instance = _FakePathProviderPlatform(
      supportDirectory.path,
    );
    storage = TestStorageAdapter();
    await storage.addConnection(
      ConnectionConfig(
        id: 'local',
        name: 'Local fixture',
        host: '198.51.100.20',
        port: 22,
        username: 'fixture-user',
        serverPlatform: ServerPlatform.linux,
      ),
    );
    await storage.credentialRepository.saveCredentials(
      connectionId: 'local',
      password: 'fixture-password',
    );
    factory = _FakeSshClientFactory(storage);
    timers = <_ManualTimer>[];
    ssh = SshService(
      connectionRepository: storage.connectionRepository,
      credentialRepository: storage.credentialRepository,
      hostKeyRepository: storage.hostKeyRepository,
      terminalMetadataStore: storage.terminalMetadataStore,
      clientFactory: factory,
      reconnectDelay: (_) => Duration.zero,
      timerFactory: (duration, callback) {
        final timer = _ManualTimer(callback);
        timers.add(timer);
        return timer;
      },
    );
  });

  tearDown(() async {
    await ssh.close();
    await factory.dispose();
    await storage.shutdown();
    storage.dispose();
    await AppLogService.instance.pendingWrites;
    PathProviderPlatform.instance = previousPathProvider;
    await supportDirectory.delete(recursive: true);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'local runtime forwards terminal IO, one-shot commands, and cleanup',
    () async {
      await ssh.ensureInitialized();
      await ssh.connect('local', sessionId: 'local-io', displayName: ' Main ');

      final session = ssh.getSession('local-io')!;
      final client = factory.clients.first;
      expect(session.state, SshConnectionState.connected);
      expect(session.displayName, 'Main');
      expect(ssh.isConnected, isTrue);

      client.session.emitStdout('hello\n');
      client.session.emitStderr('warning\n');
      await _pump();
      expect(session.outputText, contains('hello'));
      expect(session.outputText, contains('warning'));

      ssh.sendData('local-io', 'echo ready\n');
      ssh.sendBytes('local-io', Uint8List.fromList(utf8.encode('bytes\n')));
      ssh.resizeTerminal('local-io', 120, 40);
      expect(client.session.stdinText, contains('echo ready\n'));
      expect(client.session.stdinText, contains('bytes\n'));
      expect(client.session.resizeCalls, <({int width, int height})>[
        (width: 120, height: 40),
      ]);

      final result = await ssh.runOneShotCommand(
        connectionId: 'local',
        command: 'printf fixture',
      );
      expect(result.exitCode, 0);
      expect(result.stdout, 'fixture stdout');
      expect(result.stderr, 'fixture stderr');
      expect(factory.clients.last.runCommands, contains('printf fixture'));

      await ssh.disconnectSession('local-io');
      expect(ssh.getSession('local-io'), isNull);
      expect(client.closeCalls, 1);
      expect(client.session.closeCalls, 1);
    },
  );

  test('local tmux runtime builds attach and kill commands', () async {
    await storage.updateConnection(
      storage
          .getConnection('local')!
          .copyWith(
            launchMode: TerminalLaunchMode.tmux,
            serverPlatform: ServerPlatform.linux,
          ),
    );
    await ssh.ensureInitialized();
    await ssh.connect('local', sessionId: 'local-tmux');

    final client = factory.clients.first;
    final session = ssh.getSession('local-tmux')!;
    expect(session.tmuxSessionName, isNotNull);
    expect(client.session.writes.single, contains('exec tmux new-session -A'));

    await ssh.disconnectSession('local-tmux');
    expect(client.runCommands, contains(contains('tmux kill-session')));
  });

  test('local runtime reconnects after a shell completion', () async {
    await ssh.ensureInitialized();
    await ssh.connect('local', sessionId: 'local-reconnect');
    final first = factory.clients.first;

    first.session.completeDone();
    await _waitUntil(() => factory.clients.length >= 2);
    expect(
      ssh.getSession('local-reconnect')!.state,
      SshConnectionState.connected,
    );
    expect(factory.clients[1].session.closeCalls, 0);

    await ssh.disconnectSession('local-reconnect');
  });

  test('reconnect stops when the saved target no longer matches', () async {
    await ssh.ensureInitialized();
    await ssh.connect('local', sessionId: 'local-target-change');
    final first = factory.clients.first;
    await storage.updateConnection(
      storage.getConnection('local')!.copyWith(host: '203.0.113.44'),
    );

    first.session.completeDone();
    await _waitUntil(
      () =>
          ssh.getSession('local-target-change')?.state ==
          SshConnectionState.error,
    );
    expect(
      ssh.getSession('local-target-change')?.errorMessage,
      contains('target changed'),
    );
  });

  test('reconnect reports exhausted attempts when every retry fails', () async {
    await ssh.ensureInitialized();
    await ssh.connect('local', sessionId: 'local-retry-failure');
    factory.connectError = StateError('retry failed');
    factory.clients.first.session.completeDone();

    await _waitUntil(
      () =>
          ssh.getSession('local-retry-failure')?.errorMessage ==
          'Reconnect failed after 5 attempts',
    );
  });

  test(
    'keep-alive handles success, in-flight timeout, and repeated failures',
    () async {
      await ssh.ensureInitialized();
      await ssh.connect('local', sessionId: 'local-keepalive-success');
      final successTimer = timers.last;
      successTimer.fire();
      await _waitUntil(() => factory.clients.first.pingCalls == 1);
      expect(factory.clients.first.pingCalls, 1);

      final pingGate = Completer<void>();
      factory.pingGate = pingGate;
      await ssh.connect('local', sessionId: 'local-keepalive-timeout');
      final timeoutClient = factory.clients.last;
      final timeoutTimer = timers.last;
      timeoutTimer.fire();
      await _waitUntil(() => timeoutClient.pingCalls == 1);
      timeoutTimer.fire();
      timeoutTimer.fire();
      timeoutTimer.fire();
      factory.connectError = StateError('reconnect after keep-alive failed');
      pingGate.complete();
      await _waitUntil(
        () =>
            ssh.getSession('local-keepalive-timeout')?.errorMessage ==
            'Reconnect failed after 5 attempts',
      );
    },
  );

  test('local shell setup and tmux cleanup failures are recorded', () async {
    await ssh.ensureInitialized();
    factory.shellError = StateError('shell open failed');
    factory.closeError = StateError('client close failed');
    await ssh.connect('local', sessionId: 'local-shell-failure');
    expect(
      ssh.getSession('local-shell-failure')?.state,
      SshConnectionState.error,
    );

    factory.shellError = null;
    factory.closeError = null;
    factory.runError = StateError('tmux kill failed');
    await storage.updateConnection(
      storage
          .getConnection('local')!
          .copyWith(launchMode: TerminalLaunchMode.tmux),
    );
    await ssh.connect('local', sessionId: 'local-tmux-failure');
    await ssh.disconnectSession('local-tmux-failure');
    factory.runError = null;
  });

  test(
    'local connection and one-shot failures are surfaced and cleaned up',
    () async {
      await ssh.ensureInitialized();
      factory.connectError = StateError('fixture connect failure');
      await ssh.connect('local', sessionId: 'local-failure');
      final failed = ssh.getSession('local-failure')!;
      expect(failed.state, SshConnectionState.error);
      expect(failed.errorMessage, contains('fixture connect failure'));

      factory.connectError = null;
      factory.runError = StateError('fixture command failure');
      await expectLater(
        ssh.runOneShotCommand(connectionId: 'local', command: 'false'),
        throwsA(isA<StateError>()),
      );
      expect(factory.clients.last.closeCalls, 1);
    },
  );
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for local SSH runtime fixture.');
}

final class _FakeSshClientFactory implements SshClientFactory {
  _FakeSshClientFactory(this.storage);

  final TestStorageAdapter storage;
  final List<_FakeSshClient> clients = <_FakeSshClient>[];
  Object? connectError;
  Object? runError;
  Object? shellError;
  Object? closeError;
  Object? pingError;
  Completer<void>? pingGate;

  @override
  Future<SSHClient> connectClient(
    ConnectionConfig config, {
    Duration timeout = const Duration(seconds: 15),
    ssh_core.SshCredentials? credentials,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    String? peerId,
    String? traceId,
    bool persistHostKeyTrust = true,
    Future<void> Function(ConnectionConfig? authenticatedConfig)?
    validateTarget,
  }) async {
    final error = connectError;
    if (error != null) throw error;
    final client = _FakeSshClient(
      runError: runError,
      shellError: shellError,
      closeError: closeError,
      pingError: pingError,
      pingGate: pingGate,
    );
    clients.add(client);
    return client;
  }

  Future<void> dispose() async {
    for (final client in clients) {
      await client.session.dispose();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SshClientFactory call: $invocation');
}

final class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

final class _FakeSshClient implements SSHClient {
  _FakeSshClient({
    this.runError,
    this.shellError,
    this.closeError,
    this.pingError,
    this.pingGate,
  }) : session = _FakeSshSession();

  final _FakeSshSession session;
  final Object? runError;
  final Object? shellError;
  final Object? closeError;
  final Object? pingError;
  final Completer<void>? pingGate;
  final List<String> runCommands = <String>[];
  int closeCalls = 0;
  int pingCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #authenticated) return Future<void>.value();
    if (invocation.memberName == #shell) {
      if (shellError != null) throw shellError!;
      return Future<SSHSession>.value(session);
    }
    if (invocation.memberName == #runWithResult) {
      runCommands.add(invocation.positionalArguments.first as String);
      final error = runError;
      if (error != null) throw error;
      return Future<SSHRunResult>.value(
        SSHRunResult(
          output: Uint8List.fromList(utf8.encode('fixture output')),
          stdout: Uint8List.fromList(utf8.encode('fixture stdout')),
          stderr: Uint8List.fromList(utf8.encode('fixture stderr')),
          exitCode: 0,
          exitSignal: null,
        ),
      );
    }
    if (invocation.memberName == #run) {
      runCommands.add(invocation.positionalArguments.first as String);
      return Future<Uint8List>.value(Uint8List(0));
    }
    if (invocation.memberName == #ping) return _ping();
    if (invocation.memberName == #close) {
      closeCalls++;
      if (closeError != null) throw closeError!;
      return Future<void>.value();
    }
    throw UnsupportedError('Unexpected SSHClient call: $invocation');
  }

  Future<void> _ping() async {
    pingCalls++;
    if (pingError != null) throw pingError!;
    await pingGate?.future;
  }
}

final class _FakeSshSession implements SSHSession {
  final StreamController<Uint8List> _stdout =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<Uint8List> _stderr =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<Uint8List> _stdin =
      StreamController<Uint8List>.broadcast(sync: true);
  final Completer<void> _done = Completer<void>();
  final List<String> _stdinChunks = <String>[];
  final List<String> writes = <String>[];
  final List<({int width, int height})> resizeCalls =
      <({int width, int height})>[];
  int closeCalls = 0;

  _FakeSshSession() {
    _stdin.stream.listen((data) => _stdinChunks.add(utf8.decode(data)));
  }

  String get stdinText => _stdinChunks.join();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #stdout) return _stdout.stream;
    if (invocation.memberName == #stderr) return _stderr.stream;
    if (invocation.memberName == #stdin) return _stdin.sink;
    if (invocation.memberName == #write) {
      writes.add(
        utf8.decode(invocation.positionalArguments.first as List<int>),
      );
      return null;
    }
    if (invocation.memberName == #resizeTerminal) {
      resizeCalls.add((
        width: invocation.positionalArguments[0] as int,
        height: invocation.positionalArguments[1] as int,
      ));
      return null;
    }
    if (invocation.memberName == #done) return _done.future;
    if (invocation.memberName == #close) {
      closeCalls++;
      return null;
    }
    throw UnsupportedError('Unexpected SSHSession call: $invocation');
  }

  void emitStdout(String value) =>
      _stdout.add(Uint8List.fromList(utf8.encode(value)));

  void emitStderr(String value) =>
      _stderr.add(Uint8List.fromList(utf8.encode(value)));

  void completeDone() {
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> dispose() async {
    completeDone();
    await _stdout.close();
    await _stderr.close();
    await _stdin.close();
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this._callback);

  final void Function(Timer) _callback;
  bool _active = true;
  int _tick = 0;

  void fire() {
    if (!_active) return;
    _tick++;
    _callback(this);
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() {
    _active = false;
  }
}
