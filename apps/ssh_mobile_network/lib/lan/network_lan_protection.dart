// AES-256-GCM protection for LAN history fields in this app.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

import 'network_lan_keys.dart';
import 'network_secret_store.dart';

/// Encrypts LAN history fields with a key stored by this app.
final class NetworkLanProtection implements LanShareDataProtectionPort {
  /// Creates protection that stores its AES key in [secrets].
  NetworkLanProtection(this._secrets);

  /// Prefix that marks ciphertext produced by this app.
  static const prefix = 'network-app-v1:';

  final NetworkSecretStore _secrets;
  final AesGcm _algorithm = AesGcm.with256bits();
  SecretKey? _cachedKey;

  @override
  bool isEncrypted(String value) => value.startsWith(prefix);

  @override
  Future<String> encryptString(String value) async {
    if (value.isEmpty) return '$prefix.';
    final box = await _algorithm.encryptString(value, secretKey: await _key());
    final payload = jsonEncode({
      'n': base64Encode(box.nonce),
      'm': base64Encode(box.mac.bytes),
      'c': base64Encode(box.cipherText),
    });
    return '$prefix${base64Encode(utf8.encode(payload))}';
  }

  @override
  Future<String> decryptString(String value) async {
    if (!isEncrypted(value)) return value;
    final body = value.substring(prefix.length);
    if (body == '.') return '';
    final decoded = jsonDecode(utf8.decode(base64Decode(body)));
    if (decoded is! Map) {
      throw StateError('Stored LAN field is invalid.');
    }
    final box = SecretBox(
      base64Decode(decoded['c'] as String),
      nonce: base64Decode(decoded['n'] as String),
      mac: Mac(base64Decode(decoded['m'] as String)),
    );
    return _algorithm.decryptString(box, secretKey: await _key());
  }

  Future<SecretKey> _key() async {
    final cached = _cachedKey;
    if (cached != null) return cached;
    final stored = await _secrets.read(NetworkLanStorageKeys.dataProtectionKey);
    if (stored != null && stored.isNotEmpty) {
      final bytes = base64Decode(stored);
      if (bytes.length != 32) {
        throw StateError('Stored data protection key is invalid.');
      }
      final key = SecretKey(Uint8List.fromList(bytes));
      _cachedKey = key;
      return key;
    }
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await _secrets.write(
      NetworkLanStorageKeys.dataProtectionKey,
      base64Encode(bytes),
    );
    final key = SecretKey(bytes);
    _cachedKey = key;
    return key;
  }
}
