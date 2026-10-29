import 'dart:async';
import 'package:connection_core/connection_core.dart';
import 'package:app_core/app_core.dart';
import 'package:flutter/foundation.dart';
import '../sftp_service.dart';
import '../sftp_path_history_store.dart';

class SftpService extends ChangeNotifier implements SftpClientAdapter {
  String? get targetFingerprint => null;
  static const int maxTextEditBytes = 512 * 1024;
  static const int maxTextPreviewBytes = 2 * 1024 * 1024;
  static const int maxRichPreviewBytes = 20 * 1024 * 1024;
  static const int maxUploadBytes = 50 * 1024 * 1024;
  static const int maxDownloadBytes = 512 * 1024 * 1024;
  static const int maxInMemoryTransferBytes = maxDownloadBytes;
  static const Duration _defaultTelemetryFailureTimeout = Duration(
    milliseconds: 250,
  );

  SftpService({
    required ConnectionRepository connectionRepository,
    required CredentialRepository credentialRepository,
    required HostKeyRepository hostKeyRepository,
    SftpPathHistoryStore? pathHistoryStore,
    dynamic nativeStreamConnector,
    dynamic peerIdResolver,
    this.telemetryClient,
    Duration telemetryFailureTimeout = _defaultTelemetryFailureTimeout,
  });

  /// 可选遥测客户端；桌面/移动 IO 实现使用，Web stub 仅持有该字段保持一致。
  TelemetryClient? telemetryClient;

  String? _activeConnectionId;
  SftpConnectionState _state = SftpConnectionState.disconnected;
  String? _errorMessage;

  @override
  String? get connectionId => _activeConnectionId;

  @override
  String? get connectionName => null;

  @override
  String get currentPath => '.';

  @override
  SftpConnectionState get state => _state;

  @override
  String? get errorMessage => _errorMessage;

  @override
  int get entriesRevision => 0;

  @override
  List<SftpEntry> get entries => const [];

  @override
  bool get isConnected => false;
  dynamic getSftpClientForConnection(String connectionId) => null;

  @override
  bool get isBusy => false;

  @override
  SftpTransferState? get activeTransfer => null;

  @override
  bool get hasActiveTransfer => false;

  @override
  bool isConnectionBusy(String connectionId) => false;

  @override
  bool isConnectionOpen(String connectionId) => false;

  @override
  Future<void> connect(String connectionId, {dynamic onUnknownHostKey}) async {
    _activeConnectionId = connectionId;
    _state = SftpConnectionState.error;
    _errorMessage =
        'Web 浏览器由于沙盒安全限制，不支持直接建立 TCP Socket 传输。因此无法在此使用 SFTP 文件管理功能。\n\nWeb browsers do not support direct TCP connections due to sandbox constraints. SFTP file management is not supported.';
    notifyListeners();
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<void> uploadFile({
    required String localPath,
    required String filename,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<void> deleteEntry(
    SftpEntry entry, {
    required String confirmedName,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<List<SftpEntry>> listDirectoryForConnection(
    String connectionId,
    String path,
  ) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = 2 * 1024 * 1024,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = 512 * 1024 * 1024,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<void> downloadFile(
    SftpEntry entry, {
    required String localPath,
    int maxBytes = 512 * 1024 * 1024,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = 512 * 1024,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = 50 * 1024 * 1024,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  @override
  Future<void> openPath(String path) async {}

  @override
  Future<void> openParent() async {}

  @override
  Future<void> disconnect({bool notify = true}) async {}

  @override
  Future<void> disconnectConnection(
    String connectionId, {
    bool notify = true,
    bool forgetPath = false,
  }) async {}

  @override
  Future<void> disconnectAll({bool notify = true}) async {}

  @override
  void cancelActiveTransfer() {}

  Future<List<SftpRecentPathRecord>> loadRecentPaths(
    String connectionId, {
    int limit = 30,
  }) async {
    return const [];
  }

  Future<List<SftpFavoritePathRecord>> loadFavoritePaths(
    String connectionId,
  ) async {
    return const [];
  }

  Future<SftpFavoritePathRecord?> findFavoritePath(
    String connectionId,
    String path,
  ) async {
    return null;
  }

  Future<SftpFavoritePathRecord> addFavoritePath(
    String connectionId,
    String path,
    String name,
  ) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  Future<void> removeFavoritePath(String id) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  Future<Uint8List> downloadBytes(
    SftpEntry entry, {
    int maxBytes = maxDownloadBytes,
    bool updateState = false,
    bool bypassCache = false,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  Future<String> readTextFile(
    SftpEntry entry, {
    int maxBytes = maxTextPreviewBytes,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }

  Future<void> saveTextFile(
    SftpEntry entry,
    String text, {
    int maxBytes = 512 * 1024,
  }) async {
    throw UnsupportedError('SFTP is not supported on Web');
  }
}
