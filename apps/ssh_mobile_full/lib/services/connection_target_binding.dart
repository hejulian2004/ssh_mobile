import 'dart:convert';

import 'package:connection_core/connection_core.dart';

/// Immutable, non-secret identity of a saved remote connection target.
///
/// The binding intentionally excludes display and tuning fields such as the
/// connection name, group, terminal size, keep-alive settings, and timestamps.
/// Those fields do not change where or how a remote operation authenticates.
class ConnectionTargetBinding {
  final String id;
  final String _name;
  final String _host;
  final int _port;
  final String _username;
  final AuthMethod _authMethod;
  final ServerPlatform _serverPlatform;
  final TerminalLaunchMode _launchMode;
  final int _tmuxAutoDeleteSeconds;
  final String? _hostKeyFingerprint;
  final String? _hostKeyAlgorithm;
  final String? _jumpHost;
  final int? _jumpPort;
  final String? _jumpUsername;
  final ConnectionConfig _configSnapshot;

  ConnectionTargetBinding._({
    required this.id,
    required this._name,
    required this._host,
    required this._port,
    required this._username,
    required this._authMethod,
    required this._serverPlatform,
    required this._launchMode,
    required this._tmuxAutoDeleteSeconds,
    required this._hostKeyFingerprint,
    required this._hostKeyAlgorithm,
    required this._jumpHost,
    required this._jumpPort,
    required this._jumpUsername,
    required this._configSnapshot,
  });

  factory ConnectionTargetBinding.fromConfig(ConnectionConfig config) {
    final snapshot = _cloneConfig(config);
    final hostKeyFingerprint = _normalizeFingerprint(
      snapshot.hostKeyFingerprint,
    );
    final jumpHost = _normalizeHost(snapshot.jumpHost);
    return ConnectionTargetBinding._(
      id: snapshot.id,
      name: snapshot.name,
      host: snapshot.host.trim().toLowerCase(),
      port: snapshot.port,
      username: snapshot.username,
      authMethod: snapshot.authMethod,
      serverPlatform: snapshot.serverPlatform,
      launchMode: snapshot.launchMode,
      tmuxAutoDeleteSeconds: snapshot.tmuxAutoDeleteSeconds,
      hostKeyFingerprint: hostKeyFingerprint,
      hostKeyAlgorithm: hostKeyFingerprint == null
          ? null
          : _normalizeOptionalLower(snapshot.hostKeyAlgorithm),
      jumpHost: jumpHost,
      jumpPort: jumpHost == null ? null : snapshot.jumpPort,
      jumpUsername: jumpHost == null ? null : snapshot.jumpUsername,
      configSnapshot: snapshot,
    );
  }

  String get name => _name;
  String get host => _host;
  int get port => _port;
  String get username => _username;
  AuthMethod get authMethod => _authMethod;
  ServerPlatform get serverPlatform => _serverPlatform;
  TerminalLaunchMode get launchMode => _launchMode;
  int get tmuxAutoDeleteSeconds => _tmuxAutoDeleteSeconds;
  String? get hostKeyFingerprint => _hostKeyFingerprint;
  String? get hostKeyAlgorithm => _hostKeyAlgorithm;
  String? get jumpHost => _jumpHost;
  int? get jumpPort => _jumpPort;
  String? get jumpUsername => _jumpUsername;

  /// Returns a fresh non-secret copy so callers cannot mutate this binding.
  ConnectionConfig get config => _cloneConfig(_configSnapshot);

  /// Stable non-secret representation used by approval and trace boundaries.
  ///
  /// This is canonical JSON rather than a process-local hash so equality has
  /// no collision risk and remains stable across app restarts.
  String get fingerprint => jsonEncode(_securityFields);

