import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:app_core/app_core.dart';
import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../app_log_service.dart';
import '../../core/services/ssh_client_factory.dart';
import '../../core/services/data_protection_service.dart';
import '../connection_target_binding.dart';
import '../remote_target_scope.dart';
import '../sftp_path_history_store.dart';
import '../telemetry/telemetry_span.dart';
import '../tool_secret_policy.dart';
import '../sftp_service.dart';
import 'sftp_entry_parser.dart';
import 'sftp_log_safety.dart';

part 'sftp_cache.dart';
part 'sftp_operations.dart';
part 'sftp_connection_lifecycle.dart';
part 'sftp_directory_navigation.dart';
part 'sftp_session.dart';
part 'sftp_transfer_telemetry.dart';
part 'sftp_transfer_downloads.dart';
part 'sftp_transfer_uploads.dart';

/// SFTP 文件操作服务。
///
/// 职责：目录列表、文件上传/下载/读取/保存/删除。
/// 文件大小上限：文本编辑 512KB / 文本预览 2MB / 富预览 20MB / 上传 50MB / 下载 512MB。
/// 多级缓存：SFTP 连接按 connectionId + host 缓存复用。
/// 通知合并：调用 notifyListeners() 有 16ms 延迟合并窗口，防止高频操作导致 UI 卡顿。
class SftpService extends ChangeNotifier implements SftpClientAdapter {
  static const int maxTextEditBytes = 512 * 1024;
  static const int maxTextPreviewBytes = 2 * 1024 * 1024;
  static const int maxRichPreviewBytes = 20 * 1024 * 1024;
  static const int maxUploadBytes = 50 * 1024 * 1024;
  static const int maxDownloadBytes = 512 * 1024 * 1024;
  static const int maxInMemoryTransferBytes = maxDownloadBytes;
  static const Duration _notifyCoalesceDelay = Duration(milliseconds: 16);
  static const Duration _defaultTelemetryFailureTimeout = Duration(
    milliseconds: 250,
  );

  final ConnectionRepository _connectionRepository;
  final CredentialRepository _credentialRepository;
  final SftpPathHistoryStore _pathHistoryStore;
  final ssh_core.SshPeerIdResolver? _peerIdResolver;
  final SshClientFactory _clientFactory;

  final Map<String, _SftpSession> _sessions = {};
  final Map<String, String> _lastPaths = {};
  final Map<String, Future<void>> _connectTasks = {};
  final Map<String, Object> _connectAttempts = {};
  final SftpDirectoryCache _directoryCache = SftpDirectoryCache();
  Timer? _notifyTimer;
  String? _activeConnectionId;
  bool _disposed = false;
  SftpTransferState? _activeTransfer;
  String? _cancelTransferId;
  int _transferCancelGeneration = 0;

  /// 可选遥测客户端；由 Composition Root 在 SFTP 服务创建后注入。
  ///
  /// transfer span 共享同一个 traceId（started -> completed/failed），便于
  /// 端到端关联。本地路径、远程路径不写入事件属性，避免泄露服务器布局。
  TelemetryClient? telemetryClient;

  // 传输 span：键为 transferId，沿用 UUID traceId；跨 completed/failed
  // 端点保持会话内关联。
  final Map<String, String> _telemetryTransferTraceIds = {};
  final Map<String, DateTime> _telemetryTransferStartedAt = {};

  @override
  SftpTransferState? get activeTransfer => _activeTransfer;
  @override
  bool get hasActiveTransfer => _activeTransfer != null;

  SftpService({
    required this._connectionRepository,
    required this._credentialRepository,
    required HostKeyRepository hostKeyRepository,
    SftpPathHistoryStore? pathHistoryStore,
    ssh_core.SshNativeStreamConnector? nativeStreamConnector,
    this._peerIdResolver,
    SshClientFactory? clientFactory,
    this.telemetryClient,
    Duration telemetryFailureTimeout = _defaultTelemetryFailureTimeout,
  }) : _pathHistoryStore = pathHistoryStore ?? InMemorySftpPathHistoryStore(),
       _telemetryFailureTimeout = _validateTelemetryFailureTimeout(
         telemetryFailureTimeout,
       ),
       _clientFactory =
           clientFactory ??
           SshClientFactory(
             credentialRepository: _credentialRepository,
             hostKeyRepository: hostKeyRepository,
             logger: AppLogService.instance,
             nativeStreamConnector: nativeStreamConnector,
             peerIdResolver: _peerIdResolver,
           );

