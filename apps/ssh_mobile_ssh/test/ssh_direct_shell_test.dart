import 'dart:async';
import 'dart:typed_data';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:ssh_mobile_ssh/app/ssh_direct_shell.dart';

void main() {
  test(
    'direct connector rejects a jump host before opening a client',
    () async {
      var opened = false;
      final connector = directTcpConnector(
        openClient:
            (
              config, {
              required onUnknownHostKey,
              required persistHostKeyTrust,
              credentials,
            }) async {
              opened = true;
              throw StateError('should not open');
            },
      );

      await expectLater(
        connector(
          _config(jumpHost: 'jump.example'),
          onUnknownHostKey: null,
          persistHostKeyTrust: false,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('does not use a jump host'),
          ),
        ),
      );
      expect(opened, isFalse);
    },
  );

  test(
    'direct connector forwards trust and credentials to the client opener',
    () async {
      var persist = true;
      SshCredentials? seen;
      final connector = directTcpConnector(
        openClient:
            (
              config, {
              required onUnknownHostKey,
              required persistHostKeyTrust,
              credentials,
            }) async {
              persist = persistHostKeyTrust;
              seen = credentials;
              throw StateError('stop before the shell adapter');
            },
      );

      await expectLater(
        connector(
          _config(),
          onUnknownHostKey: null,
          persistHostKeyTrust: false,
          credentials: const SshCredentials(
            password: 'secret',
            privateKey: null,
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(persist, isFalse);
      expect(seen?.password, 'secret');
    },
  );

  test('factory opener forwards the client request without a socket', () async {
    final client = _FakeSshClient();
    final logger = AppLoggerImpl();
    final factory = _RecordingFactory(client, logger);
    final config = _config();
    const credentials = SshCredentials(password: 'secret', privateKey: null);
    Future<bool> confirm(SshHostKeyPromptRequest request) async => false;

    final opened = await sshCoreClientOpener(factory)(
      config,
      onUnknownHostKey: confirm,
      persistHostKeyTrust: false,
      credentials: credentials,
    );

    expect(opened, same(client));
    expect(factory.config, same(config));
    expect(factory.persistHostKeyTrust, isFalse);
    expect(factory.credentials, same(credentials));
    expect(factory.onUnknownHostKey, same(confirm));
    await logger.dispose();
  });

  test(
    'session adapter forwards the shell and closes the client once',
    () async {
      final stdout = StreamController<Uint8List>();
      final stderr = StreamController<Uint8List>();
      final stdoutStream = stdout.stream;
      final stderrStream = stderr.stream;
      final shell = _FakeSshSession(stdout: stdoutStream, stderr: stderrStream);
      final client = _FakeSshClient(session: shell);
      final session = await directTcpConnector(
        openClient:
            (
              config, {
              required onUnknownHostKey,
              required persistHostKeyTrust,
              credentials,
            }) async => client,
      )(_config(), onUnknownHostKey: null, persistHostKeyTrust: true);

      final opened = await session.openShell(
        width: 100,
        height: 40,
        terminalType: 'xterm-256color',
      );

      expect(client.pty?.width, 100);
      expect(client.pty?.height, 40);
      expect(client.pty?.type, 'xterm-256color');
      final output = <List<int>>[];
      final errors = <List<int>>[];
      final outputSubscription = opened.stdout.listen(output.add);
      final errorSubscription = opened.stderr.listen(errors.add);
      stdout.add(Uint8List.fromList(const <int>[9]));
      stderr.add(Uint8List.fromList(const <int>[8]));
      await Future<void>.value();
      expect(output, <List<int>>[
        <int>[9],
      ]);
      expect(errors, <List<int>>[
        <int>[8],
      ]);
      await outputSubscription.cancel();
      await errorSubscription.cancel();
      opened.write(const <int>[1, 2, 3]);
      expect(shell.written, <int>[1, 2, 3]);
      opened.resizeTerminal(120, 50);
      expect(shell.width, 120);
      expect(shell.height, 50);

      final done = opened.done;
      await opened.close();
      expect(shell.closeCount, 1);
      expect(shell.doneCompleted, isFalse);

      await session.close();
      await session.close();
      expect(client.closeCount, 1);

      shell.complete();
      await done;
      await stdout.close();
      await stderr.close();
    },
  );
}

ConnectionConfig _config({String? jumpHost}) {
  return ConnectionConfig(
    id: 'connection-1',
    name: 'Server',
    host: 'example.test',
    username: 'user',
    jumpHost: jumpHost,
  );
}

final class _RecordingFactory extends SshClientFactory {
  _RecordingFactory(this.client, AppLoggerImpl logger)
    : super(
        credentialRepository: _UnusedCredentials(),
        hostKeyRepository: _UnusedHostKeys(),
        logger: logger,
      );

  final SSHClient client;
  ConnectionConfig? config;
  SshCredentials? credentials;
  SshHostKeyConfirmation? onUnknownHostKey;
  bool? persistHostKeyTrust;

  @override
  Future<SSHClient> connectClient(
    ConnectionConfig config, {
    Duration timeout = const Duration(seconds: 15),
    SshCredentials? credentials,
    SshHostKeyConfirmation? onUnknownHostKey,
    String? peerId,
    String? traceId,
    bool persistHostKeyTrust = true,
  }) async {
    this.config = config;
    this.credentials = credentials;
    this.onUnknownHostKey = onUnknownHostKey;
    this.persistHostKeyTrust = persistHostKeyTrust;
    return client;
  }
}

final class _FakeSshClient extends Fake implements SSHClient {
  _FakeSshClient({this.session});

  final SSHSession? session;
  SSHPtyConfig? pty;
  var closeCount = 0;
  final Completer<void> _done = Completer<void>();

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    this.pty = pty;
    return session!;
  }

  @override
  void close() {
    closeCount += 1;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}

final class _FakeSshSession extends Fake implements SSHSession {
  _FakeSshSession({required this.stdout, required this.stderr});

  @override
  final Stream<Uint8List> stdout;

  @override
  final Stream<Uint8List> stderr;

  final Completer<void> _done = Completer<void>();
  var closeCount = 0;
  Uint8List? written;
  int? width;
  int? height;

  bool get doneCompleted => _done.isCompleted;

  void complete() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  @override
  void write(Uint8List data) {
    written = data;
  }

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {
    this.width = width;
    this.height = height;
  }

  @override
  void close() {
    closeCount += 1;
  }
}

final class _UnusedCredentials implements CredentialRepository {
  @override
  Future<void> deleteCredentials(String connectionId) {
    throw StateError('unused');
  }

  @override
  Future<String?> getPassword(String connectionId) {
    throw StateError('unused');
  }

  @override
  Future<String?> getPrivateKey(String connectionId) {
    throw StateError('unused');
  }

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) {
    throw StateError('unused');
  }
}

final class _UnusedHostKeys implements HostKeyRepository {
  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) {
    throw StateError('unused');
  }
}
