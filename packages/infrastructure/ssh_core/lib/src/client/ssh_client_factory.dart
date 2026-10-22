// SSH Client 工厂。
//
// 工厂只负责凭据读取、身份解析、认证回调、Socket 建立和 Host Key 策略绑定。
// 它依赖 Connection/Credential/HostKey Repository，不直接依赖 App Shell 存储实现。

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../model/ssh_credentials.dart';
import 'ssh_host_key_policy.dart';
import 'ssh_native_socket.dart';

/// dartssh2 认证参数快照。
final class SshClientAuthOptions {
  /// 创建认证参数。
  const SshClientAuthOptions({
    required this.identities,
    required this.onPasswordRequest,
    required this.onUserInfoRequest,
  });

  final List<SSHKeyPair>? identities;
  final SSHPasswordRequestHandler? onPasswordRequest;
  final SSHUserInfoRequestHandler? onUserInfoRequest;
}

/// 从 [ConnectionConfig] 解析 enrolled peer 标识的解析器。
///
/// App 层可以通过 ConnectionConfig→PeerCatalog 索引实现；当前没有 peer 绑定的
/// 连接返回 null，工厂会回退到原始 TCP Socket（保持既有任意主机 SSH 可用）。
typedef SshPeerIdResolver = String? Function(ConnectionConfig config);

/// 通过 Core Repository 创建已认证 SSH Client。
class SshClientFactory {
  /// 创建 Client 工厂。
  ///
  /// [nativeStreamConnector] 非空时，[connectClient] 优先通过 native
  /// ReliableStream 建立 Socket（[SshNativeSocket]）；没有 connector 或没有
  /// 可解析的 peer 绑定时回退到 `SSHSocket.connect` 原始 TCP。
  const SshClientFactory({
    required this.credentialRepository,
    required this.hostKeyRepository,
    required this.logger,
    this.nativeStreamConnector,
    this.peerIdResolver,
  });

  final CredentialRepository credentialRepository;
  final HostKeyRepository hostKeyRepository;
  final AppLogger logger;

  /// 可选的 native ReliableStream 连接器；null 表示不启用 native 传输。
  final SshNativeStreamConnector? nativeStreamConnector;

  /// 可选的对端绑定解析器；仅在 [nativeStreamConnector] 非空时使用。
  final SshPeerIdResolver? peerIdResolver;

  static final RegExp _passwordPromptPattern = RegExp(
    r'password|passwd|passphrase|pass phrase|密码|口令|密碼|passwort|'
    r'mot\s+de\s+passe|contraseña|пароль|비밀번호',
    caseSensitive: false,
  );
  static final RegExp _usernamePromptPattern = RegExp(
    r'username|user\s+name|login|account|用户名|用户|账号|帳號',
    caseSensitive: false,
  );

  /// 从安全凭据 Repository 读取指定连接的认证材料。
  Future<SshCredentials> loadCredentials(ConnectionConfig config) async {
    final password = await credentialRepository.getPassword(config.id);
    final privateKey = await credentialRepository.getPrivateKey(config.id);
    validateAuthSecrets(
      config: config,
      password: password,
      privateKey: privateKey,
      logger: logger,
    );
    return SshCredentials(password: password, privateKey: privateKey);
  }

