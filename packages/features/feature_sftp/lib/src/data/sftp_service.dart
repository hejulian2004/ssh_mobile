// SFTP Feature 的 Route/Module 级服务门面。
//
// 该门面只持有注入的后端和路径 Repository，不创建 SSH Manager、Database
// 或全局单例。当前 App Shell 的后端仍是旧 SftpService 兼容适配器，后续
// 清理旧 services 时可以只替换适配器，不改变 UI 和 Feature API。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart';

import '../domain/sftp_document.dart';
import '../domain/sftp_models.dart';
import '../domain/sftp_ports.dart';
import 'sftp_document_transfer.dart';

part 'sftp_service_documents.dart';

/// SFTP 文件大小限制，集中归属 SFTP Feature，避免 UI/Service 各自硬编码。
abstract final class SftpLimits {
  static const int textEditBytes = 512 * 1024;
  static const int textPreviewBytes = 2 * 1024 * 1024;
  static const int richPreviewBytes = 20 * 1024 * 1024;
  static const int uploadBytes = 50 * 1024 * 1024;
  static const int downloadBytes = 512 * 1024 * 1024;
}

/// SFTP Feature 的注入式操作门面。
final class SftpService extends ChangeNotifier
    implements SftpClientAdapter, SftpContentPort {
  /// 创建依赖注入式 SFTP 服务。
  SftpService({
    required SftpBackend backend,
    required SftpPathHistoryRepository historyRepository,
    required SshSessionManager sshSessionManager,
    Directory Function()? documentSpillDirectory,
  }) : this._(
         backend,
         historyRepository,
         sshSessionManager,
         documentSpillDirectory,
       );

  SftpService._(
    this._backend,
    this._historyRepository,
    this._sshSessionManager,
    this._documentSpillDirectory,
  ) {
    _backend.addListener(_forwardBackendChanged);
  }

  final SftpBackend _backend;
  final SftpPathHistoryRepository _historyRepository;
  final SshSessionManager _sshSessionManager;
  final Directory Function()? _documentSpillDirectory;
  bool _disposed = false;
  bool _documentCancelled = false;
  SftpTransferState? _documentTransfer;
  _SftpDocumentReadLease? _documentReadLease;
  _SftpDocumentWriteLease? _documentWriteLease;
  bool _documentBackendActive = false;
  final _documentSettlements = <Future<void>>{};
  Future<void>? _closeFuture;

  /// 文本编辑上限，保留旧调用面的命名以减少迁移期间行为差异。
  static const int maxTextEditBytes = SftpLimits.textEditBytes;

  /// 文本预览上限。
  static const int maxTextPreviewBytes = SftpLimits.textPreviewBytes;

  /// 富预览上限。
  static const int maxRichPreviewBytes = SftpLimits.richPreviewBytes;

  /// 上传上限。
  static const int maxUploadBytes = SftpLimits.uploadBytes;

  /// 下载上限。
  static const int maxDownloadBytes = SftpLimits.downloadBytes;

  /// 内存型传输上限。
  static const int maxInMemoryTransferBytes = maxDownloadBytes;

  @override
  String? get connectionId => _backend.connectionId;

  @override
  String? get connectionName => _backend.connectionName;

  @override
  String get currentPath => _backend.currentPath;

  @override
  SftpConnectionState get state => _backend.state;

  @override
  String? get errorMessage => _backend.errorMessage;

  @override
  int get entriesRevision => _backend.entriesRevision;

  @override
  List<SftpEntry> get entries => _backend.entries;

  @override
  bool get isConnected => _backend.isConnected;

  @override
  bool get isBusy => _documentTransfer != null || _backend.isBusy;

  @override
  SftpTransferState? get activeTransfer =>
      _backend.activeTransfer ?? _documentTransfer;

  @override
  bool get hasActiveTransfer =>
      _documentTransfer != null || _backend.hasActiveTransfer;

  @override
  bool isConnectionBusy(String id) => _backend.isConnectionBusy(id);

  @override
  bool isConnectionOpen(String id) => _backend.isConnectionOpen(id);

  /// 连接前确保使用 App Scope 的 SSH Manager；服务本身不创建 Manager。
  @override
  Future<void> connect(
    String id, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    await _sshSessionManager.ensureInitialized();
    await _backend.connect(id, onUnknownHostKey: onUnknownHostKey);
    await _recordCurrentPath(id);
  }

  @override
  Future<void> refresh() => _backend.refresh();

  @override
  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  }) => _backend.uploadBytes(filename: filename, bytes: bytes);

  @override
  Future<void> uploadFile({
    required String localPath,
    required String filename,
  }) => _backend.uploadFile(localPath: localPath, filename: filename);

  SftpDocumentUploadTarget get documentUploadTarget => _captureDocumentTarget();

  Future<void> uploadFromDocument({
    required SftpDocumentSource source,
    required String filename,
    SftpDocumentUploadTarget? target,
    int maxBytes = maxUploadBytes,
  }) =>
      _trackDocument(() => _uploadDocument(source, filename, target, maxBytes));

  Future<void> downloadToDocument({
    required SftpEntry entry,
    required SftpDocumentSink sink,
    int maxBytes = maxDownloadBytes,
  }) => _trackDocument(() => _downloadDocument(entry, sink, maxBytes));

  Future<void> _trackDocument(Future<void> Function() run) {
    // Register before running: a listener may synchronously start shutdown.
    final settled = Completer<void>();
    _documentSettlements.add(settled.future);
    final operation = Future<void>.sync(run);
    void complete() {
      _documentSettlements.remove(settled.future);
      settled.complete();
    }

    unawaited(
      operation.then<void>(
        (_) {
          complete();
        },
        onError: (Object error, StackTrace stack) {
          complete();
        },
      ),
    );
    return operation;
  }

  @override
  Future<void> deleteEntry(SftpEntry entry, {required String confirmedName}) =>
      _backend.deleteEntry(entry, confirmedName: confirmedName);

  @override
  Future<List<SftpEntry>> listDirectoryForConnection(String id, String path) =>
      _backend.listDirectoryForConnection(id, path);

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = maxTextPreviewBytes,
  }) => _backend.readTextPathForConnection(
    connectionId: connectionId,
    path: path,
    maxBytes: maxBytes,
  );

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = maxDownloadBytes,
  }) => _backend.downloadPathForConnection(
    connectionId: connectionId,
    path: path,
    maxBytes: maxBytes,
  );

  @override
  Future<void> downloadFile(
    SftpEntry entry, {
    required String localPath,
    int maxBytes = maxDownloadBytes,
  }) => _backend.downloadFile(entry, localPath: localPath, maxBytes: maxBytes);

  @override
  Future<SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  }) => _backend.statPathForConnection(connectionId: connectionId, path: path);

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = maxTextEditBytes,
  }) => _backend.writeTextPathForConnection(
    connectionId: connectionId,
    path: path,
    text: text,
    maxBytes: maxBytes,
  );

  @override
  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = maxUploadBytes,
  }) => _backend.uploadBytesPathForConnection(
    connectionId: connectionId,
    path: path,
    bytes: bytes,
    maxBytes: maxBytes,
  );

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) => _backend.createDirectoryPathForConnection(
    connectionId: connectionId,
    path: path,
  );

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) => _backend.renamePathForConnection(
    connectionId: connectionId,
    path: path,
    newPath: newPath,
  );

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) =>
      _backend.deletePathForConnection(connectionId: connectionId, path: path);

  @override
  Future<void> openPath(String path) async {
    await _backend.openPath(path);
    final id = connectionId;
    if (id != null) await _recordCurrentPath(id);
  }

  @override
  Future<void> openParent() => _backend.openParent();

  @override
  Future<void> disconnect({bool notify = true}) =>
      _backend.disconnect(notify: notify);

  @override
  Future<void> disconnectConnection(
    String id, {
    bool notify = true,
    bool forgetPath = false,
  }) =>
      _backend.disconnectConnection(id, notify: notify, forgetPath: forgetPath);

  @override
  Future<void> disconnectAll({bool notify = true}) =>
      _backend.disconnectAll(notify: notify);

  @override
  void cancelActiveTransfer() {
    _cancelDocument();
    _backend.cancelActiveTransfer();
  }

  /// 读取模块自己的最近路径记录。
  Future<List<SftpRecentPathRecord>> loadRecentPaths({int limit = 30}) async {
    final id = connectionId;
    if (id == null) return const [];
    return _historyRepository.loadRecentPaths(id, limit: limit);
  }

  /// 读取模块自己的收藏路径记录。
  Future<List<SftpFavoritePathRecord>> loadFavoritePaths() async {
    final id = connectionId;
    if (id == null) return const [];
    return _historyRepository.loadFavoritePaths(id);
  }

  /// 查询当前连接下指定收藏路径。
  Future<SftpFavoritePathRecord?> findFavoritePath(String path) async {
    final id = connectionId;
    if (id == null) return null;
    return _historyRepository.findFavoritePath(id, path);
  }

  /// 新增或更新当前连接下的收藏路径。
  Future<SftpFavoritePathRecord> addFavoritePath(
    String path,
    String name,
  ) async {
    final id = connectionId;
    if (id == null) throw StateError('SFTP is not connected');
    return _historyRepository.addFavoritePath(id, path, name);
  }

  /// 删除收藏路径。
  Future<void> removeFavoritePath(String id) =>
      _historyRepository.removeFavoritePath(id);

  @override
  Future<Uint8List> downloadBytes(
    SftpEntry entry, {
    int maxBytes = maxDownloadBytes,
    bool updateState = false,
    bool bypassCache = false,
  }) => _backend.downloadBytes(
    entry,
    maxBytes: maxBytes,
    updateState: updateState,
    bypassCache: bypassCache,
  );

  @override
  Future<String> readTextFile(
    SftpEntry entry, {
    int maxBytes = maxTextPreviewBytes,
  }) => _backend.readTextFile(entry, maxBytes: maxBytes);

  @override
  Future<void> saveTextFile(
    SftpEntry entry,
    String text, {
    int maxBytes = maxTextEditBytes,
  }) => _backend.saveTextFile(entry, text, maxBytes: maxBytes);

  Future<void> _recordCurrentPath(String id) {
    final path = currentPath.trim();
    if (path.isEmpty) return Future<void>.value();
    return _historyRepository.recordVisitedPath(id, path);
  }

  void _forwardBackendChanged() {
    if (!_disposed) notifyListeners();
  }

  /// Stops new document work and drains every accepted attempt's cleanup.
  /// The borrowed backend and SSH manager remain owned by AppRuntime.
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final completion = Completer<void>();
    _closeFuture = completion.future;
    try {
      dispose();
      unawaited(
        Future.wait<void>(_documentSettlements.toList()).then<void>(
          (_) {
            completion.complete();
          },
          onError: (Object error, StackTrace stack) {
            completion.completeError(error, stack);
          },
        ),
      );
    } catch (error, stack) {
      completion.completeError(error, stack);
    }
    return completion.future;
  }

  /// 释放本服务的监听；后端和 SSH 资源由上层 Owner 释放。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelDocument();
    if (_documentBackendActive) _backend.cancelActiveTransfer();
    _backend.removeListener(_forwardBackendChanged);
    super.dispose();
  }
}