  @visibleForTesting
  SftpService.forTesting(
    this._connectionRepository,
    this._credentialRepository,
    HostKeyRepository hostKeyRepository, {
    required ConnectionConfig connection,
    required SftpClient sftpClient,
    String currentPath = '.',
    SftpPathHistoryStore? pathHistoryStore,
    ssh_core.SshNativeStreamConnector? nativeStreamConnector,
    this._peerIdResolver,
    SshClientFactory? clientFactory,
    this.telemetryClient,
    Duration telemetryFailureTimeout = _defaultTelemetryFailureTimeout,
  }) : _pathHistoryStore = pathHistoryStore ?? InMemorySftpPathHistoryStore(),
       _telemetryFailureTimeout = _validateTelemetryFailureTimeout(
         telemetryFailureTimeout,
       ),
       _clientFactory =
           clientFactory ??
           SshClientFactory(
             credentialRepository: _credentialRepository,
             hostKeyRepository: hostKeyRepository,
             logger: AppLogService.instance,
             nativeStreamConnector: nativeStreamConnector,
             peerIdResolver: _peerIdResolver,
           ) {
    final session =
        _SftpSession(
            connectionId: connection.id,
            connectionName: connection.name,
            currentPath: currentPath,
            targetBinding: ConnectionTargetBinding.fromConfig(connection),
          )
          ..sftp = sftpClient
          ..state = SftpConnectionState.connected;
    _sessions[connection.id] = session;
    _activeConnectionId = connection.id;
  }

  final Duration _telemetryFailureTimeout;

  static Duration _validateTelemetryFailureTimeout(Duration timeout) {
    if (timeout.compareTo(Duration.zero) < 0) {
      throw ArgumentError.value(
        timeout,
        'telemetryFailureTimeout',
        'must not be negative',
      );
    }
    return timeout;
  }

  static String _decodeUtf8(Uint8List bytes) {
    return utf8.decode(bytes, allowMalformed: true);
  }

  _SftpSession? get _activeSession =>
      _activeConnectionId == null ? null : _sessions[_activeConnectionId];

  @override
  String? get connectionId => _activeSession?.connectionId;

  String? get targetFingerprint {
    final binding = _activeSession?.targetBinding;
    if (binding == null ||
        !binding.matches(_connectionRepository.getConnection(binding.id))) {
      return null;
    }
    return binding.fingerprint;
  }

  @override
  String? get connectionName => _activeSession?.connectionName;
  @override
  String get currentPath => _activeSession?.currentPath ?? '.';
  @override
  SftpConnectionState get state =>
      _activeSession?.state ?? SftpConnectionState.disconnected;
  @override
  String? get errorMessage => _activeSession?.errorMessage;
  @override
  int get entriesRevision => _activeSession?.entriesRevision ?? 0;
  @override
  List<SftpEntry> get entries => _activeSession?.entries ?? const [];
  @override
  bool get isConnected => _activeSession?.sftp != null;
  SftpClient? getSftpClientForConnection(String id) => _sessions[id]?.sftp;
  @override
  bool get isBusy =>
      state == SftpConnectionState.connecting ||
      state == SftpConnectionState.loading;

  @override
  bool isConnectionBusy(String connectionId) {
    final session = _sessions[connectionId];
    return session?.state == SftpConnectionState.connecting ||
        session?.state == SftpConnectionState.loading;
  }

  @override
  bool isConnectionOpen(String connectionId) {
    return _sessions[connectionId]?.sftp != null;
  }

  Future<List<SftpRecentPathRecord>> loadRecentPaths(
    String connectionId, {
    int limit = 30,
  }) {
    return _pathHistoryStore.loadRecentPaths(connectionId, limit: limit);
  }

  Future<List<SftpFavoritePathRecord>> loadFavoritePaths(String connectionId) {
    return _pathHistoryStore.loadFavoritePaths(connectionId);
  }

  Future<SftpFavoritePathRecord?> findFavoritePath(
    String connectionId,
    String path,
  ) {
    return _pathHistoryStore.findFavoritePath(connectionId, path);
  }

  Future<SftpFavoritePathRecord> addFavoritePath(
    String connectionId,
    String path,
    String name,
  ) {
    return _pathHistoryStore.addFavoritePath(connectionId, path, name);
  }

  Future<void> removeFavoritePath(String id) {
    return _pathHistoryStore.removeFavoritePath(id);
  }

  @override
  Future<void> connect(String connectionId, {dynamic onUnknownHostKey}) =>
      _connectForConnection(connectionId, onUnknownHostKey: onUnknownHostKey);

