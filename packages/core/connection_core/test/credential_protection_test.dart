import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/credential_protection_fakes.dart';

void main() {
  late ProtectionTestStorage storage;
  late ProtectionTestCrypto crypto;
  late SecureCredentialRepository repository;
  setUp(() {
    storage = ProtectionTestStorage();
    crypto = ProtectionTestCrypto();
    repository = SecureCredentialRepository(storage: storage, crypto: crypto);
  });

  test(
    'enabling seals the complete pair and all noninteractive paths lock',
    () async {
      await repository.saveCredentials(
        connectionId: 'server',
        password: 'fixture-password',
        privateKey: 'fixture-key',
      );
      await repository.enableProtection('server');
      expect(repository.supportsProtection, isTrue);
      expect(await repository.isProtected('server'), isTrue);
      final revision = await repository.protectionRevision('server');
      expect(revision, matches(RegExp(r'^[0-9a-f]{64}$')));
      storage.reads.clear();
      await expectLater(
        repository.getPassword('server'),
        protectionError(CredentialProtectionError.locked),
      );
      await expectLater(
        repository.getPrivateKey('server'),
        protectionError(CredentialProtectionError.locked),
      );
      await expectLater(
        repository.saveCredentials(
          connectionId: 'server',
          password: 'replacement',
        ),
        protectionError(CredentialProtectionError.locked),
      );
      expect(
        storage.reads.any(
          (key) => key.startsWith(SecureCredentialRepository.passwordKeyPrefix),
        ),
        isFalse,
      );
      expect(storage.values.values, isNot(contains('fixture-password')));
      final pair = await repository.unlockCredentials(
        'server',
        expectedRevision: revision,
      );
      expect(pair.password, 'fixture-password');
      expect(pair.privateKey, 'fixture-key');
      expect(pair.revision, revision);
      expect(crypto.openCalls, 1);
    },
  );

  test('a corrupt marker cannot expose v2 or legacy credentials', () async {
    await repository.saveCredentials(connectionId: 'server', password: 'old');
    await repository.enableProtection('server');
    final marker = storage.values.keys.firstWhere(
      (key) => key.startsWith('connection.v3.protected.'),
    );
    storage.values[marker] = 'broken';
    storage.values['connection.password.server'] = 'legacy';
    storage.values['connection.v2.password.c2VydmVy'] = 'plain';
    storage.reads.clear();
    for (final operation in [
      repository.getPassword('server'),
      repository.getPrivateKey('server'),
      repository.isProtected('server'),
      repository.protectionRevision('server'),
    ]) {
      await expectLater(
        operation,
        protectionError(CredentialProtectionError.corrupt),
      );
    }
    expect(
      storage.reads.every((key) => key.startsWith('connection.v3.protected.')),
      isTrue,
    );
  });

  test(
    'protected updates authenticate again and require the expected revision',
    () async {
      await repository.saveCredentials(
        connectionId: 'server',
        password: 'first',
      );
      await repository.enableProtection('server');
      final firstRevision = await repository.protectionRevision('server');
      await repository.saveProtectedCredentials(
        connectionId: 'server',
        password: 'second',
        expectedRevision: firstRevision,
      );
      final secondRevision = await repository.protectionRevision('server');
      expect(secondRevision, isNot(firstRevision));
      expect(crypto.sealCalls, 2);
      await expectLater(
        repository.saveProtectedCredentials(
          connectionId: 'server',
          password: 'stale',
          expectedRevision: firstRevision,
        ),
        protectionError(CredentialProtectionError.stale),
      );
      expect((await repository.unlockCredentials('server')).password, 'second');
    },
  );

  test(
    'opaque snapshots restore protected updates without decrypting',
    () async {
      await repository.saveCredentials(
        connectionId: 'server',
        password: 'first',
      );
      await repository.enableProtection('server');
      final snapshot = await repository.captureProtectedSnapshot('server');
      await repository.saveProtectedCredentials(
        connectionId: 'server',
        password: 'second',
        expectedRevision: snapshot.revision,
      );
      expect(crypto.removed, isNot(contains(snapshot.revision)));
      await repository.restoreProtectedSnapshot(snapshot);
      expect(crypto.openCalls, 0);
      expect(await repository.protectionRevision('server'), snapshot.revision);
      expect((await repository.unlockCredentials('server')).password, 'first');
      await repository.discardProtectedSnapshot(snapshot);
    },
  );

  test(
    'disable authenticates once and restores ordinary secure storage semantics',
    () async {
      await repository.saveCredentials(
        connectionId: 'server',
        privateKey: 'fixture-key',
      );
      await repository.enableProtection('server');
      await repository.disableProtection('server');
      expect(await repository.isProtected('server'), isFalse);
      expect(await repository.getPrivateKey('server'), 'fixture-key');
      expect(crypto.openCalls, 1);
    },
  );

  test(
    'cancelled authentication leaves the original values unchanged',
    () async {
      await repository.saveCredentials(
        connectionId: 'server',
        password: 'first',
      );
      crypto.failure = const CredentialProtectionException(
        CredentialProtectionError.cancelled,
      );
      await expectLater(
        repository.enableProtection('server'),
        protectionError(CredentialProtectionError.cancelled),
      );
      expect(await repository.isProtected('server'), isFalse);
      expect(await repository.getPassword('server'), 'first');
    },
  );

  test(
    'a stale request after native seal cannot commit or delete old credentials',
    () async {
      await repository.saveCredentials(
        connectionId: 'server',
        password: 'first',
      );
      var current = true;
      crypto.onSeal = () {
        current = false;
      };
      await expectLater(
        repository.enableProtection('server', isCurrent: () => current),
        protectionError(CredentialProtectionError.stale),
      );
      expect(await repository.isProtected('server'), isFalse);
      expect(await repository.getPassword('server'), 'first');
    },
  );
}

Matcher protectionError(CredentialProtectionError code) => throwsA(
  isA<CredentialProtectionException>().having(
    (error) => error.code,
    'code',
    code,
  ),
);
