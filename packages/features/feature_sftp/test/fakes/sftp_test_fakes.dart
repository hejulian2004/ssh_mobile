// SFTP Feature 测试替身。
//
// Fake 不创建真实 SSH、文件或平台数据库资源，只用于验证 Module、Service
// 和 Repository 的依赖注入及生命周期行为。

import 'package:flutter/foundation.dart';
import 'package:feature_sftp/feature_sftp.dart';
import 'package:ssh_core/ssh_core.dart';

/// 可控的 SFTP 后端 Fake。
final class FakeSftpBackend extends ChangeNotifier implements SftpBackend {
  @override
  String? targetFingerprint = 'fingerprint';
  @override
  String? connectionId;

  @override
  String? connectionName;

  @override
  String currentPath = '.';

  @override
  SftpConnectionState state = SftpConnectionState.disconnected;

  @override
  String? errorMessage;

  @override
  int entriesRevision = 0;

  @override
  List<SftpEntry> entries = const [];

  @override
  bool isConnected = false;

  @override
  bool isBusy = false;

  @override
  SftpTransferState? activeTransfer;

  @override
  bool get hasActiveTransfer => activeTransfer != null;

  final Set<String> openConnectionIds = <String>{};

  @override
  bool isConnectionBusy(String id) => id == connectionId && isBusy;

  @override
  bool isConnectionOpen(String id) => openConnectionIds.contains(id);

  @override
  Future<void> connect(
    String id, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    connectionId = id;
    connectionName = 'Test connection';
    state = SftpConnectionState.connected;
    isConnected = true;
    openConnectionIds.add(id);
    notifyListeners();
  }

  @override
  Future<void> refresh() async {
    entriesRevision++;
    notifyListeners();
  }

  @override
  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  }) async {}

  /// 测试观察实际上传。未设置时保持空操作。
  Future<void> Function({required String localPath, required String filename})?
  onUploadFile;

  /// 测试观察实际下载。未设置时保持空操作。
  Future<void> Function(
    SftpEntry entry, {
    required String localPath,
    required int maxBytes,
  })?
  onDownloadFile;

  @override
  Future<void> uploadFile({
    required String localPath,
    required String filename,
  }) async {
    await onUploadFile?.call(localPath: localPath, filename: filename);
  }

  @override
  Future<void> deleteEntry(
    SftpEntry entry, {
    required String confirmedName,
  }) async {}

  @override
  Future<List<SftpEntry>> listDirectoryForConnection(
    String id,
    String path,
  ) async => entries;

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = SftpService.maxTextPreviewBytes,
  }) async => '';

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = SftpService.maxDownloadBytes,
  }) async => Uint8List(0);

  @override
  Future<void> downloadFile(
    SftpEntry entry, {
    required String localPath,
    int maxBytes = SftpService.maxDownloadBytes,
  }) async {
    await onDownloadFile?.call(entry, localPath: localPath, maxBytes: maxBytes);
  }

  @override
  Future<SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  }) async => SftpPathInfo(
    path: path,
    isDirectory: false,
    isLink: false,
    size: 0,
    sizeLabel: '0 B',
    modifiedAt: null,
  );

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = SftpService.maxTextEditBytes,
  }) async {}

  @override
  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = SftpService.maxUploadBytes,
  }) async {}

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) async {}

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) async {}

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) async {}

  @override
  Future<void> openPath(String path) async {
    currentPath = path;
    notifyListeners();
  }

  @override
  Future<void> openParent() async {}

  @override
  Future<void> disconnect({bool notify = true}) async {
    if (connectionId != null) openConnectionIds.remove(connectionId);
    connectionId = null;
    connectionName = null;
    isConnected = false;
    state = SftpConnectionState.disconnected;
    if (notify) notifyListeners();
  }

  @override
  Future<void> disconnectConnection(
    String id, {
    bool notify = true,
    bool forgetPath = false,
  }) async {
    openConnectionIds.remove(id);
    if (connectionId == id) await disconnect(notify: notify);
  }

  @override
  Future<void> disconnectAll({bool notify = true}) async {
    openConnectionIds.clear();
    await disconnect(notify: notify);
  }

  @override
  void cancelActiveTransfer() {
    onCancelTransfer?.call();
    activeTransfer = null;
    notifyListeners();
  }

  VoidCallback? onCancelTransfer;

  @override
  Future<Uint8List> downloadBytes(
    SftpEntry entry, {
    int maxBytes = SftpService.maxDownloadBytes,
    bool updateState = false,
    bool bypassCache = false,
  }) async => Uint8List(0);

  @override
  Future<String> readTextFile(
    SftpEntry entry, {
    int maxBytes = SftpService.maxTextPreviewBytes,
  }) async => '';

  @override
  Future<void> saveTextFile(
    SftpEntry entry,
    String text, {
    int maxBytes = SftpService.maxTextEditBytes,
  }) async {}
}

/// 只记录初始化和关闭次数的 SSH Manager Fake。
final class FakeSshSessionManager implements SshSessionManager {
  int ensureInitializedCalls = 0;
  int closeCalls = 0;

  @override
  SshTerminalCapability? get terminalCapability => null;

  @override
  bool initialized = false;

  @override
  Future<void> ensureInitialized() async {
    ensureInitializedCalls++;
    initialized = true;
  }

  @override
  Future<SshSessionLease> acquire({
    required String sessionId,
    required Future<SshSession> Function() create,
  }) {
    throw UnsupportedError('The SFTP tests do not acquire SSH leases.');
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}
