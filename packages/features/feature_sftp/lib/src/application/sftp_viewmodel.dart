// SFTP Route Scope 的 ViewModel。
//
// ViewModel 只转发用户操作和只读状态，不创建 SFTP Service/SSH 连接；页面
// 销毁时由 Provider 调用 dispose，Service 和 sftp.db 由 SftpModule 管理。

import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart';

import '../data/sftp_service.dart';
import '../domain/sftp_document.dart';
import '../domain/sftp_models.dart';

/// SFTP 页面状态协调器。
final class SftpViewModel extends ChangeNotifier {
  /// 注入 Module 创建的 Route Service。
  SftpViewModel(this._sftpService) {
    _sftpService.addListener(_forwardServiceChanged);
  }

  final SftpService _sftpService;
  bool _disposed = false;

  String? get connectionId => _sftpService.connectionId;
  String? get connectionName => _sftpService.connectionName;
  String get currentPath => _sftpService.currentPath;
  SftpConnectionState get state => _sftpService.state;
  String? get errorMessage => _sftpService.errorMessage;
  int get entriesRevision => _sftpService.entriesRevision;
  List<SftpEntry> get entries => _sftpService.entries;
  bool get isConnected => _sftpService.isConnected;
  bool get isBusy => _sftpService.isBusy;
  SftpTransferState? get activeTransfer => _sftpService.activeTransfer;
  bool get hasActiveTransfer => _sftpService.hasActiveTransfer;

  bool isConnectionBusy(String id) => _sftpService.isConnectionBusy(id);
  bool isConnectionOpen(String id) => _sftpService.isConnectionOpen(id);

  Future<List<SftpRecentPathRecord>> loadRecentPaths({int limit = 30}) =>
      _sftpService.loadRecentPaths(limit: limit);

  Future<List<SftpFavoritePathRecord>> loadFavoritePaths() =>
      _sftpService.loadFavoritePaths();

  Future<SftpFavoritePathRecord?> findFavoritePath(String path) =>
      _sftpService.findFavoritePath(path);

  Future<SftpFavoritePathRecord> addFavoritePath(String path, String name) =>
      _sftpService.addFavoritePath(path, name);

  Future<void> removeFavoritePath(String id) =>
      _sftpService.removeFavoritePath(id);

  Future<void> connect(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) => _sftpService.connect(connectionId, onUnknownHostKey: onUnknownHostKey);

  Future<void> disconnect() => _sftpService.disconnect();
  Future<void> openPath(String path) => _sftpService.openPath(path);
  Future<void> openParent() => _sftpService.openParent();
  Future<void> refresh() => _sftpService.refresh();

  Future<void> retry({SshHostKeyConfirmation? onUnknownHostKey}) async {
    final activeConnectionId = connectionId;
    if (activeConnectionId != null && !isConnected) {
      await connect(activeConnectionId, onUnknownHostKey: onUnknownHostKey);
      return;
    }
    await refresh();
  }

  Future<void> uploadLocalFile({
    required String localPath,
    required String filename,
    required int sizeBytes,
  }) => _sftpService.uploadFile(localPath: localPath, filename: filename);

  Future<void> downloadToLocalFile({
    required SftpEntry entry,
    required String localPath,
    required int maxBytes,
  }) => _sftpService.downloadFile(
    entry,
    localPath: localPath,
    maxBytes: maxBytes,
  );

  /// 上传一个系统文档。超限时不会写远端。
  SftpDocumentUploadTarget get documentUploadTarget =>
      _sftpService.documentUploadTarget;

  Future<void> uploadFromDocument({
    required SftpDocumentSource source,
    required String filename,
    SftpDocumentUploadTarget? target,
    int maxBytes = SftpLimits.uploadBytes,
  }) => _sftpService.uploadFromDocument(
    source: source,
    filename: filename,
    target: target,
    maxBytes: maxBytes,
  );

  /// 把远端文件写入用户选择的文档。
  Future<void> downloadToDocument({
    required SftpEntry entry,
    required SftpDocumentSink sink,
    required int maxBytes,
  }) => _sftpService.downloadToDocument(
    entry: entry,
    sink: sink,
    maxBytes: maxBytes,
  );

  void cancelActiveTransfer() => _sftpService.cancelActiveTransfer();

  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  }) {
    if (bytes.length > SftpLimits.uploadBytes) {
      throw StateError('File exceeds max upload size of 50MB');
    }
    return _sftpService.uploadBytes(filename: filename, bytes: bytes);
  }

  Future<void> deleteEntry(SftpEntry entry, {required String confirmedName}) =>
      _sftpService.deleteEntry(entry, confirmedName: confirmedName);

  Future<Uint8List> downloadBytes(
    SftpEntry entry, {
    int maxBytes = SftpLimits.downloadBytes,
    bool updateState = false,
    bool bypassCache = false,
  }) => _sftpService.downloadBytes(
    entry,
    maxBytes: maxBytes,
    updateState: updateState,
    bypassCache: bypassCache,
  );

  Future<String> readTextFile(SftpEntry entry, {required int maxBytes}) =>
      _sftpService.readTextFile(entry, maxBytes: maxBytes);

  Future<void> saveTextFile(
    SftpEntry entry,
    String content, {
    required int maxBytes,
  }) => _sftpService.saveTextFile(entry, content, maxBytes: maxBytes);

  void _forwardServiceChanged() {
    if (!_disposed) notifyListeners();
  }

  /// 取消 Service 监听；不释放 Module 拥有的数据库。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sftpService.removeListener(_forwardServiceChanged);
    super.dispose();
  }
}