  @override
  Future<void> refresh() async {
    final session = _activeSession;
    if (session == null) return;
    await _openPath(session, session.currentPath, bypassCache: true);
  }

  @override
  void cancelActiveTransfer() {
    _transferCancelGeneration++;
    final transfer = _activeTransfer;
    if (transfer != null) {
      _cancelTransferId = transfer.id;
      _activeTransfer = transfer.copyWith(isCancelled: true);
      notifyListeners();
    }
  }

  @override
  Future<void> uploadFile({
    required String localPath,
    required String filename,
  }) => _uploadFileImpl(localPath: localPath, filename: filename);

  @override
  Future<void> downloadFile(
    SftpEntry entry, {
    required String localPath,
    int maxBytes = SftpService.maxDownloadBytes,
  }) => _downloadFileImpl(entry, localPath: localPath, maxBytes: maxBytes);

  @override
  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  }) => _uploadBytesImpl(filename: filename, bytes: bytes);

  @override
  Future<void> deleteEntry(SftpEntry entry, {required String confirmedName}) =>
      _deleteEntryImpl(entry, confirmedName: confirmedName);

  Future<Uint8List> downloadBytes(
    SftpEntry entry, {
    int maxBytes = SftpService.maxDownloadBytes,
    bool updateState = false,
    bool bypassCache = false,
  }) => _downloadBytesImpl(
    entry,
    maxBytes: maxBytes,
    updateState: updateState,
    bypassCache: bypassCache,
  );

  Future<String> readTextFile(
    SftpEntry entry, {
    int maxBytes = SftpService.maxTextEditBytes,
  }) => _readTextFileImpl(entry, maxBytes: maxBytes);

  Future<void> saveTextFile(
    SftpEntry entry,
    String text, {
    int maxBytes = SftpService.maxTextEditBytes,
  }) => _saveTextFileImpl(entry, text, maxBytes: maxBytes);

  @override
  Future<void> openPath(String path) async {
    final session = _activeSession;
    if (session == null) return;
    return _openPath(session, path);
  }

  @override
  Future<List<SftpEntry>> listDirectoryForConnection(
    String connectionId,
    String path,
  ) => _listDirectoryForConnectionImpl(connectionId, path);

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = maxTextPreviewBytes,
  }) => _readTextPathForConnectionImpl(
    connectionId: connectionId,
    path: path,
    maxBytes: maxBytes,
  );

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = maxDownloadBytes,
  }) => _downloadPathForConnectionImpl(
    connectionId: connectionId,
    path: path,
    maxBytes: maxBytes,
  );

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = maxTextEditBytes,
  }) => _writeTextPathForConnectionImpl(
    connectionId: connectionId,
    path: path,
    text: text,
    maxBytes: maxBytes,
  );

  @override
  Future<SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  }) => _statPathForConnectionImpl(connectionId: connectionId, path: path);

  @override
  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = maxUploadBytes,
  }) => _uploadBytesPathForConnectionImpl(
    connectionId: connectionId,
    path: path,
    bytes: bytes,
    maxBytes: maxBytes,
  );

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) => _createDirectoryPathForConnectionImpl(
    connectionId: connectionId,
    path: path,
  );

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) => _renamePathForConnectionImpl(
    connectionId: connectionId,
    path: path,
    newPath: newPath,
  );

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) => _deletePathForConnectionImpl(connectionId: connectionId, path: path);

  @override
  Future<void> openParent() {
    final path = currentPath;
    if (path == '/' || path.isEmpty) return refresh();
    final trimmed = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final slash = trimmed.lastIndexOf('/');
    if (slash <= 0) return openPath('/');
    return openPath(trimmed.substring(0, slash));
  }

  @override
  Future<void> disconnect({bool notify = true}) =>
      _disconnectCurrent(notify: notify);

  @override
  Future<void> disconnectConnection(
    String connectionId, {
    bool notify = true,
    bool forgetPath = false,
  }) => _disconnectId(connectionId, notify: notify, forgetPath: forgetPath);

  @override
  Future<void> disconnectAll({bool notify = true}) =>
      _disconnectEvery(notify: notify);
  @override
  void notifyListeners() {
    if (_disposed) return;
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(_notifyCoalesceDelay, () {
      _notifyTimer = null;
      if (!_disposed) super.notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    _directoryCache.clear();
    unawaited(disconnectAll(notify: false));
    super.dispose();
  }

  void notify() {
    notifyListeners();
  }
}
