import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:connection_core/connection_core.dart';

final class ProtectionTestStorage implements SecureStorageClient {
  final values = <String, String>{};
  final reads = <String>[];
  String? failWriteKey;
  String? failReadKey;
  final failDeletes = <String>{};
  final ignoredWrites = <String>{};
  bool failAfterWrite = false;
  void Function(String key, String value)? afterWrite;
  @override
  Future<String?> read({required String key}) async {
    reads.add(key);
    if (failReadKey == key) {
      failReadKey = null;
      throw StateError('storage-read');
    }
    return values[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    if (ignoredWrites.contains(key)) return;
    final fail = key == failWriteKey;
    if (fail && !failAfterWrite) {
      failWriteKey = null;
      throw StateError('storage-write');
    }
    values[key] = value;
    afterWrite?.call(key, value);
    if (fail) {
      failWriteKey = null;
      throw StateError('storage-write');
    }
  }

  @override
  Future<void> delete({required String key}) async {
    if (failDeletes.contains(key)) throw StateError('storage-delete');
    values.remove(key);
  }
}

final class ProtectionTestCrypto implements CredentialCryptoPort {
  @override
  bool supportsProtection = true;
  int sealCalls = 0;
  int openCalls = 0;
  final values = <String, Uint8List>{};
  final removed = <String>[];
  CredentialProtectionException? failure;
  CredentialProtectionException? failureAfterCreate;
  void Function(String connectionId, String revision)? onSealRequest;
  void Function()? onSeal;
  void Function()? onOpen;
  Future<void>? sealGate;
  Completer<void>? sealStarted;
  bool failRemove = false;
  @override
  Future<CredentialCiphertext> seal({
    required String connectionId,
    required String revision,
    required Uint8List plaintext,
  }) async {
    sealCalls++;
    onSealRequest?.call(connectionId, revision);
    sealStarted?.complete();
    if (sealGate != null) await sealGate;
    if (failure != null) throw failure!;
    values['$connectionId/$revision'] = Uint8List.fromList(plaintext);
    if (failureAfterCreate != null) throw failureAfterCreate!;
    onSeal?.call();
    return CredentialCiphertext(
      iv: Uint8List(12),
      ciphertext: Uint8List.fromList(utf8.encode(revision)),
    );
  }

  @override
  Future<Uint8List> open({
    required String connectionId,
    required String revision,
    required CredentialCiphertext ciphertext,
  }) async {
    openCalls++;
    onOpen?.call();
    if (failure != null) throw failure!;
    final value = values['$connectionId/$revision'];
    if (value == null || utf8.decode(ciphertext.ciphertext) != revision) {
      throw const CredentialProtectionException(
        CredentialProtectionError.keyInvalidated,
      );
    }
    return Uint8List.fromList(value);
  }

  @override
  Future<void> removeKey({
    required String connectionId,
    required String revision,
  }) async {
    if (failRemove) throw StateError('key-remove');
    values.remove('$connectionId/$revision');
    removed.add(revision);
  }
}