  bool matches(ConnectionConfig? candidate) {
    if (candidate == null || candidate.id != id) return false;
    final candidateFingerprint = _normalizeFingerprint(
      candidate.hostKeyFingerprint,
    );
    final candidateJumpHost = _normalizeHost(candidate.jumpHost);
    return _host == candidate.host.trim().toLowerCase() &&
        _port == candidate.port &&
        _username == candidate.username &&
        _authMethod == candidate.authMethod &&
        _serverPlatform == candidate.serverPlatform &&
        _launchMode == candidate.launchMode &&
        _tmuxAutoDeleteSeconds == candidate.tmuxAutoDeleteSeconds &&
        _hostKeyFingerprint == candidateFingerprint &&
        _hostKeyAlgorithm ==
            (candidateFingerprint == null
                ? null
                : _normalizeOptionalLower(candidate.hostKeyAlgorithm)) &&
        _jumpHost == candidateJumpHost &&
        _jumpPort == (candidateJumpHost == null ? null : candidate.jumpPort) &&
        _jumpUsername ==
            (candidateJumpHost == null ? null : candidate.jumpUsername);
  }

  Map<String, Object?> get _securityFields => <String, Object?>{
    'id': id,
    'host': _host,
    'port': _port,
    'username': _username,
    'authMethod': _authMethod.name,
    'serverPlatform': _serverPlatform.name,
    'launchMode': _launchMode.name,
    'tmuxAutoDeleteSeconds': _tmuxAutoDeleteSeconds,
    'hostKeyFingerprint': _hostKeyFingerprint,
    'hostKeyAlgorithm': _hostKeyAlgorithm,
    'jumpHost': _jumpHost,
    'jumpPort': _jumpPort,
    'jumpUsername': _jumpUsername,
  };

  static ConnectionConfig _cloneConfig(ConnectionConfig source) {
    return ConnectionConfig.fromJson(
      Map<String, dynamic>.from(source.toJson()),
    );
  }

  static String? _normalizeHost(String? value) {
    final normalized = _normalizeOptional(value);
    return normalized?.toLowerCase();
  }

  static String? _normalizeOptionalLower(String? value) {
    return _normalizeOptional(value)?.toLowerCase();
  }

  static String? _normalizeOptional(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String? _normalizeFingerprint(String? value) {
    final trimmed = _normalizeOptional(value);
    if (trimmed == null) return null;
    final compact = trimmed
        .toLowerCase()
        .replaceFirst(RegExp(r'^md5:'), '')
        .replaceAll(':', '');
    if (RegExp(r'^[0-9a-f]{32}$').hasMatch(compact)) {
      return 'md5:$compact';
    }
    return trimmed.toLowerCase();
  }
}

/// A short-lived immutable target plus its secure authentication material.
///
/// Instances must never be logged, serialized, cached in chat state, or
/// persisted. [config] returns a fresh copy to keep the runtime target stable.
class ConnectionRuntimeTarget {
  final ConnectionTargetBinding binding;
  final ConnectionConfig _configSnapshot;
  final String? password;
  final String? privateKey;
  final Future<void> Function(ConnectionConfig?)? _validate;

  ConnectionRuntimeTarget(
    this.binding,
    ConnectionConfig config,
    this.password,
    this.privateKey, {
    Future<void> Function(ConnectionConfig?)? validate,
  }) : _configSnapshot = ConnectionConfig.fromJson(
         Map<String, dynamic>.from(config.toJson()),
       ),
       // Public callback parameter keeps the validation closure encapsulated.
       // ignore: prefer_initializing_formals
       _validate = validate {
    if (!binding.matches(config)) {
      throw ArgumentError.value(
        config.id,
        'config',
        'Runtime config does not match its target binding.',
      );
    }
  }

  ConnectionConfig get config => ConnectionConfig.fromJson(
    Map<String, dynamic>.from(_configSnapshot.toJson()),
  );

  /// 在 Socket 或后台凭据交接前再次验证目标及凭据版本，不缓存解锁状态。
  Future<void> validateCurrent([ConnectionConfig? authenticatedConfig]) async {
    await _validate?.call(authenticatedConfig);
  }
}
