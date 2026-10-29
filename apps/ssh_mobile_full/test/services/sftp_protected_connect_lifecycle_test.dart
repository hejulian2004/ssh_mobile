import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/sftp_io_backend_adapters.dart';

import '../test_utils/test_storage_adapter.dart';
import 'sftp_transfer_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'an invalidated old unlock cannot clear the replacement connect attempt',
    () async {
      final storage = TestStorageAdapter();
      final config = makeConnection('protected-fixture');
      await storage.connectionRepository.addConnection(config);
      final credentials = _BlockedProtectedCredentials()
        ..separateAttempts = true;
      final factory = FakeSshClientFactory(
        MemorySftpClient()..setListing('.', const []),
      );
      final service = SftpService(
        connectionRepository: storage.connectionRepository,
        credentialRepository: credentials,
        hostKeyRepository: storage.hostKeyRepository,
        clientFactory: factory,
      );
      addTearDown(() {
        service.dispose();
        storage.dispose();
      });
      final first = service.connect(config.id);
      await credentials.started.future;
      await service.disconnectConnection(config.id);
      final second = service.connect(config.id);
      await credentials.secondStarted.future;
      credentials.attemptGates.first.complete();
      await first;
      final duplicate = service.connect(config.id);
      expect(identical(second, duplicate), isTrue);
      expect(credentials.unlockCalls, 2);
      credentials.attemptGates[1].complete();
      await Future.wait([second, duplicate]);
      expect(factory.connectCount, 1);
      expect(service.isConnected, isTrue);
    },
  );

  test(
    'connect after service disposal never reads or unlocks credentials',
    () async {
      final storage = TestStorageAdapter();
      final credentials = _BlockedProtectedCredentials();
      final factory = FakeSshClientFactory(MemorySftpClient());
      final service = SftpService(
        connectionRepository: storage.connectionRepository,
        credentialRepository: credentials,
        hostKeyRepository: storage.hostKeyRepository,
        clientFactory: factory,
      );
      service.dispose();
      addTearDown(storage.dispose);
      await expectLater(service.connect('protected-fixture'), throwsStateError);
      expect(credentials.unlockCalls, 0);
      expect(factory.connectCount, 0);
    },
  );

  for (final stop in [
    'dispose',
    'disconnect',
    'disconnectConnection',
    'disconnectAll',
  ]) {
    test(
      '$stop invalidates a protected connect still awaiting biometric unlock',
      () async {
        final storage = TestStorageAdapter();
        final config = makeConnection('protected-fixture');
        await storage.connectionRepository.addConnection(config);
        final credentials = _BlockedProtectedCredentials();
        final factory = FakeSshClientFactory(
          MemorySftpClient()..setListing('.', const []),
        );
        final service = SftpService(
          connectionRepository: storage.connectionRepository,
          credentialRepository: credentials,
          hostKeyRepository: storage.hostKeyRepository,
          clientFactory: factory,
        );
        addTearDown(() async {
          await service.disconnectAll(notify: false);
          if (stop != 'dispose') service.dispose();
          storage.dispose();
        });
        final connecting = service.connect(config.id);
        await credentials.started.future;
        switch (stop) {
          case 'dispose':
            service.dispose();
          case 'disconnect':
            await service.disconnect();
          case 'disconnectConnection':
            await service.disconnectConnection(config.id);
          case 'disconnectAll':
            await service.disconnectAll();
        }
        credentials.release.complete();
        await connecting;
        expect(credentials.unlockCalls, 1);
        expect(
          factory.connectCount,
          0,
          reason:
              'A late credential pair cannot create a new SSH Socket after cancellation.',
        );
        expect(service.isConnected, isFalse);
        expect(service.connectionId, isNull);
      },
    );
  }

  test(
    'duplicate protected connects share the complete unlock attempt',
    () async {
      final storage = TestStorageAdapter();
      final config = makeConnection('protected-fixture');
      await storage.connectionRepository.addConnection(config);
      final credentials = _BlockedProtectedCredentials();
      final factory = FakeSshClientFactory(
        MemorySftpClient()..setListing('.', const []),
      );
      final service = SftpService(
        connectionRepository: storage.connectionRepository,
        credentialRepository: credentials,
        hostKeyRepository: storage.hostKeyRepository,
        clientFactory: factory,
      );
      addTearDown(() {
        service.dispose();
        storage.dispose();
      });
      final first = service.connect(config.id);
      await credentials.started.future;
      final second = service.connect(config.id);
      try {
        await Future<void>.delayed(Duration.zero);
        expect(credentials.unlockCalls, 1);
      } finally {
        credentials.release.complete();
        await Future.wait([first, second]);
      }
      expect(factory.connectCount, 1);
      expect(service.isConnected, isTrue);
    },
  );
}

/// 延迟的是公开凭据能力本身，覆盖真实 resolveIfBound 路径而非 SFTP 私有字段。
final class _BlockedProtectedCredentials extends Fake
    implements CredentialRepository, CredentialProtectionRepository {
  final started = Completer<void>();
  final release = Completer<void>();
  final secondStarted = Completer<void>();
  final attemptGates = <Completer<void>>[];
  bool separateAttempts = false;
  int unlockCalls = 0;
  static const revision =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  @override
  Future<String?> protectionRevision(String connectionId) async => revision;
  @override
  Future<CredentialPair> unlockCredentials(
    String connectionId, {
    String? expectedRevision,
  }) async {
    unlockCalls++;
    if (!started.isCompleted) started.complete();
    if (unlockCalls == 2) secondStarted.complete();
    final gate = separateAttempts ? Completer<void>() : release;
    attemptGates.add(gate);
    await gate.future;
    return const CredentialPair(
      password: 'fixture-password',
      revision: revision,
    );
  }

  @override
  Future<String?> getPassword(String connectionId) =>
      throw StateError('Protected credentials must never fall back.');
  @override
  Future<String?> getPrivateKey(String connectionId) =>
      throw StateError('Protected credentials must never fall back.');
}
