import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/protected_credentials_fakes.dart';

void main() {
  late ConnectionRepositoryFake repository;
  late ProtectedCredentialFake credentials;
  late ConnectionViewModel viewModel;
  late ConnectionVerificationFake verification;
  setUp(() {
    repository = ConnectionRepositoryFake();
    credentials = ProtectedCredentialFake();
    verification = ConnectionVerificationFake();
    viewModel = ConnectionViewModel(
      connectionRepository: repository,
      credentialRepository: credentials,
      hostKeyRepository: repository,
      runtimePort: ConnectionRuntimeFake(),
      verificationPort: verification,
    );
  });
  tearDown(() => viewModel.dispose());
  Future<bool> save() => viewModel.verifyAndSaveConnection(
    config: repository.current!.copyWith(name: 'Edited'),
    isEditing: true,
    rawPassword: 'new-fixture-password',
    rawPrivateKey: 'new-fixture-key',
    confirmDisconnectCallback: (_) async => true,
  );

  test(
    'protected save snapshots ciphertext and never loads a plaintext rollback copy',
    () async {
      expect(await save(), isTrue);
      expect(credentials.plainReads, 0);
      expect(credentials.plainWrites, 0);
      expect(credentials.protectedWrites, 1);
      expect(credentials.captures, 1);
      expect(credentials.discards, 1);
      expect(repository.current!.name, 'Edited');
      expect(credentials.ciphertext, 'opaque-after');
    },
  );

  test(
    'protected write failure restores opaque ciphertext and old structure',
    () async {
      credentials.saveError = const CredentialProtectionException(
        CredentialProtectionError.storageFailure,
      );
      await expectLater(save(), throwsA(isA<CredentialProtectionException>()));
      expect(repository.current!.name, 'Fixture');
      expect(credentials.ciphertext, 'opaque-before');
      expect(credentials.restores, 1);
      expect(credentials.plainReads, 0);
      expect(credentials.plainWrites, 0);
      expect(credentials.discards, 1);
    },
  );

  test(
    'structure failure releases snapshot without attempting plaintext rollback',
    () async {
      repository.updateError = StateError('failed write');
      await expectLater(save(), throwsStateError);
      expect(credentials.protectedWrites, 0);
      expect(credentials.discards, 1);
      expect(credentials.plainReads, 0);
    },
  );

  test(
    'cancelled crypto save keeps opaque original and original structure',
    () async {
      credentials.error = CredentialProtectionError.cancelled;
      await expectLater(save(), throwsA(isA<CredentialProtectionException>()));
      expect(repository.current!.name, 'Fixture');
      expect(credentials.ciphertext, 'opaque-before');
      expect(credentials.plainWrites, 0);
    },
  );

  test(
    'an editor revision mismatch rejects before network verification',
    () async {
      await expectLater(
        viewModel.verifyAndSaveConnection(
          config: repository.current!.copyWith(name: 'Edited'),
          isEditing: true,
          rawPassword: 'new-password',
          rawPrivateKey: null,
          expectedCredentialRevision: 'obsolete-revision',
          confirmDisconnectCallback: (_) async => true,
        ),
        throwsA(
          isA<CredentialProtectionException>().having(
            (error) => error.code,
            'code',
            CredentialProtectionError.stale,
          ),
        ),
      );
      expect(verification.calls, 0);
      expect(credentials.protectedWrites, 0);
    },
  );

  test('revoked editor access rejects before network verification', () async {
    await expectLater(
      viewModel.verifyAndSaveConnection(
        config: repository.current!.copyWith(name: 'Edited'),
        isEditing: true,
        rawPassword: 'fixture-password',
        rawPrivateKey: 'fixture-key',
        expectedCredentialRevision: credentials.revision,
        isCredentialAccessCurrent: () => false,
        confirmDisconnectCallback: (_) async => true,
      ),
      throwsA(isA<CredentialProtectionException>()),
    );
    expect(verification.calls, 0);
    expect(credentials.captures, 0);
    expect(credentials.protectedWrites, 0);
    expect(repository.current!.name, 'Fixture');
  });

  for (final protected in [false, true]) {
    test(
      'target change during the initial credential check blocks $protected verification',
      () async {
        credentials.protected = protected;
        credentials.beforeState = () {
          repository.current = repository.current!.copyWith(
            host: 'rebound.example.test',
          );
        };
        await expectLater(
          save(),
          throwsA(isA<CredentialProtectionException>()),
        );
        expect(verification.calls, 0);
        expect(credentials.plainWrites, 0);
        expect(credentials.protectedWrites, 0);
        expect(repository.current!.host, 'rebound.example.test');
      },
    );
  }

  test(
    'an editor cannot silently save after protection was removed elsewhere',
    () async {
      credentials.protected = false;
      await expectLater(
        viewModel.verifyAndSaveConnection(
          config: repository.current!.copyWith(name: 'Stale edit'),
          isEditing: true,
          rawPassword: 'new-password',
          rawPrivateKey: null,
          expectedCredentialRevision: 'revision-1',
          confirmDisconnectCallback: (_) async => true,
        ),
        throwsA(
          isA<CredentialProtectionException>().having(
            (error) => error.code,
            'code',
            CredentialProtectionError.stale,
          ),
        ),
      );
      expect(verification.calls, 0);
      expect(credentials.plainWrites, 0);
    },
  );

  test(
    'a revision changed during verification cannot be overwritten',
    () async {
      verification.beforeVerify = () async {
        credentials.revision = 'concurrent-revision';
      };
      await expectLater(
        save(),
        throwsA(
          isA<CredentialProtectionException>().having(
            (error) => error.code,
            'code',
            CredentialProtectionError.stale,
          ),
        ),
      );
      expect(credentials.revision, 'concurrent-revision');
      expect(credentials.protectedWrites, 0);
      expect(credentials.discards, 1);
    },
  );

  test('a target changed during verification cannot be overwritten', () async {
    verification.beforeVerify = () async {
      repository.current = repository.current!.copyWith(
        host: 'other.example.test',
      );
    };
    await expectLater(
      save(),
      throwsA(
        isA<CredentialProtectionException>().having(
          (error) => error.code,
          'code',
          CredentialProtectionError.stale,
        ),
      ),
    );
    expect(repository.current!.host, 'other.example.test');
    expect(credentials.protectedWrites, 0);
  });

  test(
    'closing the route during crypto save prevents publication and restores structure',
    () async {
      final started = Completer<void>();
      final proceed = Completer<void>();
      var current = true;
      credentials.beforeMutation = () {
        started.complete();
        return proceed.future;
      };
      final saving = viewModel.verifyAndSaveConnection(
        config: repository.current!.copyWith(name: 'Edited'),
        isEditing: true,
        rawPassword: 'new-password',
        rawPrivateKey: null,
        isCredentialAccessCurrent: () => current,
        confirmDisconnectCallback: (_) async => true,
      );
      final rejected = expectLater(
        saving,
        throwsA(isA<CredentialProtectionException>()),
      );
      await started.future;
      current = false;
      proceed.complete();
      await rejected;
      expect(repository.current!.name, 'Fixture');
      expect(credentials.ciphertext, 'opaque-before');
      expect(credentials.plainWrites, 0);
    },
  );
}
