import 'dart:convert';
import 'dart:typed_data';

import 'package:connection_core/connection_core.dart';
import 'package:connection_core/src/repository/protected_credential_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final corrupt = throwsA(
    isA<CredentialProtectionException>().having(
      (error) => error.code,
      'code',
      CredentialProtectionError.corrupt,
    ),
  );
  CredentialCiphertext cipher({int iv = 12, int bytes = 16}) =>
      CredentialCiphertext(iv: Uint8List(iv), ciphertext: Uint8List(bytes));
  test(
    'ciphertext copies and freezes its buffers without exposing pair contents',
    () {
      final iv = Uint8List.fromList(List.filled(12, 4));
      final bytes = Uint8List.fromList(List.filled(16, 5));
      final encrypted = CredentialCiphertext(iv: iv, ciphertext: bytes);
      iv[0] = 0;
      bytes[0] = 0;
      expect(encrypted.iv.first, 4);
      expect(encrypted.ciphertext.first, 5);
      expect(() => encrypted.iv[0] = 8, throwsUnsupportedError);
      expect(() => encrypted.ciphertext[0] = 8, throwsUnsupportedError);
      const pair = CredentialPair(
        password: 'synthetic-private-value',
        privateKey: 'sample',
        revision: 'revision',
      );
      expect(pair.toString(), isNot(contains('synthetic-private-value')));
      expect(
        const CredentialProtectionException(
          CredentialProtectionError.corrupt,
        ).toString(),
        'CredentialProtectionException: corrupt',
      );
    },
  );

  test('envelope and pair round trip complete optional fields', () {
    final record = ProtectedCredentialRecord('id', 'a' * 64, cipher());
    final decoded = ProtectedCredentialRecord.decode('id', record.encode());
    expect(decoded.connectionId, 'id');
    expect(decoded.revision, 'a' * 64);
    expect(decoded.cipher.ciphertext, Uint8List(16));
    final bytes = ProtectedCredentialRecord.encodePair('sample', null);
    final pair = ProtectedCredentialRecord.decodePair(bytes, 'revision');
    expect(pair.password, 'sample');
    expect(pair.privateKey, isNull);
    expect(pair.revision, 'revision');
    final empty = ProtectedCredentialRecord.decodePair(
      ProtectedCredentialRecord.encodePair('', ''),
      'revision',
    );
    expect(empty.password, isNull);
    expect(empty.privateKey, isNull);
  });

  test('malformed and over-budget envelopes always fail closed', () {
    final good = ProtectedCredentialRecord('id', 'a' * 64, cipher()).encode();
    for (final raw in [
      'x' * (ProtectedCredentialRecord.maxBytes * 2 + 1),
      '{}',
      'null',
      '[]',
      'broken',
      jsonEncode({...jsonDecode(good) as Map<String, dynamic>, 'v': 2}),
      jsonEncode({...jsonDecode(good) as Map<String, dynamic>, 'id': 'other'}),
      jsonEncode({
        ...jsonDecode(good) as Map<String, dynamic>,
        'iv': 'not-base64',
      }),
    ]) {
      expect(() => ProtectedCredentialRecord.decode('id', raw), corrupt);
    }
    for (final value in [
      ProtectedCredentialRecord('id', 'bad', cipher()),
      ProtectedCredentialRecord('id', 'a' * 64, cipher(iv: 11)),
      ProtectedCredentialRecord('id', 'a' * 64, cipher(bytes: 15)),
      ProtectedCredentialRecord(
        'id',
        'a' * 64,
        cipher(bytes: ProtectedCredentialRecord.maxBytes + 17),
      ),
    ]) {
      expect(value.encode, corrupt);
    }
  });

  test(
    'plain pair parser rejects missing fields, wrong types and oversized values',
    () {
      for (final raw in [
        'null',
        '{}',
        '[]',
        'broken',
        '{"v":1,"password":7,"privateKey":null}',
        '{"v":1,"password":null,"privateKey":7}',
        '{"v":2,"password":null,"privateKey":null}',
      ]) {
        expect(
          () => ProtectedCredentialRecord.decodePair(
            Uint8List.fromList(utf8.encode(raw)),
            'r',
          ),
          corrupt,
        );
      }
      expect(
        () => ProtectedCredentialRecord.decodePair(
          Uint8List(ProtectedCredentialRecord.maxBytes + 1),
          'r',
        ),
        corrupt,
      );
      expect(
        () => ProtectedCredentialRecord.encodePair(
          'x' * ProtectedCredentialRecord.maxBytes,
          null,
        ),
        corrupt,
      );
    },
  );
}
