import 'dart:async';
import 'dart:convert';
import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/credential_protection_fakes.dart';

Matcher fails(CredentialProtectionError code) => throwsA(
  isA<CredentialProtectionException>().having((e) => e.code, 'code', code),
);

void main() {
  late ProtectionTestStorage storage;
  late ProtectionTestCrypto crypto;
  late SecureCredentialRepository repository;
  const marker = 'connection.v3.protected.c2VydmVy';
  const journal = 'connection.v3.revisions.c2VydmVy';
  setUp(() async {
    storage = ProtectionTestStorage();
    crypto = ProtectionTestCrypto();
    repository = SecureCredentialRepository(storage: storage, crypto: crypto);
    await repository.saveCredentials(
      connectionId: 'server',
      password: 'first',
      privateKey: 'key',
    );
  });

  test(
    'a snapshot cannot overwrite a later ordinary save after disable',
    () async {
      await repository.enableProtection('server');
      final snapshot = await repository.captureProtectedSnapshot('server');
      await repository.disableProtection(
        'server',
        expectedRevision: snapshot.revision,
      );
      await repository.saveCredentials(
        connectionId: 'server',
        password: 'later',
      );
      await expectLater(
        repository.restoreProtectedSnapshot(snapshot),
        fails(CredentialProtectionError.stale),
      );
      await repository.discardProtectedSnapshot(snapshot);
      expect(await repository.getPassword('server'), 'later');
    },
  );

  test(
    'delete preserves an unreadable revision journal for a later retry',
    () async {
      await repository.enableProtection('server');
      final snapshot = await repository.captureProtectedSnapshot('server');
      await repository.saveProtectedCredentials(
        connectionId: 'server',
        password: 'second',
      );
      final restarted = SecureCredentialRepository(
        storage: storage,
        crypto: crypto,
      );
      storage.failReadKey = journal;
      await expectLater(
        restarted.deleteCredentials('server'),
        fails(CredentialProtectionError.storageFailure),
      );
      expect(crypto.values.keys, contains('server/${snapshot.revision}'));
      await restarted.deleteCredentials('server');
      expect(crypto.values, isEmpty);
      expect(storage.values, isEmpty);
    },
  );

  test(
    'a durable verified revision owner exists before native seal begins',
    () async {
      var hasDurableOwner = false;
      crypto.onSealRequest = (id, revision) {
        final raw = storage.values[journal];
        hasDurableOwner =
            raw != null && (jsonDecode(raw) as List).contains(revision);
      };
      await repository.enableProtection('server');
      expect(hasDurableOwner, isTrue);
    },
  );

  for (final afterWrite in [false, true]) {
    test(
      'a revision journal write failure before/after write ($afterWrite) never invokes seal',
      () async {
        storage.failWriteKey = journal;
        storage.failAfterWrite = afterWrite;
        await expectLater(
          repository.enableProtection('server'),
          fails(CredentialProtectionError.storageFailure),
        );
        expect(crypto.sealCalls, 0);
        expect(await repository.getPassword('server'), 'first');
        expect(await repository.getPrivateKey('server'), 'key');
        expect(await repository.isProtected('server'), isFalse);
      },
    );
  }

  test(
    'a missing revision journal write confirmation never invokes seal',
    () async {
      storage.ignoredWrites.add(journal);
      await expectLater(
        repository.enableProtection('server'),
        fails(CredentialProtectionError.storageFailure),
      );
      expect(crypto.sealCalls, 0);
      expect(await repository.getPassword('server'), 'first');
    },
  );

  for (final code in [
    CredentialProtectionError.cancelled,
    CredentialProtectionError.authenticationFailed,
  ]) {
    test(
      'native $code after key creation preserves prior values and removes the reserved revision',
      () async {
        crypto.failureAfterCreate = CredentialProtectionException(code);
        await expectLater(repository.enableProtection('server'), fails(code));
        expect(crypto.sealCalls, 1);
        expect(crypto.removed, hasLength(1));
        expect(crypto.values, isEmpty);
        expect(storage.values.containsKey(journal), isFalse);
        expect(await repository.getPassword('server'), 'first');
        expect(await repository.getPrivateKey('server'), 'key');
      },
    );
  }

  test(
    'native seal cleanup failure keeps its durable revision for a later delete',
    () async {
      crypto.failureAfterCreate = const CredentialProtectionException(
        CredentialProtectionError.cancelled,
      );
      crypto.failRemove = true;
      await expectLater(
        repository.enableProtection('server'),
        fails(CredentialProtectionError.cancelled),
      );
      expect(storage.values.containsKey(journal), isTrue);
      expect(await repository.getPassword('server'), 'first');
      crypto.failRemove = false;
      final restarted = SecureCredentialRepository(
        storage: storage,
        crypto: crypto,
      );
      await restarted.deleteCredentials('server');
      expect(crypto.values, isEmpty);
      expect(storage.values, isEmpty);
    },
  );

  for (final afterWrite in [false, true]) {
    test(
      'enable storage failure (committed=$afterWrite) preserves the original pair',
      () async {
        storage.failWriteKey = marker;
        storage.failAfterWrite = afterWrite;
        await expectLater(
          repository.enableProtection('server'),
          fails(CredentialProtectionError.storageFailure),
        );
        expect(await repository.isProtected('server'), isFalse);
        expect(await repository.getPassword('server'), 'first');
        expect(await repository.getPrivateKey('server'), 'key');
        expect(crypto.values, isEmpty);
      },
    );
  }

  test(
    'failure clearing old plaintext never downgrades a verified protected record',
    () async {
      storage.failDeletes.add('connection.v2.password.c2VydmVy');
      await expectLater(
        repository.enableProtection('server'),
        fails(CredentialProtectionError.storageFailure),
      );
      expect(await repository.isProtected('server'), isTrue);
      await expectLater(
        repository.getPassword('server'),
        fails(CredentialProtectionError.locked),
      );
      expect((await repository.unlockCredentials('server')).password, 'first');
    },
  );

  test('all callers serialize behind an authentication prompt', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    crypto.sealGate = gate.future;
    crypto.sealStarted = started;
    final enabling = repository.enableProtection('server');
    await started.future;
    final reading = repository.getPassword('server');
    final checked = expectLater(
      reading,
      fails(CredentialProtectionError.locked),
    );
    gate.complete();
    await enabling;
    await checked;
    expect(crypto.sealCalls, 1);
  });

  test(
    'stale transition after record write rolls back without losing original credentials',
    () async {
      var current = true;
      storage.afterWrite = (key, value) {
        if (key == marker) current = false;
      };
      await expectLater(
        repository.enableProtection('server', isCurrent: () => current),
        fails(CredentialProtectionError.stale),
      );
      expect(await repository.getPassword('server'), 'first');
    },
  );

  test(
    'a failed protected update can restore its opaque snapshot even after rollback write failure',
    () async {
      await repository.enableProtection('server');
      final snapshot = await repository.captureProtectedSnapshot('server');
      var once = true;
      storage.afterWrite = (key, value) {
        if (key == marker && once) {
          once = false;
          storage.failReadKey = marker;
          storage.failWriteKey = marker;
        }
      };
      await expectLater(
        repository.saveProtectedCredentials(
          connectionId: 'server',
          password: 'second',
          expectedRevision: snapshot.revision,
        ),
        fails(CredentialProtectionError.storageFailure),
      );
      storage.afterWrite = null;
      await repository.restoreProtectedSnapshot(snapshot);
      expect((await repository.unlockCredentials('server')).password, 'first');
    },
  );

  test(
    'unrelated later revisions cannot be overwritten by an old snapshot',
    () async {
      await repository.enableProtection('server');
      final snapshot = await repository.captureProtectedSnapshot('server');
      await repository.saveProtectedCredentials(
        connectionId: 'server',
        password: 'second',
      );
      await repository.saveProtectedCredentials(
        connectionId: 'server',
        password: 'third',
      );
      await expectLater(
        repository.restoreProtectedSnapshot(snapshot),
        fails(CredentialProtectionError.stale),
      );
      await repository.discardProtectedSnapshot(snapshot);
      expect((await repository.unlockCredentials('server')).password, 'third');
      expect(crypto.removed, contains(snapshot.revision));
    },
  );

  test(
    'a snapshot from another repository cannot restore credentials',
    () async {
      await repository.enableProtection('server');
      final snapshot = await repository.captureProtectedSnapshot('server');
      final other = SecureCredentialRepository(
        storage: storage,
        crypto: crypto,
      );
      expect(
        () => other.restoreProtectedSnapshot(snapshot),
        fails(CredentialProtectionError.stale),
      );
      await repository.discardProtectedSnapshot(snapshot);
      await repository.discardProtectedSnapshot(snapshot);
      await expectLater(
        repository.restoreProtectedSnapshot(snapshot),
        fails(CredentialProtectionError.stale),
      );
    },
  );

  test(
    'disabling with a stale request after authentication retains protection',
    () async {
      await repository.enableProtection('server');
      var current = true;
      crypto.onOpen = () {
        current = false;
      };
      await expectLater(
        repository.disableProtection('server', isCurrent: () => current),
        fails(CredentialProtectionError.stale),
      );
      expect(await repository.isProtected('server'), isTrue);
      await expectLater(
        repository.getPrivateKey('server'),
        fails(CredentialProtectionError.locked),
      );
    },
  );

  test(
    'failed disable storage writes leave the opaque record available',
    () async {
      await repository.enableProtection('server');
      storage.failWriteKey = 'connection.v2.private_key.c2VydmVy';
      await expectLater(
        repository.disableProtection('server'),
        fails(CredentialProtectionError.storageFailure),
      );
      expect(await repository.isProtected('server'), isTrue);
      expect((await repository.unlockCredentials('server')).privateKey, 'key');
      expect(
        storage.values.keys.where((key) => key.startsWith('connection.v2.')),
        isEmpty,
      );
    },
  );

  test(
    'delete clears corrupt protected markers and all stale credentials',
    () async {
      await repository.enableProtection('server');
      storage.values[marker] = 'corrupt';
      storage.values['connection.password.server'] = 'stale';
      await repository.deleteCredentials('server');
      expect(storage.values, isEmpty);
      expect(crypto.values, isEmpty);
    },
  );

  test('a partial deletion remains blocked and can be retried', () async {
    await repository.enableProtection('server');
    final first = await repository.captureProtectedSnapshot('server');
    await repository.saveProtectedCredentials(
      connectionId: 'server',
      password: 'second',
    );
    storage.values['connection.v2.password.c2VydmVy'] = 'stale';
    storage.failDeletes.add('connection.v2.password.c2VydmVy');
    await expectLater(
      repository.deleteCredentials('server'),
      fails(CredentialProtectionError.storageFailure),
    );
    await expectLater(
      repository.getPassword('server'),
      fails(CredentialProtectionError.corrupt),
    );
    expect(crypto.removed, contains(first.revision));
    storage.failDeletes.clear();
    await repository.deleteCredentials('server');
    expect(storage.values, isEmpty);
    expect(crypto.values, isEmpty);
  });

  test(
    'deletion retries every revision whose Keystore removal failed',
    () async {
      await repository.enableProtection('server');
      crypto.failRemove = true;
      await expectLater(
        repository.deleteCredentials('server'),
        fails(CredentialProtectionError.storageFailure),
      );
      expect(storage.values.containsKey(marker), isTrue);
      crypto.failRemove = false;
      await repository.deleteCredentials('server');
      expect(crypto.values, isEmpty);
      expect(storage.values, isEmpty);
    },
  );

  test('unsupported hosts never create a protected marker', () async {
    crypto.supportsProtection = false;
    await expectLater(
      repository.enableProtection('server'),
      fails(CredentialProtectionError.unsupported),
    );
    expect(await repository.getPassword('server'), 'first');
    final unsupported = SecureCredentialRepository(storage: storage);
    expect(unsupported.supportsProtection, isFalse);
  });

  test(
    'protection validates canonical ids and does not change old long-id storage',
    () async {
      for (final id in ['', ' server', 'x' * 257]) {
        expect(() => repository.isProtected(id), throwsArgumentError);
      }
      await repository.saveCredentials(
        connectionId: 'x' * 257,
        password: 'long-id',
      );
      expect(await repository.getPassword('x' * 257), 'long-id');
      expect(await repository.protectionRevision('server'), isNull);
      expect((await repository.unlockCredentials('server')).revision, isNull);
      await expectLater(
        repository.unlockCredentials('server', expectedRevision: 'stale'),
        fails(CredentialProtectionError.stale),
      );
      await expectLater(
        repository.disableProtection('server'),
        fails(CredentialProtectionError.stale),
      );
      await expectLater(
        repository.captureProtectedSnapshot('server'),
        fails(CredentialProtectionError.locked),
      );
      await expectLater(
        repository.saveProtectedCredentials(connectionId: 'server'),
        fails(CredentialProtectionError.locked),
      );
    },
  );

  test('journal corruption cannot trigger native key use', () async {
    storage.values[journal] = 'broken';
    await expectLater(
      repository.enableProtection('server'),
      fails(CredentialProtectionError.corrupt),
    );
    expect(await repository.isProtected('server'), isFalse);
    expect(await repository.getPassword('server'), 'first');
  });
}
