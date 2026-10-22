// LAN V2 TLS、配对 PIN、E2E 密钥与可信对端安全服务。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:basic_utils/basic_utils.dart' hide Mac;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'lan_peer_trust.dart';
import 'lan_pairing_crypto.dart';

/// 在工作 isolate 中生成自签名证书和私钥。
Map<String, String> _generateSelfSignedCertIsolate(String commonName) {
  final pair = CryptoUtils.generateEcKeyPair();
  final privKey = pair.privateKey as ECPrivateKey;
  final pubKey = pair.publicKey as ECPublicKey;

  final dn = {'CN': commonName, 'O': 'SSH Mobile LAN Share'};
  final csr = X509Utils.generateEccCsrPem(dn, privKey, pubKey);
  final certPem = X509Utils.generateSelfSignedCertificate(privKey, csr, 3650);
  final keyPem = CryptoUtils.encodeEcPrivateKeyToPem(privKey);

  return {'cert': certPem, 'key': keyPem};
}

/// 为定向单元测试同步生成证书材料。
@visibleForTesting
Map<String, String> generateSelfSignedCertForTest(String commonName) =>
    _generateSelfSignedCertIsolate(commonName);

/// 负责 TLS 证书生成、PIN 校验、ECDH 密钥协商和可信设备存储的服务。
class LanSecurityService {
  static const String _certKeyPrefix = 'lan_share_cert_';
  static const String _privateKeyPrefix = 'lan_share_key_';

  final FlutterSecureStorage _secureStorage;
  final LanPeerTrustStore peerTrustStore;
  final Uint8List _appOwnedX25519PrivateSeed;

  String? _cachedCertPem;
  String? _cachedKeyPem;
  SecurityContext? _cachedSecurityContext;
  String? _cachedSecurityContextDeviceId;
  Future<SecurityContext>? _securityContextFuture;
  String? _securityContextFutureDeviceId;

  String? _activePin;
  DateTime? _pinGeneratedTime;
  String? _previousPin;
  DateTime? _previousPinGeneratedTime;
  int _failedPinAttempts = 0;
  DateTime? _lockoutUntil;

