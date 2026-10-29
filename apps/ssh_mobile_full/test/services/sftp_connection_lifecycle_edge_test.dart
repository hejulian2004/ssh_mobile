import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/sftp_backend_adapters.dart' hide SftpService;
import 'package:ssh_mobile/app/sftp_io_backend_adapters.dart';
import 'package:ssh_mobile/core/services/ssh_client_factory.dart';

import '../test_utils/test_storage_adapter.dart';
import 'sftp_transfer_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reuses a connected session and rebinds when the target changes',
    () async {
      final storage = TestStorageAdapter();
      final connection = makeConnection('server-1');
      await storage.connectionRepository.addConnection(connection);
      final remote = MemorySftpClient()..setListing('.', const []);
      final factory = FakeSshClientFactory(remote);
      final service = SftpService(
        connectionRepository: storage.connectionRepository,
        credentialRepository: storage.credentialRepository,
        hostKeyRepository: storage.hostKeyRepository,
        clientFactory: factory,
      );
      addTearDown(() {
        service.dispose();
        storage.dispose();
      });

      await service.connect(connection.id);
      await service.connect(connection.id);
      expect(factory.connectCount, 1);
      expect(service.isConnectionOpen(connection.id), isTrue);

      await storage.connectionRepository.updateConnection(
        connection.copyWith(host: 'two.example.com'),
      );
      await service.connect(connection.id);

      expect(factory.connectCount, 2);
      expect(service.state, SftpConnectionState.connected);
    },
  );

  test('duplicate connect calls await the single in-flight task', () async {
    final storage = TestStorageAdapter();
    final connection = makeConnection('server-1');
    await storage.connectionRepository.addConnection(connection);
    final remote = MemorySftpClient()..setListing('.', const []);
    final factory = _DelayedSshClientFactory(remote);
    final service = SftpService(
      connectionRepository: storage.connectionRepository,
      credentialRepository: storage.credentialRepository,
      hostKeyRepository: storage.hostKeyRepository,
      clientFactory: factory,
    );
    addTearDown(() {
      service.dispose();
      storage.dispose();
    });

    final first = service.connect(connection.id);
    await Future<void>.delayed(Duration.zero);
    final second = service.connect(connection.id);
    factory.connectGate.complete();

    await Future.wait([first, second]);
    expect(factory.connectCount, 1);
    expect(service.state, SftpConnectionState.connected);
  });

  test(
    'late SSH client is closed when the connection is removed mid-connect',
    () async {
      final storage = TestStorageAdapter();
      final connection = makeConnection('server-1');
      await storage.connectionRepository.addConnection(connection);
      final remote = MemorySftpClient();
      final factory = _DelayedSshClientFactory(remote);
      final service = SftpService(
        connectionRepository: storage.connectionRepository,
        credentialRepository: storage.credentialRepository,
        hostKeyRepository: storage.hostKeyRepository,
        clientFactory: factory,
      );
      addTearDown(() {
        service.dispose();
        storage.dispose();
      });

      final connecting = service.connect(connection.id);
      await Future<void>.delayed(Duration.zero);
      await service.disconnectConnection(connection.id);
      factory.connectGate.complete();
      await connecting;

      expect(factory.lastClient?.closeCount, 1);
      expect(service.connectionId, isNull);
    },
  );

  test(
    'late SFTP handle is closed when the session is removed mid-open',
    () async {
      final storage = TestStorageAdapter();
      final connection = makeConnection('server-1');
      await storage.connectionRepository.addConnection(connection);
      final factory = _DelayedSftpClientFactory();
      final service = SftpService(
        connectionRepository: storage.connectionRepository,
        credentialRepository: storage.credentialRepository,
        hostKeyRepository: storage.hostKeyRepository,
        clientFactory: factory,
      );
      addTearDown(() {
        service.dispose();
        storage.dispose();
      });

      final connecting = service.connect(connection.id);
      await Future<void>.delayed(Duration.zero);
      await service.disconnectConnection(connection.id);
      factory.sftpGate.complete();
      await connecting;

      expect(factory.lastClient?.closeCount, greaterThanOrEqualTo(1));
      expect(factory.lastSftp?.closeCount, greaterThanOrEqualTo(1));
      expect(service.connectionId, isNull);
    },
  );
}

final class _DelayedSshClientFactory implements SshClientFactory {
  _DelayedSshClientFactory(this.remote);

  final SftpClient remote;
  final Completer<void> connectGate = Completer<void>();
  int connectCount = 0;
  _ClosableSshClient? lastClient;

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
    connectCount++;
    await connectGate.future;
    final client = _ClosableSshClient(remote);
    lastClient = client;
    return client;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SshClientFactory call: $invocation');
}

final class _DelayedSftpClientFactory implements SshClientFactory {
  final Completer<void> sftpGate = Completer<void>();
  int connectCount = 0;
  _ClosableSshClient? lastClient;
  _ClosableSftpClient? lastSftp;

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
    connectCount++;
    final sftp = _ClosableSftpClient(sftpGate);
    lastSftp = sftp;
    final client = _ClosableSshClient(sftp);
    lastClient = client;
    return client;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SshClientFactory call: $invocation');
}

final class _ClosableSshClient implements SSHClient {
  _ClosableSshClient(this.value);

  final Object value;
  int closeCount = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #sftp) {
      if (value is _ClosableSftpClient) {
        return (value as _ClosableSftpClient).openAfterGate();
      }
      return Future<SftpClient>.value(value as SftpClient);
    }
    if (invocation.memberName == #close) {
      closeCount++;
      return Future<void>.value();
    }
    throw UnsupportedError('Unexpected SSHClient call: $invocation');
  }
}

final class _ClosableSftpClient implements SftpClient {
  _ClosableSftpClient(this.gate);

  final Completer<void> gate;
  int closeCount = 0;

  Future<SftpClient> openAfterGate() async {
    await gate.future;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #close) {
      closeCount++;
      return Future<void>.value();
    }
    throw UnsupportedError('Unexpected SFTP client call: $invocation');
  }
}
