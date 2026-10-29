import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App 的原生认证加密适配器；密钥、提示框和取消归当前 Android Activity。
/// 这里只传递一次操作的数据，不缓存解密凭据，也不创建第二个安全存储。
final class AndroidCredentialCrypto implements CredentialCryptoPort {
  AndroidCredentialCrypto({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('ssh_mobile/credential_protection');

  final MethodChannel _channel;
  Future<void>? _initialization;
  bool _supported = false;
  static int _sequence = 0;
  static const _maxBytes = 512 * 1024;

  /// 初始化只查询平台能力；录入状态与锁定状态由原生每次操作动态核验。
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      _supported =
          await _channel
              .invokeMethod<Object?>('capability')
              .timeout(const Duration(seconds: 2)) ==
          true;
    } on PlatformException {
      _supported = false;
    } on MissingPluginException {
      _supported = false;
    } on TimeoutException {
      _supported = false;
    }
  }

  @override
  bool get supportsProtection => _supported;

  @override
  Future<CredentialCiphertext> seal({
    required String connectionId,
    required String revision,
    required Uint8List plaintext,
  }) async {
    if (plaintext.length > _maxBytes) throw _corrupt;
    final raw = await _invoke('seal', {
      'connectionId': connectionId,
      'revision': revision,
      'plaintext': plaintext,
    });
    if (raw is! Map) throw _corrupt;
    final iv = raw['iv'];
    final ciphertext = raw['ciphertext'];
    if (iv is! Uint8List ||
        iv.length != 12 ||
        ciphertext is! Uint8List ||
        ciphertext.length != plaintext.length + 16) {
      throw _corrupt;
    }
    return CredentialCiphertext(iv: iv, ciphertext: ciphertext);
  }

  @override
  Future<Uint8List> open({
    required String connectionId,
    required String revision,
    required CredentialCiphertext ciphertext,
  }) async {
    if (ciphertext.iv.length != 12 ||
        ciphertext.ciphertext.length < 16 ||
        ciphertext.ciphertext.length > _maxBytes + 16) {
      throw _corrupt;
    }
    final raw = await _invoke('open', {
      'connectionId': connectionId,
      'revision': revision,
      'iv': ciphertext.iv,
      'ciphertext': ciphertext.ciphertext,
    });
    if (raw is! Uint8List || raw.length != ciphertext.ciphertext.length - 16) {
      throw _corrupt;
    }
    return raw;
  }

  @override
  Future<void> removeKey({
    required String connectionId,
    required String revision,
  }) async {
    final removed = await _invoke('removeKey', {
      'connectionId': connectionId,
      'revision': revision,
    });
    if (removed != true) {
      throw const CredentialProtectionException(
        CredentialProtectionError.authenticationFailed,
      );
    }
  }

  Future<Object?> _invoke(String method, Map<String, Object?> arguments) async {
    if (!_supported) {
      throw const CredentialProtectionException(
        CredentialProtectionError.unsupported,
      );
    }
    try {
      return await _channel.invokeMethod<Object?>(method, {
        ...arguments,
        'operationId':
            '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
      });
    } on MissingPluginException {
      throw const CredentialProtectionException(
        CredentialProtectionError.unsupported,
      );
    } on PlatformException catch (error) {
      throw CredentialProtectionException(switch (error.code) {
        'CREDENTIAL_CANCELLED' => CredentialProtectionError.cancelled,
        'CREDENTIAL_UNAVAILABLE' => CredentialProtectionError.unsupported,
        'CREDENTIAL_INVALIDATED' ||
        'CREDENTIAL_MISSING' => CredentialProtectionError.keyInvalidated,
        'CREDENTIAL_BUSY' => CredentialProtectionError.locked,
        'CREDENTIAL_INVALID_ARGUMENT' => CredentialProtectionError.corrupt,
        _ => CredentialProtectionError.authenticationFailed,
      });
    }
  }

  static const _corrupt = CredentialProtectionException(
    CredentialProtectionError.corrupt,
  );
}