  /// 创建使用平台安全存储的安全服务。
  LanSecurityService({
    required Uint8List appOwnedX25519PrivateSeed,
    FlutterSecureStorage? secureStorage,
    LanPeerTrustStore? peerTrustStore,
  }) : _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           ),
       peerTrustStore =
           peerTrustStore ??
           LanPeerTrustStore(
             secureStorage:
                 secureStorage ??
                 const FlutterSecureStorage(
                   mOptions: MacOsOptions(usesDataProtectionKeychain: false),
                 ),
           ),
       _appOwnedX25519PrivateSeed = _validateAppOwnedSeed(
         appOwnedX25519PrivateSeed,
       );

  static Uint8List _validateAppOwnedSeed(Uint8List seed) {
    if (seed.length != 32) {
      throw ArgumentError.value(
        seed.length,
        'appOwnedX25519PrivateSeed',
        'must contain exactly 32 bytes',
      );
    }
    return Uint8List.fromList(seed);
  }

  /// Create a bearer token for a pairing transaction without persisting it.
  /// The token becomes durable only as part of a complete trust record.
  String createPairingAccessToken() =>
      LanPairingCrypto.randomToken(byteLength: 32);

  /// Atomically persist the complete V2 peer trust record.  No caller should
  /// persist individual certificate, token, or public-key fields.
  Future<void> savePeerTrustRecord({
    required String deviceId,
    required String certificateFingerprint,
    required String inboundAccessToken,
    required String outboundAccessToken,
    required Uint8List x25519PublicKey,
    required Uint8List networkIdentityPublicKey,
    DateTime? createdAt,
  }) async {
    await peerTrustStore.save(
      LanPeerTrustRecord(
        deviceId: deviceId,
        certificateFingerprint: certificateFingerprint,
        inboundAccessToken: inboundAccessToken,
        outboundAccessToken: outboundAccessToken,
        x25519PublicKey: x25519PublicKey,
        networkIdentityPublicKey: networkIdentityPublicKey,
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: true,
          relay: false,
        ),
        createdAt: createdAt ?? DateTime.now().toUtc(),
      ),
    );
  }

  /// 检查远端设备是否存在完整 V2 信任记录。
  Future<bool> isDevicePaired(
    String deviceId, {
    String? ip,
    int? port,
    String? localDeviceId,
  }) async {
    return await peerTrustStore.read(deviceId) != null;
  }

  /// Read a pinned peer X25519 identity from the complete trust record.
  Future<Uint8List?> getPeerX25519PublicKey(String deviceId) async {
    final record = await peerTrustStore.read(deviceId);
    return record == null ? null : Uint8List.fromList(record.x25519PublicKey);
  }

  /// Read a pinned Network Identity key from the complete trust record.
  Future<Uint8List?> getPeerNetworkIdentityPublicKey(String deviceId) async {
    final record = await peerTrustStore.read(deviceId);
    return record == null
        ? null
        : Uint8List.fromList(record.networkIdentityPublicKey);
  }

  /// Read the outbound bearer credential from the complete trust record.
  Future<String?> getOutboundAccessToken(String deviceId) async {
    return (await peerTrustStore.read(deviceId))?.outboundAccessToken;
  }

  /// Read the pinned TLS certificate fingerprint from the complete trust record.
  Future<String?> getPeerCertificateFingerprint(String deviceId) async {
    return (await peerTrustStore.read(deviceId))?.certificateFingerprint;
  }

  /// 返回本设备用于 LAN V2 配对的证书指纹。
  Future<String> getLocalCertificateFingerprint(String deviceId) async {
    await getOrCreateSecurityContext(deviceId);
    final pem = _cachedCertPem;
    if (pem == null) throw StateError('LAN certificate is unavailable.');
    return computeCertFingerprint(pem);
  }

  // ── E2E 应用层加密 ─────────────────────────────────────────────────────

  /// 返回本设备是否支持 E2E 应用层加密。
  static const bool supportsE2EEncryption = true;

  /// 使用 X25519 ECDH 密钥协商与 AES-256-GCM 加密 [plaintext] 字节。
  ///
  /// 返回单个数据块：[32 字节临时公钥] [12 字节 nonce] [N 字节密文+tag]。
  ///
  /// 接收方使用自己的 X25519 私钥和发送方临时公钥派生相同共享秘密并解密。
  Future<Uint8List> encryptE2E(Uint8List plaintext) async {
    final x25519 = X25519();
    final aesGcm = AesGcm.with256bits();

    // 生成发送方临时密钥对。
    final ephemeralKeyPair = await x25519.newKeyPair();
    final ephemeralPubKey = await ephemeralKeyPair.extractPublicKey();

    // 获取持久接收方公钥（服务端解密时是本机公钥；发送方需要通过请求头交换
    // 接收方公钥）。不同设备分别拥有两端密钥，因此使用本设备静态 X25519 密钥
    // 作为“接收方密钥”派生 sharedSecret。
    final staticKeyPair = await _getOrCreateStaticX25519KeyPair();
    final staticPubKey = await staticKeyPair.extractPublicKey();

    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: staticPubKey,
    );

    final secretKey = SecretKey(await sharedSecret.extractBytes());
    final nonce = aesGcm.newNonce();
    final secretBox = await aesGcm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    // 组合：[32B 临时公钥] + [12B nonce] + [密文 + 16B tag]。
    final ephemeralPubBytes = ephemeralPubKey.bytes;
    final ciphertextWithTag = secretBox.cipherText + secretBox.mac.bytes;
    final result = Uint8List(
      ephemeralPubBytes.length + nonce.length + ciphertextWithTag.length,
    );
    result.setRange(0, ephemeralPubBytes.length, ephemeralPubBytes);
    result.setRange(
      ephemeralPubBytes.length,
      ephemeralPubBytes.length + nonce.length,
      nonce,
    );
    result.setRange(
      ephemeralPubBytes.length + nonce.length,
      result.length,
      ciphertextWithTag,
    );
    return result;
  }

  /// 使用目标 [recipientPubKeyBytes]（X25519 公钥）加密 [plaintext] 字节。
  ///
  /// 返回与 [encryptE2E] 相同的数据块格式：[32 字节临时公钥] [12 字节 nonce]
  /// [密文+tag]。
  Future<Uint8List> encryptE2EFor(
    Uint8List plaintext,
    Uint8List recipientPubKeyBytes,
  ) async {
    final x25519 = X25519();
    final aesGcm = AesGcm.with256bits();

    final ephemeralKeyPair = await x25519.newKeyPair();
    final ephemeralPubKey = await ephemeralKeyPair.extractPublicKey();
    final recipientPubKey = SimplePublicKey(
      recipientPubKeyBytes,
      type: KeyPairType.x25519,
    );

    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientPubKey,
    );

    final secretKey = SecretKey(await sharedSecret.extractBytes());
    final nonce = aesGcm.newNonce();
    final secretBox = await aesGcm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    final ephemeralPubBytes = ephemeralPubKey.bytes;
    final ciphertextWithTag = secretBox.cipherText + secretBox.mac.bytes;
    final result = Uint8List(
      ephemeralPubBytes.length + nonce.length + ciphertextWithTag.length,
    );
    result.setRange(0, ephemeralPubBytes.length, ephemeralPubBytes);
    result.setRange(
      ephemeralPubBytes.length,
      ephemeralPubBytes.length + nonce.length,
      nonce,
    );
    result.setRange(
      ephemeralPubBytes.length + nonce.length,
      result.length,
      ciphertextWithTag,
    );
    return result;
  }

  /// 使用本设备静态 X25519 私钥解密 [encryptE2EFor] 产生的数据块。
  Future<Uint8List> decryptE2E(Uint8List blob) async {
    const ephemeralPubLen = 32;
    const nonceLen = 12;
    const macLen = 16;

    if (blob.length < ephemeralPubLen + nonceLen + macLen) {
      throw ArgumentError('E2E blob too short');
    }

    final ephemeralPubBytes = blob.sublist(0, ephemeralPubLen);
    final nonce = blob.sublist(ephemeralPubLen, ephemeralPubLen + nonceLen);
    final ciphertextWithTag = blob.sublist(ephemeralPubLen + nonceLen);

    final ciphertext = ciphertextWithTag.sublist(
      0,
      ciphertextWithTag.length - macLen,
    );
    final mac = Mac(
      ciphertextWithTag.sublist(ciphertextWithTag.length - macLen),
    );

    final x25519 = X25519();
    final aesGcm = AesGcm.with256bits();

    final staticKeyPair = await _getOrCreateStaticX25519KeyPair();
    final ephemeralPubKey = SimplePublicKey(
      ephemeralPubBytes,
      type: KeyPairType.x25519,
    );

    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: staticKeyPair,
      remotePublicKey: ephemeralPubKey,
    );

    final secretKey = SecretKey(await sharedSecret.extractBytes());
    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: mac);
    final plaintext = await aesGcm.decrypt(secretBox, secretKey: secretKey);
    return Uint8List.fromList(plaintext);
  }

  /// 返回本设备持久化 X25519 公钥字节（32 字节）。
  Future<Uint8List> getStaticX25519PublicKeyBytes() async {
    final kp = await _getOrCreateStaticX25519KeyPair();
    final pub = await kp.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  /// 返回交给进程内原生网络运行时的持久化 X25519 种子。
  /// 调用方必须仅在内存中保存它。
  Future<Uint8List> getStaticX25519PrivateKeyBytes() async {
    final keyPair = await _getOrCreateStaticX25519KeyPair();
    return Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
  }

  SimpleKeyPair? _cachedX25519KeyPair;
  Future<SimpleKeyPair>? _x25519KeyPairFuture;

  /// 基于 AppScope 注入的 X25519 seed 构造本设备静态密钥对。
  Future<SimpleKeyPair> _getOrCreateStaticX25519KeyPair() {
    final cached = _cachedX25519KeyPair;
    if (cached != null) return Future<SimpleKeyPair>.value(cached);
    final active = _x25519KeyPairFuture;
    if (active != null) return active;
    late final Future<SimpleKeyPair> load;
    load = X25519()
        .newKeyPairFromSeed(_appOwnedX25519PrivateSeed)
        .then((key) {
          _cachedX25519KeyPair = key;
          return key;
        })
        .whenComplete(() {
          if (identical(_x25519KeyPairFuture, load)) {
            _x25519KeyPairFuture = null;
          }
        });
    _x25519KeyPairFuture = load;
    return load;
  }

  /// 生成或加载持久化 ECDSA 自签名 TLS 证书。
  Future<SecurityContext> getOrCreateSecurityContext(String deviceId) {
    final cached = _cachedSecurityContext;
    if (cached != null) {
      if (_cachedSecurityContextDeviceId != deviceId) {
        return Future<SecurityContext>.error(
          StateError('LAN TLS context is bound to a different device ID.'),
        );
      }
      return Future<SecurityContext>.value(cached);
    }
    final active = _securityContextFuture;
    if (active != null) {
      if (_securityContextFutureDeviceId != deviceId) {
        return Future<SecurityContext>.error(
          StateError('LAN TLS context creation is bound to another device ID.'),
        );
      }
      return active;
    }
    late final Future<SecurityContext> load;
    _securityContextFutureDeviceId = deviceId;
    load = _loadOrCreateSecurityContext(deviceId).whenComplete(() {
      if (identical(_securityContextFuture, load)) {
        _securityContextFuture = null;
        _securityContextFutureDeviceId = null;
      }
    });
    _securityContextFuture = load;
    return load;
  }

  Future<SecurityContext> _loadOrCreateSecurityContext(String deviceId) async {
    final certKey = '$_certKeyPrefix$deviceId';
    final privateKeyKey = '$_privateKeyPrefix$deviceId';

    _cachedCertPem = await _secureStorage.read(key: certKey);
    _cachedKeyPem = await _secureStorage.read(key: privateKeyKey);

    if (_cachedCertPem == null || _cachedKeyPem == null) {
      debugPrint(
        '[LanSecurityService] Generating new self-signed TLS certificate in Isolate...',
      );
      final commonName = 'device-$deviceId';
      final certData = await Isolate.run(
        () => _generateSelfSignedCertIsolate(commonName),
      );
      _cachedCertPem = certData['cert']!;
      _cachedKeyPem = certData['key']!;

      await _secureStorage.write(key: certKey, value: _cachedCertPem);
      await _secureStorage.write(key: privateKeyKey, value: _cachedKeyPem);
    }

    final context = SecurityContext(withTrustedRoots: false);
    final certBytes = utf8.encode(_cachedCertPem!);
    final keyBytes = utf8.encode(_cachedKeyPem!);

    context.useCertificateChainBytes(certBytes);
    context.usePrivateKeyBytes(keyBytes);

    _cachedSecurityContext = context;
    _cachedSecurityContextDeviceId = deviceId;
    return context;
  }

  /// 计算 PEM 证书的 SHA-256 指纹。
  Future<String> computeCertFingerprint(String certPem) async {
    final lines = certPem
        .split('\n')
        .where((line) => !line.startsWith('---'))
        .join('')
        .replaceAll('\r', '')
        .replaceAll('\n', '');
    final bytes = base64.decode(lines);
    final digest = await Sha256().hash(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 生成设备配对使用的随机六位 PIN。
  String generate6DigitPin() {
    final random = Random.secure();
    final pin = (100000 + random.nextInt(900000)).toString();

    // 保留旧的活动 PIN，用于宽限期校验。
    _previousPin = _activePin;
    _previousPinGeneratedTime = _pinGeneratedTime;

    _activePin = pin;
    _pinGeneratedTime = DateTime.now();
    _failedPinAttempts = 0;
    _lockoutUntil = null;
    debugPrint('[LanSecurityService] Generated a new pairing PIN');
    return pin;
  }

  /// 在活动配对 PIN 有效期间返回它。
  String? get activePin {
    if (_activePin == null || _pinGeneratedTime == null) return null;
    final diff = DateTime.now().difference(_pinGeneratedTime!);
    if (diff.inSeconds > 60) {
      _activePin = null;
      _pinGeneratedTime = null;
      return null;
    }
    return _activePin;
  }

  /// 返回活动配对 PIN 的剩余有效秒数。
  int get pinSecondsRemaining {
    if (_activePin == null || _pinGeneratedTime == null) return 0;
    final diff = DateTime.now().difference(_pinGeneratedTime!);
    final remaining = 60 - diff.inSeconds;
    return remaining > 0 ? remaining : 0;
  }

  /// 复用活动 PIN，或生成新的六位配对 PIN。
  String getOrGenerate6DigitPin() {
    final current = activePin;
    if (current != null) return current;
    return generate6DigitPin();
  }

  /// 在带锁定保护的前提下校验传入 PIN。
  bool verifyPin(String candidatePin) {
    debugPrint('[LanSecurityService] Verifying pairing PIN');
    if (_lockoutUntil != null && DateTime.now().isBefore(_lockoutUntil!)) {
      debugPrint(
        '[LanSecurityService] PIN verification locked out until $_lockoutUntil',
      );
      return false;
    }

    final currentPin = activePin;

    // 1. 与当前活动 PIN 校验。
    if (currentPin != null && candidatePin == currentPin) {
      debugPrint(
        '[LanSecurityService] PIN verified successfully (current PIN match)',
      );
      _failedPinAttempts = 0;
      return true;
    }

    // 2. 与旧 PIN 校验，并提供 15 秒宽限期（从旧 PIN 生成起总计 75 秒）。
    if (_previousPin != null && _previousPinGeneratedTime != null) {
      final diff = DateTime.now().difference(_previousPinGeneratedTime!);
      debugPrint(
        '[LanSecurityService] Checking previous PIN grace. Elapsed seconds since previous generation: ${diff.inSeconds}s',
      );
      if (diff.inSeconds <= 75 && candidatePin == _previousPin) {
        debugPrint(
          '[LanSecurityService] PIN verified successfully (previous PIN match via grace period)',
        );
        _failedPinAttempts = 0;
        return true;
      }
    }

    _failedPinAttempts++;
    debugPrint(
      '[LanSecurityService] PIN mismatch! Failed attempts: $_failedPinAttempts',
    );
    if (_failedPinAttempts >= 3) {
      _lockoutUntil = DateTime.now().add(const Duration(seconds: 30));
      debugPrint(
        '[LanSecurityService] PIN failed 3 times. Locked out for 30s.',
      );
    }
    return false;
  }

  /// 报告配对认证当前是否被锁定。
  bool get isLockedOut =>
      _lockoutUntil != null && DateTime.now().isBefore(_lockoutUntil!);

  /// 返回 SRP-6a 交换使用的当前轮换 PIN 候选。
  /// 每个候选拥有独立 salt 和指数。
  List<String> validPairingPinsForHandshake() {
    if (isLockedOut) return const [];
    final pins = <String>[];
    final current = activePin;
    if (current != null) pins.add(current);
    if (_previousPin != null && _previousPinGeneratedTime != null) {
      final age = DateTime.now().difference(_previousPinGeneratedTime!);
      if (age.inSeconds <= 75 && !pins.contains(_previousPin)) {
        pins.add(_previousPin!);
      }
    }
    return List.unmodifiable(pins);
  }

  /// 清除配对认证失败次数和锁定计数。
  void recordPairingAuthenticationSuccess() {
    _failedPinAttempts = 0;
    _lockoutUntil = null;
  }

  /// 记录一次配对认证失败，并应用锁定策略。
  void recordPairingAuthenticationFailure() {
    _failedPinAttempts++;
    if (_failedPinAttempts >= 3) {
      _lockoutUntil = DateTime.now().add(const Duration(seconds: 30));
    }
  }

  /// 使用恒定时间逐字节校验比较传入 token。
  Future<bool> verifyInboundAccessToken(String deviceId, String token) async {
    final expected = (await peerTrustStore.read(deviceId))?.inboundAccessToken;
    if (expected == null) return false;
    if (expected.length != token.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected.codeUnitAt(i) ^ token.codeUnitAt(i);
    }
    return difference == 0;
  }
}