  /// 建立 Socket、绑定 Host Key 策略并完成认证。
  ///
  /// [peerId] 显式提供 enrolled peer 标识时优先走 native 传输；未提供则通过
  /// [peerIdResolver] 解析。native 不可用（无 connector / 无 peer 绑定）时回退到
  /// 原始 TCP Socket，保持任意主机 SSH 的既有行为。
  /// [persistHostKeyTrust] 只允许保存编排器设为 false：确认仍然必需，但候选信任
  /// 由调用方随后与连接结构和凭据统一提交；普通连接必须保留默认值。
  Future<SSHClient> connectClient(
    ConnectionConfig config, {
    Duration timeout = const Duration(seconds: 15),
    SshCredentials? credentials,
    SshHostKeyConfirmation? onUnknownHostKey,
    String? peerId,
    String? traceId,
    bool persistHostKeyTrust = true,
  }) async {
    final resolved = credentials ?? await loadCredentials(config);
    validateAuthSecrets(
      config: config,
      password: resolved.password,
      privateKey: resolved.privateKey,
      logger: logger,
    );
    final identities = await identitiesFor(config, resolved);
    final authOptions = buildAuthOptions(
      config: config,
      credentials: resolved,
      identities: identities,
    );
    final hostKeyPolicy = SshHostKeyPolicy(
      logger: logger,
      onUnknownHostKey: onUnknownHostKey,
      persistTrust: persistHostKeyTrust
          ? (updatedConfig) => hostKeyRepository.trustHostKey(
              updatedConfig.id,
              algorithm: updatedConfig.hostKeyAlgorithm,
              fingerprint: updatedConfig.hostKeyFingerprint,
              trustedAt: updatedConfig.hostKeyTrustedAt,
            )
          : null,
    );
    _log(
      LogLevel.info,
      'SSH client connecting',
      details:
          'connection=${config.name} host=${config.host}:${config.port} '
          'user=${config.username} authMethod=${config.authMethod.name}',
    );
    final socket = await _openSocket(
      config,
      timeout: timeout,
      peerId: peerId,
      traceId: traceId,
    );
    try {
      final client = SSHClient(
        socket,
        username: config.username,
        onVerifyHostKey: (algorithm, fingerprint) =>
            hostKeyPolicy.verifyHostKey(
              config: config,
              algorithm: algorithm,
              md5Fingerprint: fingerprint,
            ),
        identities: authOptions.identities,
        onPasswordRequest: authOptions.onPasswordRequest,
        onUserInfoRequest: authOptions.onUserInfoRequest,
      );
      await client.authenticated.timeout(timeout);
      return client;
    } catch (error, stackTrace) {
      _log(
        LogLevel.error,
        'SSH client setup failed',
        details: 'connection=${config.name}',
        error: error,
        stackTrace: stackTrace,
      );
      try {
        await socket.close();
      } catch (closeError, closeStackTrace) {
        _log(
          LogLevel.warning,
          'SSH socket cleanup failed after client setup failure',
          details: 'connection=${config.name}',
          error: closeError,
          stackTrace: closeStackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// 打开 SSH Socket：native ReliableStream 优先，原始 TCP 回退。
  Future<SSHSocket> _openSocket(
    ConnectionConfig config, {
    required Duration timeout,
    String? peerId,
    String? traceId,
  }) async {
    final connector = nativeStreamConnector;
    if (connector == null) {
      return SSHSocket.connect(config.host, config.port, timeout: timeout);
    }
    final resolvedPeerId = peerId ?? peerIdResolver?.call(config);
    if (resolvedPeerId == null || resolvedPeerId.trim().isEmpty) {
      _log(
        LogLevel.warning,
        'SSH connection has no peer binding; falling back to TCP socket',
        details: 'connection=${config.name} host=${config.host}:${config.port}',
      );
      return SSHSocket.connect(config.host, config.port, timeout: timeout);
    }
    _log(
      LogLevel.info,
      'SSH client opening native reliable stream',
      details:
          'connection=${config.name} peer=$resolvedPeerId '
          'service=$kSshNativeStreamService',
    );
    final stream = await connector.open(
      peerId: resolvedPeerId,
      service: kSshNativeStreamService,
      traceId: traceId,
    );
    return SshNativeSocket(stream: stream);
  }

  /// 根据认证模式构造 dartssh2 身份和回调。
  static SshClientAuthOptions buildAuthOptions({
    required ConnectionConfig config,
    required SshCredentials credentials,
    required List<SSHKeyPair>? identities,
  }) {
    final password = credentials.password?.isNotEmpty == true
        ? credentials.password
        : null;
    final usesPassword = config.authMethod != AuthMethod.privateKey;
    return SshClientAuthOptions(
      identities: identities,
      onPasswordRequest: usesPassword && password != null
          ? () => password
          : null,
      onUserInfoRequest: usesPassword && password != null
          ? (request) => keyboardInteractiveResponsesForPassword(
              request,
              password,
              username: config.username,
            )
          : null,
    );
  }

  /// 在后台 isolate 解析 PEM，避免阻塞 UI isolate。
  static Future<List<SSHKeyPair>?> identitiesFor(
    ConnectionConfig config,
    SshCredentials credentials,
  ) async {
    final shouldUseKey =
        config.authMethod == AuthMethod.privateKey ||
        config.authMethod == AuthMethod.both;
    if (!shouldUseKey || credentials.privateKey?.isNotEmpty != true) {
      return null;
    }
    return compute(_parsePemKey, {
      'pem': credentials.privateKey!,
      'passphrase': credentials.password,
    });
  }

  /// 安全回答能识别为用户名或密码输入的 keyboard-interactive 提示。
  static List<String>? keyboardInteractiveResponsesForPassword(
    Object request,
    String password, {
    String? username,
  }) {
    if (password.isEmpty) return null;
    final prompts = _keyboardInteractivePrompts(request);
    if (prompts.isEmpty) return const [];
    final normalizedUsername = username?.trim();
    final responses = <String>[];
    for (final prompt in prompts) {
      if (prompt.echo) {
        if (normalizedUsername?.isEmpty != false ||
            !_usernamePromptPattern.hasMatch(prompt.promptText)) {
          return null;
        }
        responses.add(normalizedUsername!);
        continue;
      }
      if (prompts.length == 1 ||
          prompt.promptText.trim().isEmpty ||
          _passwordPromptPattern.hasMatch(prompt.promptText)) {
        responses.add(password);
        continue;
      }
      // Do not send the SSH password to an unrecognized hidden prompt such as
      // an OTP or approval challenge.
      return null;
    }
    return responses;
  }

  /// 在建立 Socket 前校验认证材料是否完整。
  static void validateAuthSecrets({
    required ConnectionConfig config,
    required String? password,
    required String? privateKey,
    AppLogger? logger,
  }) {
    final hasPassword = password?.isNotEmpty == true;
    final hasPrivateKey = privateKey?.isNotEmpty == true;
    StateError missingError(String message) {
      final error = StateError(message);
      logger?.log(
        LogRecord(
          timestamp: DateTime.now(),
          level: LogLevel.warning,
          source: 'ssh_core',
          message: 'SSH credential validation failed: $message',
          details:
              'connection=${config.name} authMethod=${config.authMethod.name}',
        ),
      );
      return error;
    }

    switch (config.authMethod) {
      case AuthMethod.password:
        if (!hasPassword) {
          throw missingError('Password is missing for this connection.');
        }
      case AuthMethod.privateKey:
        if (!hasPrivateKey) {
          throw missingError('Private key is missing for this connection.');
        }
      case AuthMethod.both:
        if (!hasPrivateKey || !hasPassword) {
          throw missingError(
            'Password or private key is missing for this connection.',
          );
        }
    }
  }

  static List<SSHKeyPair> _parsePemKey(Map<String, String?> args) {
    return SSHKeyPair.fromPem(args['pem']!, args['passphrase']);
  }

  static List<_KeyboardInteractivePrompt> _keyboardInteractivePrompts(
    Object request,
  ) {
    final dynamic dynamicRequest = request;
    final prompts = dynamicRequest.prompts;
    if (prompts is! Iterable) return const [];
    return prompts
        .map<_KeyboardInteractivePrompt?>((prompt) {
          final dynamic dynamicPrompt = prompt;
          final promptText = dynamicPrompt.promptText;
          final echo = dynamicPrompt.echo;
          if (promptText is! String || echo is! bool) return null;
          return _KeyboardInteractivePrompt(promptText: promptText, echo: echo);
        })
        .whereType<_KeyboardInteractivePrompt>()
        .toList(growable: false);
  }

  void _log(
    LogLevel level,
    String message, {
    String? details,
    Object? error,
    StackTrace? stackTrace,
  }) {
    logger.log(
      LogRecord(
        timestamp: DateTime.now(),
        level: level,
        source: 'ssh_core',
        message: message,
        details: details,
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }
}

final class _KeyboardInteractivePrompt {
  const _KeyboardInteractivePrompt({
    required this.promptText,
    required this.echo,
  });

  final String promptText;
  final bool echo;
}
