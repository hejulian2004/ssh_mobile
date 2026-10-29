import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_mobile/services/remote_target_scope.dart';

void main() {
  late _Connections connections;
  late _Credentials credentials;
  setUp(() {
    connections = _Connections();
    credentials = _Credentials();
  });

  test(
    'noninteractive access to protected credentials never prompts or reads old keys',
    () async {
      await expectLater(
        RemoteTargetScope.resolveIfBound(
          connectionRepository: connections,
          credentialRepository: credentials,
          connectionId: 'fixture',
        ),
        throwsA(
          isA<CredentialProtectionException>().having(
            (e) => e.code,
            'code',
            CredentialProtectionError.locked,
          ),
        ),
      );
      expect(credentials.unlocks, 0);
      expect(credentials.oldReads, 0);
    },
  );

  test(
    'explicit connection unlocks one complete pair and binds its revision',
    () async {
      final target = await RemoteTargetScope.resolveIfBound(
        connectionRepository: connections,
        credentialRepository: credentials,
        connectionId: 'fixture',
        allowCredentialUnlock: true,
      );
      expect(target.password, 'public-fixture-password');
      expect(target.privateKey, 'public-fixture-key');
      expect(credentials.unlocks, 1);
      expect(credentials.oldReads, 0);
      await target.validateCurrent();
      credentials.revision = 'replaced';
      await expectLater(
        target.validateCurrent(),
        throwsA(isA<RemoteTargetScopeException>()),
      );
    },
  );

  test(
    'retargeting during authentication rejects the late plaintext',
    () async {
      final waiting = Completer<CredentialPair>();
      credentials.pending = waiting.future;
      final resolving = RemoteTargetScope.resolveBinding(
        ConnectionTargetBinding.fromConfig(connections.value),
        connectionRepository: connections,
        credentialRepository: credentials,
        allowCredentialUnlock: true,
      );
      await Future<void>.delayed(Duration.zero);
      connections.value = connections.value.copyWith(
        host: 'other.example.invalid',
      );
      waiting.complete(
        const CredentialPair(password: 'public-fixture', revision: 'revision'),
      );
      expect(await resolving, isNull);
    },
  );

  test(
    'unprotected reads also recheck the target after awaited storage',
    () async {
      credentials.protected = false;
      credentials.afterPassword = () => connections.value = connections.value
          .copyWith(host: 'other.example.invalid');
      expect(
        await RemoteTargetScope.resolveBinding(
          ConnectionTargetBinding.fromConfig(connections.value),
          connectionRepository: connections,
          credentialRepository: credentials,
        ),
        isNull,
      );
    },
  );
  test(
    'target changes during revision lookup are rejected before authentication',
    () async {
      final target = await RemoteTargetScope.resolveIfBound(
        connectionRepository: connections,
        credentialRepository: credentials,
        connectionId: 'fixture',
        allowCredentialUnlock: true,
      );
      credentials.duringRevisionRead = () {
        connections.value = connections.value.copyWith(
          host: 'other.example.invalid',
        );
      };
      await expectLater(
        target.validateCurrent(),
        throwsA(isA<RemoteTargetScopeException>()),
      );
    },
  );
  test(
    'first explicitly trusted Host Key enriches only the selected target',
    () async {
      final target = await RemoteTargetScope.resolveIfBound(
        connectionRepository: connections,
        credentialRepository: credentials,
        connectionId: 'fixture',
        allowCredentialUnlock: true,
      );
      final trusted = connections.value.copyWith(
        hostKeyFingerprint: 'md5:00112233445566778899aabbccddeeff',
        hostKeyAlgorithm: 'ssh-ed25519',
        hostKeyTrustedAt: DateTime.utc(2026),
      );
      connections.value = trusted;
      await target.validateCurrent(trusted);
      connections.value = trusted.copyWith(host: 'other.example.invalid');
      await expectLater(
        target.validateCurrent(connections.value),
        throwsA(isA<RemoteTargetScopeException>()),
      );
    },
  );

  test('authenticated metadata cannot replace an already pinned key', () async {
    connections.value = connections.value.copyWith(
      hostKeyFingerprint: 'md5:00112233445566778899aabbccddeeff',
      hostKeyAlgorithm: 'ssh-ed25519',
    );
    final target = await RemoteTargetScope.resolveIfBound(
      connectionRepository: connections,
      credentialRepository: credentials,
      connectionId: 'fixture',
      allowCredentialUnlock: true,
    );
    connections.value = connections.value.copyWith(
      hostKeyFingerprint: 'md5:ffeeddccbbaa99887766554433221100',
    );
    await expectLater(
      target.validateCurrent(connections.value),
      throwsA(isA<RemoteTargetScopeException>()),
    );
  });
}

final class _Connections extends Fake implements ConnectionRepository {
  ConnectionConfig value = ConnectionConfig(
    id: 'fixture',
    name: 'Public fixture',
    host: 'fixture.example.invalid',
    port: 22,
    username: 'fixture',
    authMethod: AuthMethod.password,
  );
  @override
  ConnectionConfig? getConnection(String id) => id == value.id ? value : null;
}

final class _Credentials extends Fake
    implements CredentialRepository, CredentialProtectionRepository {
  bool protected = true;
  String? revision = 'revision';
  int unlocks = 0;
  int oldReads = 0;
  Future<CredentialPair>? pending;
  void Function()? afterPassword;
  void Function()? duringRevisionRead;
  @override
  bool get supportsProtection => true;
  @override
  Future<bool> isProtected(String connectionId) async => protected;
  @override
  Future<String?> protectionRevision(String connectionId) async {
    duringRevisionRead?.call();
    return protected ? revision : null;
  }

  @override
  Future<CredentialPair> unlockCredentials(
    String connectionId, {
    String? expectedRevision,
  }) async {
    unlocks++;
    return await pending ??
        CredentialPair(
          password: 'public-fixture-password',
          privateKey: 'public-fixture-key',
          revision: revision,
        );
  }

  @override
  Future<String?> getPassword(String connectionId) async {
    oldReads++;
    afterPassword?.call();
    return null;
  }

  @override
  Future<String?> getPrivateKey(String connectionId) async {
    oldReads++;
    return null;
  }
}
