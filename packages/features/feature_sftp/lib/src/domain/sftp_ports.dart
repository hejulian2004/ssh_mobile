// SFTP Feature 的跨层 Port 与 Capability Contract。
//
// 业务包只依赖这些契约，不读取 AppSettings、统一存储门面或 Connection
// ViewModel 或其他 Feature 的实现。具体适配器由 App Shell 注入。

import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart';

import 'sftp_models.dart';

/// SFTP 连接目录及排序能力。
abstract interface class SftpConnectionCatalogPort implements Listenable {
  bool get isLoading;
  List<SftpConnectionInfo> get connections;
  Future<void> reorderConnections(int oldIndex, int newIndex);
}

/// SFTP 相关设置的最小读写契约。
abstract interface class SftpSettingsPort implements Listenable {
  SftpLanguage get language;
  int get sftpDownloadLimitBytes;
  int get sftpTextPreviewLimitBytes;
  int get sftpRichPreviewLimitBytes;
  int get sftpTextEditLimitBytes;

  Future<void> setSftpDownloadLimitBytes(int bytes);
  Future<void> setSftpTextPreviewLimitBytes(int bytes);
  Future<void> setSftpRichPreviewLimitBytes(int bytes);
  Future<void> setSftpTextEditLimitBytes(int bytes);
}

/// SFTP 设置页允许用户调整的边界，避免 UI 重复硬编码业务范围。
abstract final class SftpSettingsLimits {
  static const int minBytes = 64 * 1024;
  static const int maxBytes = 2 * 1024 * 1024 * 1024;
}

/// App Shell 注入的日志能力；Feature 不直接访问全局日志单例。
abstract interface class SftpLoggerPort {
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  });
}

/// App Shell 的 Host Key 确认 UI 能力。
abstract interface class SftpHostKeyConfirmationPort {
  Future<bool> confirm(SshHostKeyPromptRequest request);
}

/// 旧 SFTP 服务与新 Feature 之间的兼容后端契约。
///
/// 后端由 App Scope 创建，Feature 不拥有它的 SSH Manager 或连接资源；
/// Module 只通过 [SshSessionManager] 共享初始化和生命周期边界。
abstract interface class SftpBackend
    implements SftpClientAdapter, SftpContentPort {
  /// Active SSH target still matching the saved config, even for an empty directory.
  /// Null for a missing or rebound target.
  String? get targetFingerprint;
  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);
}

/// 面向工具和预览的额外内容操作。
abstract interface class SftpContentPort {
  Future<Uint8List> downloadBytes(
    SftpEntry entry, {
    int maxBytes,
    bool updateState,
    bool bypassCache,
  });

  Future<String> readTextFile(SftpEntry entry, {int maxBytes});

  Future<void> saveTextFile(SftpEntry entry, String text, {int maxBytes});
}

/// SFTP 客户端展示和基础操作契约。
abstract interface class SftpClientAdapter {
  String? get connectionId;
  String? get connectionName;
  String get currentPath;
  SftpConnectionState get state;
  String? get errorMessage;
  int get entriesRevision;
  List<SftpEntry> get entries;
  bool get isConnected;
  bool get isBusy;
  SftpTransferState? get activeTransfer;
  bool get hasActiveTransfer;

  bool isConnectionBusy(String connectionId);
  bool isConnectionOpen(String connectionId);

  Future<void> connect(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  });

  Future<void> refresh();

  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  });
  Future<void> uploadFile({
    required String localPath,
    required String filename,
  });

  Future<void> deleteEntry(SftpEntry entry, {required String confirmedName});

  Future<List<SftpEntry>> listDirectoryForConnection(
    String connectionId,
    String path,
  );

  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes,
  });

  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes,
  });

  Future<void> downloadFile(
    SftpEntry entry, {
    required String localPath,
    int maxBytes,
  });

  Future<SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  });

  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes,
  });

  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes,
  });

  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  });

  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  });

  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  });

  Future<void> openPath(String path);
  Future<void> openParent();
  Future<void> disconnect({bool notify = true});
  Future<void> disconnectConnection(
    String connectionId, {
    bool notify = true,
    bool forgetPath = false,
  });
  Future<void> disconnectAll({bool notify = true});
  void cancelActiveTransfer();
}

/// Module 内部访问的路径历史 Repository。
abstract interface class SftpPathHistoryRepository {
  Future<void> recordVisitedPath(String connectionId, String path);
  Future<List<SftpRecentPathRecord>> loadRecentPaths(
    String connectionId, {
    int limit,
  });
  Future<SftpFavoritePathRecord> addFavoritePath(
    String connectionId,
    String path,
    String name,
  );
  Future<void> removeFavoritePath(String id);
  Future<void> renameFavoritePath(String id, String name);
  Future<List<SftpFavoritePathRecord>> loadFavoritePaths(String connectionId);
  Future<SftpFavoritePathRecord?> findFavoritePath(
    String connectionId,
    String path,
  );
}

/// SFTP UI 支持的语言，避免 Feature 依赖 AppSettings 的枚举。
enum SftpLanguage { chinese, english }
