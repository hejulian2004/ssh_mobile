import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:flutter_test/flutter_test.dart';

final class ConnectionRepositoryFake extends Fake
    implements ConnectionRepository, HostKeyRepository {
  ConnectionConfig? current = ConnectionConfig(
    id: 'server-1',
    name: 'Fixture',
    host: 'fixture.example.test',
    username: 'fixture',
    authMethod: AuthMethod.both,
  );
  Object? updateError;
  Object? trustError;
  @override
  List<ConnectionConfig> get connections => [?current];
  @override
  ConnectionConfig? getConnection(String id) =>
      current?.id == id ? current : null;
  @override
  Future<void> initialize() async {}
  @override
  Future<List<ConnectionConfig>> loadConnections() async => connections;
  @override
  Future<void> addConnection(ConnectionConfig config) async {
    current = config;
  }

  @override
  Future<void> updateConnection(ConnectionConfig config) async {
    current = config;
    final error = updateError;
    updateError = null;
    if (error != null) throw error;
  }

  @override
  Future<void> deleteConnection(String id) async {
    if (current?.id == id) current = null;
  }

  @override
  Future<void> deleteConnections(List<String> ids) async {
    if (ids.contains(current?.id)) current = null;
  }

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {}
  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {
    final error = trustError;
    trustError = null;
    if (error != null) throw error;
    current?.hostKeyAlgorithm = algorithm;
    current?.hostKeyFingerprint = fingerprint;
    current?.hostKeyTrustedAt = trustedAt;
  }
}

final class ProtectedCredentialFake extends Fake
    implements CredentialRepository, CredentialProtectionRepository {
  @override
  bool supportsProtection = true;
  bool protected = true;
  String revision = 'revision-1';
  String ciphertext = 'opaque-before';
  CredentialProtectionError? error;
  CredentialProtectionError? stateError;
  Future<CredentialPair>? unlockResult;
  Future<void> Function()? beforeMutation;
  void Function()? beforeState;
  int plainReads = 0;
  int plainWrites = 0;
  int unlockCalls = 0;
  int enables = 0;
  int disables = 0;
  int protectedWrites = 0;
  int captures = 0;
  int restores = 0;
  int discards = 0;
  int deletes = 0;
  Object? saveError;
  Object? afterEnableError;
  @override
  Future<bool> isProtected(String id) async {
    beforeState?.call();
    if (stateError != null) throw CredentialProtectionException(stateError!);
    return protected;
  }

  @override
  Future<String?> protectionRevision(String id) async =>
      protected ? revision : null;
  @override
  Future<String?> getPassword(String id) async {
    plainReads++;
    if (protected) {
      throw const CredentialProtectionException(
        CredentialProtectionError.locked,
      );
    }
    return 'fixture-password';
  }

  @override
  Future<String?> getPrivateKey(String id) async {
    plainReads++;
    if (protected) {
      throw const CredentialProtectionException(
        CredentialProtectionError.locked,
      );
    }
    return 'fixture-key';
  }

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {
    plainWrites++;
    if (protected) {
      throw const CredentialProtectionException(
        CredentialProtectionError.locked,
      );
    }
  }

  @override
  Future<void> deleteCredentials(String id) async {
    deletes++;
    protected = false;
  }

  @override
  Future<CredentialPair> unlockCredentials(
    String id, {
    String? expectedRevision,
  }) async {
    unlockCalls++;
    if (error != null) throw CredentialProtectionException(error!);
    if (expectedRevision != null && expectedRevision != revision) {
      throw const CredentialProtectionException(
        CredentialProtectionError.stale,
      );
    }
    return unlockResult ??
        Future.value(
          CredentialPair(
            password: 'fixture-password',
            privateKey: 'fixture-key',
            revision: revision,
          ),
        );
  }

  Future<void> _before(
    bool Function()? isCurrent,
    String? expectedRevision,
  ) async {
    await beforeMutation?.call();
    if (error != null) throw CredentialProtectionException(error!);
    if (!(isCurrent?.call() ?? true) ||
        (expectedRevision != null && expectedRevision != revision)) {
      throw const CredentialProtectionException(
        CredentialProtectionError.stale,
      );
    }
  }

  @override
  Future<void> enableProtection(String id, {bool Function()? isCurrent}) async {
    enables++;
    await _before(isCurrent, null);
    protected = true;
    if (afterEnableError != null) throw afterEnableError!;
  }

  @override
  Future<void> disableProtection(
    String id, {
    String? expectedRevision,
    bool Function()? isCurrent,
  }) async {
    disables++;
    await _before(isCurrent, expectedRevision);
    protected = false;
  }

  @override
  Future<void> saveProtectedCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
    String? expectedRevision,
    bool Function()? isCurrent,
  }) async {
    protectedWrites++;
    await _before(isCurrent, expectedRevision);
    ciphertext = 'opaque-after';
    revision = 'revision-2';
    if (saveError != null) throw saveError!;
  }

  @override
  Future<CredentialProtectionSnapshot> captureProtectedSnapshot(
    String id,
  ) async {
    captures++;
    return _Snapshot(id, revision, ciphertext);
  }

  @override
  Future<void> restoreProtectedSnapshot(
    CredentialProtectionSnapshot snapshot,
  ) async {
    restores++;
    revision = snapshot.revision;
    ciphertext = (snapshot as _Snapshot).ciphertext;
  }

  @override
  Future<void> discardProtectedSnapshot(
    CredentialProtectionSnapshot snapshot,
  ) async {
    discards++;
  }
}

final class _Snapshot implements CredentialProtectionSnapshot {
  _Snapshot(this.connectionId, this.revision, this.ciphertext);
  @override
  final String connectionId;
  @override
  final String revision;
  final String ciphertext;
}

final class ConnectionRuntimeFake extends Fake
    implements ConnectionRuntimePort {
  @override
  Future<int> activeWindowCount(String connectionId) async => 0;
  @override
  Future<void> cleanupConnectionResources(String connectionId) async {}
}

final class ConnectionVerificationFake extends Fake
    implements ConnectionVerificationPort {
  Future<void> Function()? beforeVerify;
  int calls = 0;
  @override
  Future<ConnectionVerificationResult> verify(
    ConnectionConfig config, {
    required String? password,
    required String? privateKey,
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async {
    calls++;
    await beforeVerify?.call();
    return const ConnectionVerificationResult();
  }
}
