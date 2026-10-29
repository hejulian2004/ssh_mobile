import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/protected_credentials_fakes.dart';

void main() {
  late ProtectedCredentialFake credentials;
  late ConnectionRepositoryFake repository;
  late ConnectionCredentialEditor editor;
  setUp(() {
    credentials = ProtectedCredentialFake();
    repository = ConnectionRepositoryFake();
    editor = ConnectionCredentialEditor(
      connectionId: 'server-1',
      connectionRepository: repository,
      credentialRepository: credentials,
    );
  });
  tearDown(() => editor.dispose());

  test(
    'submission access requires initialization and an unlocked protected pair',
    () async {
      expect(editor.isAccessCurrent, isFalse);
      expect(editor.canSubmit, isFalse);
      expect(
        editor.captureSubmissionAccess,
        throwsA(isA<CredentialProtectionException>()),
      );
      await editor.initialize();
      expect(editor.isAccessCurrent, isTrue);
      expect(editor.canSubmit, isFalse);
      expect(
        editor.captureSubmissionAccess,
        throwsA(isA<CredentialProtectionException>()),
      );
      await editor.unlock();
      final lease = editor.captureSubmissionAccess();
      expect(editor.canSubmit, isTrue);
      expect(lease(), isTrue);
      // VM 拥有合法提交时的结构检查；编辑租约仅检查相同明文/生命周期。
      repository.current = repository.current!.copyWith(
        host: 'staged.example.test',
      );
      expect(lease(), isTrue);
      editor.lock();
      expect(lease(), isFalse);
      expect(editor.canSubmit, isFalse);
    },
  );

  test('busy authentication cannot create a submission lease', () async {
    await editor.initialize();
    final pending = Completer<CredentialPair>();
    credentials.unlockResult = pending.future;
    final unlocking = editor.unlock();
    expect(editor.canSubmit, isFalse);
    expect(
      editor.captureSubmissionAccess,
      throwsA(isA<CredentialProtectionException>()),
    );
    pending.complete(
      const CredentialPair(password: 'fixture', revision: 'revision-1'),
    );
    await unlocking;
    final lease = editor.captureSubmissionAccess();
    editor.dispose();
    expect(lease(), isFalse);
    expect(editor.isAccessCurrent, isFalse);
  });

  test(
    'protected editor loads state without reading either old getter',
    () async {
      await editor.initialize();
      expect(editor.isProtected, isTrue);
      expect(editor.credentials, isNull);
      expect(credentials.plainReads, 0);
      expect(editor.revision, 'revision-1');
    },
  );

  test(
    'explicit unlock loads both secrets in one authenticated operation',
    () async {
      await editor.initialize();
      await editor.unlock();
      expect(editor.credentials!.password, 'fixture-password');
      expect(editor.credentials!.privateKey, 'fixture-key');
      expect(credentials.unlockCalls, 1);
      expect(credentials.plainReads, 0);
    },
  );

  for (final code in CredentialProtectionError.values) {
    test('unlock reports stable $code and retains no secrets', () async {
      await editor.initialize();
      credentials.error = code;
      await editor.unlock();
      expect(editor.error, code);
      expect(editor.credentials, isNull);
      expect(editor.isBusy, isFalse);
    });
  }

  test('dispose discards a late authenticated result', () async {
    await editor.initialize();
    final pending = Completer<CredentialPair>();
    credentials.unlockResult = pending.future;
    final unlocking = editor.unlock();
    editor.dispose();
    pending.complete(
      const CredentialPair(password: 'late-secret', revision: 'revision-1'),
    );
    await unlocking;
    expect(editor.credentials, isNull);
  });

  test(
    'locking while authentication is pending discards a late result',
    () async {
      await editor.initialize();
      final pending = Completer<CredentialPair>();
      credentials.unlockResult = pending.future;
      final unlocking = editor.unlock();
      editor.lock();
      pending.complete(
        const CredentialPair(password: 'late-secret', revision: 'revision-1'),
      );
      await unlocking;
      expect(editor.credentials, isNull);
      expect(editor.isBusy, isFalse);
    },
  );

  test(
    'target change while authentication is pending cannot publish a pair',
    () async {
      await editor.initialize();
      final pending = Completer<CredentialPair>();
      credentials.unlockResult = pending.future;
      final unlocking = editor.unlock();
      repository.current = repository.current!.copyWith(
        host: 'changed.example.test',
      );
      pending.complete(
        const CredentialPair(password: 'late-secret', revision: 'revision-1'),
      );
      await unlocking;
      expect(editor.credentials, isNull);
      expect(editor.error, CredentialProtectionError.stale);
    },
  );

  test(
    'revision change while authentication is pending cannot publish a pair',
    () async {
      await editor.initialize();
      final pending = Completer<CredentialPair>();
      credentials.unlockResult = pending.future;
      final unlocking = editor.unlock();
      credentials.revision = 'revision-2';
      pending.complete(
        const CredentialPair(password: 'late-secret', revision: 'revision-1'),
      );
      await unlocking;
      expect(editor.credentials, isNull);
      expect(editor.error, CredentialProtectionError.stale);
    },
  );

  test('a changed target stays stale across retries and initialize', () async {
    await editor.initialize();
    repository.current = repository.current!.copyWith(
      host: 'replacement.example.test',
    );
    credentials.revision = 'replacement-revision';
    await editor.unlock();
    await editor.unlock();
    await editor.initialize();
    expect(editor.error, CredentialProtectionError.stale);
    expect(editor.credentials, isNull);
    expect(credentials.unlockCalls, 0);
    expect(editor.revision, 'revision-1');
  });

  test('an observed target change cannot be cleared by restoring it', () async {
    await editor.initialize();
    final original = repository.current!;
    final pending = Completer<CredentialPair>();
    credentials.unlockResult = pending.future;
    final unlocking = editor.unlock();
    repository.current = original.copyWith(host: 'replacement.example.test');
    pending.complete(
      const CredentialPair(privateKey: 'late-key', revision: 'revision-1'),
    );
    await unlocking;
    repository.current = original;
    credentials.unlockResult = null;
    await editor.unlock();
    expect(editor.error, CredentialProtectionError.stale);
    expect(editor.credentials, isNull);
    expect(credentials.unlockCalls, 1);
  });

  test(
    'a stale target cannot enable protection or reload plain fields',
    () async {
      credentials.protected = false;
      await editor.initialize();
      repository.current = repository.current!.copyWith(
        username: 'replacement',
      );
      await editor.setProtection(true);
      await editor.initialize();
      expect(editor.error, CredentialProtectionError.stale);
      expect(editor.credentials, isNull);
      expect(credentials.enables, 0);
      expect(credentials.plainReads, 2);
    },
  );

  test(
    'enable and disable use protected repository crypto capabilities',
    () async {
      credentials.protected = false;
      await editor.initialize();
      expect(editor.credentials!.password, 'fixture-password');
      await editor.setProtection(true);
      expect(credentials.enables, 1);
      expect(editor.isProtected, isTrue);
      expect(editor.credentials, isNull);
      await editor.setProtection(false);
      expect(credentials.disables, 1);
      expect(editor.isProtected, isFalse);
      expect(editor.credentials!.privateKey, 'fixture-key');
    },
  );

  test('unsupported capability cannot enable protection', () async {
    credentials.supportsProtection = false;
    credentials.protected = false;
    await editor.initialize();
    await editor.setProtection(true);
    expect(editor.supportsProtection, isFalse);
    expect(editor.error, CredentialProtectionError.unsupported);
    expect(credentials.enables, 0);
  });

  test(
    'a failed enable cleanup still reflects an already protected record',
    () async {
      credentials.protected = false;
      await editor.initialize();
      credentials.afterEnableError = const CredentialProtectionException(
        CredentialProtectionError.storageFailure,
      );
      await editor.setProtection(true);
      expect(editor.isProtected, isTrue);
      expect(editor.credentials, isNull);
      expect(editor.error, CredentialProtectionError.storageFailure);
    },
  );

  test(
    'protection state failure stays blocked and never falls back to getters',
    () async {
      credentials.stateError = CredentialProtectionError.corrupt;
      await editor.initialize();
      expect(editor.isProtected, isTrue);
      expect(editor.error, CredentialProtectionError.corrupt);
      expect(credentials.plainReads, 0);
    },
  );

  test(
    'a disposed or changed operation cannot commit late protection mutation',
    () async {
      credentials.protected = false;
      await editor.initialize();
      final pause = Completer<void>();
      credentials.beforeMutation = () => pause.future;
      final enabling = editor.setProtection(true);
      editor.lock();
      pause.complete();
      await enabling;
      expect(credentials.protected, isFalse);
      expect(editor.credentials, isNull);
    },
  );
}
