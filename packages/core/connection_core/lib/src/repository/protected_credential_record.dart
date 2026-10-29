import 'dart:convert';
import 'dart:typed_data';

import 'credential_protection.dart';

/// 保护记录只携带密文与非秘密绑定，严格解析且永不退回旧凭据键。
final class ProtectedCredentialRecord {
  ProtectedCredentialRecord(this.connectionId, this.revision, this.cipher);
  static const maxBytes = 512 * 1024;
  static final revisionPattern = RegExp(r'^[0-9a-f]{64}$');
  final String connectionId;
  final String revision;
  final CredentialCiphertext cipher;

  String encode() {
    if (!revisionPattern.hasMatch(revision) ||
        cipher.iv.length != 12 ||
        cipher.ciphertext.length < 16 ||
        cipher.ciphertext.length > maxBytes + 16) {
      throw const CredentialProtectionException(
        CredentialProtectionError.corrupt,
      );
    }
    return jsonEncode({
      'v': 1,
      'id': connectionId,
      'revision': revision,
      'iv': base64Encode(cipher.iv),
      'ciphertext': base64Encode(cipher.ciphertext),
    });
  }

  static ProtectedCredentialRecord decode(String id, String raw) {
    try {
      if (raw.length > maxBytes * 2) throw const FormatException();
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['v'] != 1 ||
          value['id'] != id ||
          value['revision'] is! String ||
          value['iv'] is! String ||
          value['ciphertext'] is! String) {
        throw const FormatException();
      }
      final record = ProtectedCredentialRecord(
        id,
        value['revision'] as String,
        CredentialCiphertext(
          iv: base64Decode(value['iv'] as String),
          ciphertext: base64Decode(value['ciphertext'] as String),
        ),
      );
      record.encode();
      return record;
    } catch (_) {
      throw const CredentialProtectionException(
        CredentialProtectionError.corrupt,
      );
    }
  }

  static Uint8List encodePair(String? password, String? privateKey) {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'password': password == '' ? null : password,
          'privateKey': privateKey == '' ? null : privateKey,
        }),
      ),
    );
    if (bytes.length > maxBytes) {
      bytes.fillRange(0, bytes.length, 0);
      throw const CredentialProtectionException(
        CredentialProtectionError.corrupt,
      );
    }
    return bytes;
  }

  static CredentialPair decodePair(Uint8List bytes, String revision) {
    try {
      if (bytes.length > maxBytes) throw const FormatException();
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map ||
          value['v'] != 1 ||
          !value.containsKey('password') ||
          !value.containsKey('privateKey') ||
          (value['password'] != null && value['password'] is! String) ||
          (value['privateKey'] != null && value['privateKey'] is! String)) {
        throw const FormatException();
      }
      return CredentialPair(
        password: value['password'] as String?,
        privateKey: value['privateKey'] as String?,
        revision: revision,
      );
    } catch (_) {
      throw const CredentialProtectionException(
        CredentialProtectionError.corrupt,
      );
    }
  }
}
