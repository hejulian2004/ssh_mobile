// App Shell 的远程目标解析边界。
//
// 该文件只处理审批绑定的 Zone 作用域和 Connection Core Repository，
// 不持有数据库或统一存储门面；密码和私钥仅在解析后的短生命周期对象中
// 存在。
import 'dart:async';

import 'package:connection_core/connection_core.dart';

import 'connection_target_binding.dart';

/// 远程执行目标范围校验失败时返回的结构化异常。
class RemoteTargetScopeException implements Exception {
  final String code;
  final String connectionId;
  final String message;

  const RemoteTargetScopeException._({
    required this.code,
    required this.connectionId,
    required this.message,
  });

  factory RemoteTargetScopeException.notBound(String connectionId) {
    return RemoteTargetScopeException._(
      code: 'connection_not_bound',
      connectionId: connectionId,
      message: 'Connection is not bound to this remote execution scope.',
    );
  }

  factory RemoteTargetScopeException.notFound(String connectionId) {
    return RemoteTargetScopeException._(
      code: 'connection_not_found',
      connectionId: connectionId,
      message: 'Connection config not found',
    );
  }

  factory RemoteTargetScopeException.targetChanged(String connectionId) {
    return RemoteTargetScopeException._(
      code: 'approval_target_changed',
      connectionId: connectionId,
      message:
          'The saved connection target changed after it was selected. '
          'Review the updated target before retrying.',
    );
  }

  @override
  String toString() => '$code: $message (connectionId=$connectionId)';
}

/// 携带一次远程执行所授权的不可变连接集合。
class RemoteTargetScope {
  static final Object _bindingsZoneKey = Object();

  const RemoteTargetScope._();

  static Map<String, ConnectionTargetBinding>? get currentBindings {
    return Zone.current[_bindingsZoneKey]
        as Map<String, ConnectionTargetBinding>?;
  }

  static R run<R>(
    Map<String, ConnectionTargetBinding> bindings,
    R Function() callback,
  ) {
    final snapshot = <String, ConnectionTargetBinding>{};
    for (final entry in bindings.entries) {
      if (entry.key != entry.value.id) {
        throw ArgumentError.value(
          entry.key,
          'bindings',
          'Binding map keys must match binding ids.',
        );
      }
      snapshot[entry.key] = entry.value;
    }
    return runZoned(
      callback,
      zoneValues: {
        _bindingsZoneKey: Map<String, ConnectionTargetBinding>.unmodifiable(
          snapshot,
        ),
      },
    );
  }

  /// 在网络边界解析当前保存的目标与凭据，并拒绝越权或过期绑定。
  static Future<ConnectionRuntimeTarget> resolveIfBound({
    required ConnectionRepository connectionRepository,
    required CredentialRepository credentialRepository,
    required String connectionId,
    bool allowCredentialUnlock = false,
  }) async {
    final normalizedId = connectionId.trim();
    final scopedBindings = currentBindings;
    final binding = scopedBindings == null
        ? _captureBinding(connectionRepository, normalizedId)
        : scopedBindings[normalizedId];

    if (binding == null) {
      if (scopedBindings != null) {
        throw RemoteTargetScopeException.notBound(normalizedId);
      }
      throw RemoteTargetScopeException.notFound(normalizedId);
    }

    final target = await resolveBinding(
      binding,
      connectionRepository: connectionRepository,
      credentialRepository: credentialRepository,
      allowCredentialUnlock: allowCredentialUnlock,
    );
    if (target != null) return target;

    if (connectionRepository.getConnection(normalizedId) == null) {
      throw RemoteTargetScopeException.notFound(normalizedId);
    }
    throw RemoteTargetScopeException.targetChanged(normalizedId);
  }

  /// 按已授权绑定读取当前配置和安全凭据。
  static Future<ConnectionRuntimeTarget?> resolveBinding(
    ConnectionTargetBinding binding, {
    required ConnectionRepository connectionRepository,
    required CredentialRepository credentialRepository,
    bool allowCredentialUnlock = false,
  }) async {
    final config = connectionRepository.getConnection(binding.id);
    if (!binding.matches(config)) return null;
    final protection = credentialRepository is CredentialProtectionRepository
        ? credentialRepository as CredentialProtectionRepository
        : null;
    final revision = await protection?.protectionRevision(binding.id);
    final CredentialPair pair;
    if (revision != null) {
      if (!allowCredentialUnlock) {
        throw const CredentialProtectionException(
          CredentialProtectionError.locked,
        );
      }
      pair = await protection!.unlockCredentials(
        binding.id,
        expectedRevision: revision,
      );
      if (pair.revision != revision) {
        throw const CredentialProtectionException(
          CredentialProtectionError.stale,
        );
      }
    } else {
      pair = CredentialPair(
        password: await credentialRepository.getPassword(binding.id),
        privateKey: await credentialRepository.getPrivateKey(binding.id),
      );
    }
    Future<void> validate(ConnectionConfig? authenticatedConfig) async {
      var expected = binding;
      // Only a first, explicitly authenticated Host Key may enrich this snapshot.
      // It cannot change routing, user, authentication method or a pinned key.
      if (authenticatedConfig != null &&
          binding.hostKeyFingerprint == null &&
          authenticatedConfig.hostKeyFingerprint?.isNotEmpty == true) {
        final enriched = binding.config
          ..hostKeyAlgorithm = authenticatedConfig.hostKeyAlgorithm
          ..hostKeyFingerprint = authenticatedConfig.hostKeyFingerprint
          ..hostKeyTrustedAt = authenticatedConfig.hostKeyTrustedAt;
        expected = ConnectionTargetBinding.fromConfig(enriched);
        if (!expected.matches(authenticatedConfig)) {
          throw RemoteTargetScopeException.targetChanged(binding.id);
        }
      }
      final currentRevision = await protection?.protectionRevision(binding.id);
      if (!expected.matches(connectionRepository.getConnection(binding.id)) ||
          currentRevision != revision) {
        throw RemoteTargetScopeException.targetChanged(binding.id);
      }
    }

    if (!binding.matches(connectionRepository.getConnection(binding.id))) {
      return null;
    }
    await validate(null);
    return ConnectionRuntimeTarget(
      binding,
      config!,
      pair.password,
      pair.privateKey,
      validate: validate,
    );
  }

  static ConnectionTargetBinding? _captureBinding(
    ConnectionRepository repository,
    String connectionId,
  ) {
    final config = repository.getConnection(connectionId);
    return config == null ? null : ConnectionTargetBinding.fromConfig(config);
  }
}
