import 'dart:convert';

import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';

/// 路由独占的凭据编辑状态，只持有本次显式解锁的短生命周期明文。
/// 平台认证与密文持久化仍属于 Core/App；释放或锁定后迟到结果不能回填。
final class ConnectionCredentialEditor extends ChangeNotifier {
  ConnectionCredentialEditor({
    required this.connectionId,
    required ConnectionRepository connectionRepository,
    required CredentialRepository credentialRepository,
    Future<void> Function(Future<void> Function())? runMutation,
  }) : _connections = connectionRepository,
       _credentials = credentialRepository,
       _runMutation = runMutation ?? ((action) => action());

  final String connectionId;
  final ConnectionRepository _connections;
  final CredentialRepository _credentials;
  final Future<void> Function(Future<void> Function()) _runMutation;
  CredentialPair? _pair;
  CredentialProtectionError? _error;
  String? _revision;
  bool _protected = true;
  bool _busy = false;
  bool _disposed = false;
  int _generation = 0;
  String? _initialTarget;
  bool _targetStale = false;

  CredentialProtectionRepository? get _protection =>
      _credentials is CredentialProtectionRepository
      ? _credentials as CredentialProtectionRepository
      : null;

  bool get supportsProtection => _protection?.supportsProtection ?? false;
  bool get isProtected => _protected;
  bool get isBusy => _busy;
  CredentialPair? get credentials => _pair;
  CredentialProtectionError? get error => _error;
  String? get revision => _revision;

  /// 表单仍绑定初次加载的 Repository 结构；读取不发送通知，也不接受新目标。
  bool get isAccessCurrent {
    if (_disposed) return false;
    final target = _initialTarget;
    if (target == null) return false;
    if (target.isEmpty || _target() != target) _targetStale = true;
    return !_targetStale;
  }

  /// UI 和实际保存动作共用的入口门禁；不比较用户尚未提交的表单字段。
  bool get canSubmit =>
      !_busy && isAccessCurrent && (!_protected || _pair != null);

  /// 保存前固定编辑租约；提交后的结构由 VM 校验，不能把自身 staged 写入当重绑。
  /// 租约只核验 Route generation、同一 pair 和 revision，不拥有平台认证会话。
  bool Function() captureSubmissionAccess() {
    _requireCurrent(_generation, _initialTarget ?? '');
    if (_busy || (_protected && _pair == null)) {
      throw const CredentialProtectionException(
        CredentialProtectionError.locked,
      );
    }
    final generation = _generation;
    final pair = _pair;
    final revision = _revision;
    return () =>
        !_disposed &&
        generation == _generation &&
        identical(pair, _pair) &&
        revision == _revision;
  }

  /// 读取保护状态；受保护时不触碰旧的单项明文 getter。
  Future<void> initialize() => _run(_loadState);

  Future<void> _loadState(int generation, String target) async {
    final protection = _protection;
    final protected = protection == null
        ? false
        : await protection.isProtected(connectionId);
    _requireCurrent(generation, target);
    _protected = protected;
    _revision = await protection?.protectionRevision(connectionId);
    _requireCurrent(generation, target);
    _pair = null;
    if (!protected) {
      final password = await _credentials.getPassword(connectionId);
      _requireCurrent(generation, target);
      final privateKey = await _credentials.getPrivateKey(connectionId);
      _requireCurrent(generation, target);
      _pair = CredentialPair(password: password, privateKey: privateKey);
    }
  }

  /// 一次认证返回完整 pair，并在发布前复核目标与凭据 revision。
  Future<void> unlock() => _run((generation, target) async {
    final protection = _requireProtection();
    if (!_protected) return;
    final pair = await protection.unlockCredentials(
      connectionId,
      expectedRevision: _revision,
    );
    _requireCurrent(generation, target);
    final currentRevision = await protection.protectionRevision(connectionId);
    _requireCurrent(generation, target);
    if (pair.revision == null || currentRevision != pair.revision) {
      throw const CredentialProtectionException(
        CredentialProtectionError.stale,
      );
    }
    _revision = pair.revision;
    _pair = pair;
  });

  /// 保护变更与连接保存、删除共用外部 mutation queue；Core 在认证后再核验令牌。
  Future<void> setProtection(bool enabled) => _run((generation, target) async {
    final protection = _requireProtection();
    await _runMutation(() async {
      _requireCurrent(generation, target);
      if (enabled) {
        await protection.enableProtection(
          connectionId,
          isCurrent: () => _isCurrent(generation, target),
        );
      } else {
        await protection.disableProtection(
          connectionId,
          expectedRevision: _revision,
          isCurrent: () => _isCurrent(generation, target),
        );
      }
      _requireCurrent(generation, target);
      await _loadState(generation, target);
    });
  });

  CredentialProtectionRepository _requireProtection() {
    final protection = _protection;
    if (protection == null || !protection.supportsProtection) {
      throw const CredentialProtectionException(
        CredentialProtectionError.unsupported,
      );
    }
    return protection;
  }

  Future<void> _run(Future<void> Function(int, String) action) async {
    if (_disposed || _busy) return;
    final generation = ++_generation;
    // 编辑字段只在路由初始化时加载，重试不能偷偷接受外部替换后的连接。
    final target = _initialTarget ??= _target();
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      _requireCurrent(generation, target);
      await action(generation, target);
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _pair = null;
        _error = error is CredentialProtectionException
            ? error.code
            : CredentialProtectionError.storageFailure;
        await _refreshProtectionAfterFailure(generation, target);
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  /// 迁移可能已经写入权威保护记录后才在旧键清理失败；只刷新非秘密状态。
  Future<void> _refreshProtectionAfterFailure(
    int generation,
    String target,
  ) async {
    final protection = _protection;
    if (protection == null) return;
    try {
      final protected = await protection.isProtected(connectionId);
      final revision = await protection.protectionRevision(connectionId);
      if (_isCurrent(generation, target)) {
        _protected = protected;
        _revision = revision;
      }
    } catch (_) {
      if (_isCurrent(generation, target)) _protected = true;
    }
  }

  /// 只比较连接的非敏感结构快照；不替代 App 的远端审批/Host Key 目标 Owner。
  String _target() {
    final config = _connections.getConnection(connectionId);
    return config == null ? '' : jsonEncode(config.toJson());
  }

  bool _isCurrent(int generation, String target) {
    if (_disposed || generation != _generation) return false;
    // 观察到结构变化即永久失效；即使随后恢复原值也必须重开整个编辑路由。
    return target == _initialTarget && isAccessCurrent;
  }

  void _requireCurrent(int generation, String target) {
    if (!_isCurrent(generation, target)) {
      throw const CredentialProtectionException(
        CredentialProtectionError.stale,
      );
    }
  }

  /// 明确锁定或 App 隐藏时清除本次明文，并使正在认证的结果失效。
  void lock() {
    if (_disposed) return;
    _generation++;
    _pair = null;
    _busy = false;
    _error = _targetStale ? CredentialProtectionError.stale : null;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _pair = null;
    super.dispose();
  }
}
