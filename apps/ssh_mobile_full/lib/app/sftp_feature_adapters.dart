// SFTP Feature 的 App Shell 适配器与路由 Module Scope。
//
// 兼容后端暂时仍由 AppRuntime 持有；本文件只负责把旧服务转换为 Feature
// Port，并在 SFTP 路由激活时创建和释放 feature-owned 的 sftp.db。

import 'dart:async';
import 'dart:typed_data';

import 'package:app_core/app_core.dart';
import 'package:app_ui/app_ui.dart';
import 'package:feature_connection/feature_connection.dart'
    as feature_connection;
import 'package:feature_sftp/feature_sftp.dart' as feature_sftp;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../core/services/ssh_host_key_policy.dart' as legacy_ssh;
import 'app_runtime.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/sftp_service.dart' as legacy_sftp;
import '../widgets/ssh_host_key_trust_dialog.dart';

/// 将 AppSettings 转换为 SFTP Feature 的最小设置 Port。
final class AppSftpSettingsAdapter extends ChangeNotifier
    implements feature_sftp.SftpSettingsPort {
  /// 创建适配器并监听 App Scope 设置。
  AppSftpSettingsAdapter(this._settings) {
    _settings.addListener(_forwardChanged);
  }

  final AppSettings _settings;
  bool _disposed = false;

  @override
  feature_sftp.SftpLanguage get language => _settings.language == AppLanguage.en
      ? feature_sftp.SftpLanguage.english
      : feature_sftp.SftpLanguage.chinese;

  @override
  int get sftpDownloadLimitBytes => _settings.sftpDownloadLimitBytes;

  @override
  int get sftpTextPreviewLimitBytes => _settings.sftpTextPreviewLimitBytes;

  @override
  int get sftpRichPreviewLimitBytes => _settings.sftpRichPreviewLimitBytes;

  @override
  int get sftpTextEditLimitBytes => _settings.sftpTextEditLimitBytes;

  @override
  Future<void> setSftpDownloadLimitBytes(int bytes) =>
      _settings.setSftpDownloadLimitBytes(bytes);

  @override
  Future<void> setSftpTextPreviewLimitBytes(int bytes) =>
      _settings.setSftpTextPreviewLimitBytes(bytes);

  @override
  Future<void> setSftpRichPreviewLimitBytes(int bytes) =>
      _settings.setSftpRichPreviewLimitBytes(bytes);

  @override
  Future<void> setSftpTextEditLimitBytes(int bytes) =>
      _settings.setSftpTextEditLimitBytes(bytes);

  void _forwardChanged() {
    if (!_disposed) notifyListeners();
  }

  /// 解除对 AppSettings 的监听；AppSettings 本身由 AppRuntime 释放。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _settings.removeListener(_forwardChanged);
    super.dispose();
  }
}

/// 将 Connection Feature 的连接列表转换为 SFTP 的只读展示 Port。
final class AppSftpConnectionCatalogAdapter extends ChangeNotifier
    implements feature_sftp.SftpConnectionCatalogPort {
  /// 创建适配器并转发 ConnectionViewModel 的列表变化。
  AppSftpConnectionCatalogAdapter(this._viewModel) {
    _viewModel?.addListener(_forwardChanged);
  }

  final feature_connection.ConnectionViewModel? _viewModel;
  bool _disposed = false;

  @override
  bool get isLoading => _viewModel?.isLoading ?? false;

  @override
  List<feature_sftp.SftpConnectionInfo> get connections =>
      _viewModel?.connections
          .map(
            (connection) => feature_sftp.SftpConnectionInfo(
              id: connection.id,
              name: connection.name,
              host: connection.host,
              port: connection.port,
              username: connection.username,
            ),
          )
          .toList(growable: false) ??
      const [];

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) =>
      _viewModel?.reorderConnections(oldIndex, newIndex) ?? Future.value();

  void _forwardChanged() {
    if (!_disposed) notifyListeners();
  }

  /// 解除对 ConnectionViewModel 的监听；连接 ViewModel 由 App Shell 持有。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _viewModel?.removeListener(_forwardChanged);
    super.dispose();
  }
}

/// 将 App Shell 的 Host Key 对话框转换为 SSH Core 提示契约。
final class AppSftpHostKeyConfirmationAdapter
    implements feature_sftp.SftpHostKeyConfirmationPort {
  /// 使用路由 Scope 的上下文打开确认对话框。
  AppSftpHostKeyConfirmationAdapter(this._contextProvider);

  final BuildContext Function() _contextProvider;

  @override
  Future<bool> confirm(ssh_core.SshHostKeyPromptRequest request) {
    final context = _contextProvider();
    return showSshHostKeyTrustDialog(context, _toLegacyPrompt(request));
  }

  legacy_ssh.SshHostKeyPromptRequest _toLegacyPrompt(
    ssh_core.SshHostKeyPromptRequest request,
  ) {
    return legacy_ssh.SshHostKeyPromptRequest(
      connectionId: request.connectionId,
      connectionName: request.connectionName,
      host: request.host,
      port: request.port,
      username: request.username,
      algorithm: request.algorithm,
      fingerprint: request.fingerprint,
    );
  }
}

/// 将 AppLogService 暴露为 SFTP Feature 的日志 Port。
final class AppSftpLoggerAdapter implements feature_sftp.SftpLoggerPort {
  /// 创建日志适配器。
  const AppSftpLoggerAdapter(this._logger);

  final AppLogService _logger;

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    _logger.error(
      message,
      error: error,
      stackTrace: stackTrace,
      details: details,
    );
  }
}

/// 把旧 SftpService 转换为 Feature 自有模型的兼容后端。
final class AppSftpBackendAdapter implements feature_sftp.SftpBackend {
  /// 创建不拥有旧服务的适配器；旧服务仍由 AppRuntime 负责关闭。
  AppSftpBackendAdapter(this._legacyService);

  final legacy_sftp.SftpService _legacyService;

  @override
  void addListener(VoidCallback listener) =>
      _legacyService.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _legacyService.removeListener(listener);

  @override
  String? get connectionId => _legacyService.connectionId;

  @override
  String? get targetFingerprint => _legacyService.targetFingerprint;

  @override
  String? get connectionName => _legacyService.connectionName;

  @override
  String get currentPath => _legacyService.currentPath;

  @override
  feature_sftp.SftpConnectionState get state =>
      feature_sftp.SftpConnectionState.values.byName(_legacyService.state.name);

  @override
  String? get errorMessage => _legacyService.errorMessage;

  @override
  int get entriesRevision => _legacyService.entriesRevision;

  @override
  List<feature_sftp.SftpEntry> get entries =>
      _legacyService.entries.map(_toFeatureEntry).toList(growable: false);

  @override
  bool get isConnected => _legacyService.isConnected;

  @override
  bool get isBusy => _legacyService.isBusy;

  @override
  feature_sftp.SftpTransferState? get activeTransfer {
    final transfer = _legacyService.activeTransfer;
    if (transfer == null) return null;
    return feature_sftp.SftpTransferState(
      id: transfer.id,
      name: transfer.name,
      totalBytes: transfer.totalBytes,
      isUpload: transfer.isUpload,
      bytesTransferred: transfer.bytesTransferred,
      isCancelled: transfer.isCancelled,
      isError: transfer.isError,
      errorMessage: transfer.errorMessage,
    );
  }

  @override
  bool get hasActiveTransfer => _legacyService.hasActiveTransfer;

  @override
  bool isConnectionBusy(String connectionId) =>
      _legacyService.isConnectionBusy(connectionId);

  @override
  bool isConnectionOpen(String connectionId) =>
      _legacyService.isConnectionOpen(connectionId);

  @override
  Future<void> connect(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) => _translate(() {
    final legacyCallback = onUnknownHostKey == null
        ? null
        : (dynamic request) async {
            final prompt = request as legacy_ssh.SshHostKeyPromptRequest;
            return onUnknownHostKey(_toCorePrompt(prompt));
          };
    return _legacyService.connect(
      connectionId,
      onUnknownHostKey: legacyCallback,
    );
  });

  @override
  Future<void> refresh() => _translate(_legacyService.refresh);

  @override
  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  }) => _translate(
    () => _legacyService.uploadBytes(filename: filename, bytes: bytes),
  );

  @override
  Future<void> uploadFile({
    required String localPath,
    required String filename,
  }) => _translate(
    () => _legacyService.uploadFile(localPath: localPath, filename: filename),
  );

  @override
  Future<void> deleteEntry(
    feature_sftp.SftpEntry entry, {
    required String confirmedName,
  }) => _translate(
    () => _legacyService.deleteEntry(
      _toLegacyEntry(entry),
      confirmedName: confirmedName,
    ),
  );

  @override
  Future<List<feature_sftp.SftpEntry>> listDirectoryForConnection(
    String connectionId,
    String path,
  ) => _translate(
    () async => (await _legacyService.listDirectoryForConnection(
      connectionId,
      path,
    )).map(_toFeatureEntry).toList(growable: false),
  );

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = feature_sftp.SftpService.maxTextPreviewBytes,
  }) => _translate(
    () => _legacyService.readTextPathForConnection(
      connectionId: connectionId,
      path: path,
      maxBytes: maxBytes,
    ),
  );

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = feature_sftp.SftpService.maxDownloadBytes,
  }) => _translate(
    () => _legacyService.downloadPathForConnection(
      connectionId: connectionId,
      path: path,
      maxBytes: maxBytes,
    ),
  );

  @override
  Future<void> downloadFile(
    feature_sftp.SftpEntry entry, {
    required String localPath,
    int maxBytes = feature_sftp.SftpService.maxDownloadBytes,
  }) => _translate(
    () => _legacyService.downloadFile(
      _toLegacyEntry(entry),
      localPath: localPath,
      maxBytes: maxBytes,
    ),
  );

  @override
  Future<feature_sftp.SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  }) => _translate(
    () async => _toFeaturePathInfo(
      await _legacyService.statPathForConnection(
        connectionId: connectionId,
        path: path,
      ),
    ),
  );

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = feature_sftp.SftpService.maxTextEditBytes,
  }) => _translate(
    () => _legacyService.writeTextPathForConnection(
      connectionId: connectionId,
      path: path,
      text: text,
      maxBytes: maxBytes,
    ),
  );

  @override
  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = feature_sftp.SftpService.maxUploadBytes,
  }) => _translate(
    () => _legacyService.uploadBytesPathForConnection(
      connectionId: connectionId,
      path: path,
      bytes: bytes,
      maxBytes: maxBytes,
    ),
  );

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) => _translate(
    () => _legacyService.createDirectoryPathForConnection(
      connectionId: connectionId,
      path: path,
    ),
  );

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) => _translate(
    () => _legacyService.renamePathForConnection(
      connectionId: connectionId,
      path: path,
      newPath: newPath,
    ),
  );

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) => _translate(
    () => _legacyService.deletePathForConnection(
      connectionId: connectionId,
      path: path,
    ),
  );

  @override
  Future<void> openPath(String path) =>
      _translate(() => _legacyService.openPath(path));

  @override
  Future<void> openParent() => _translate(_legacyService.openParent);

  @override
  Future<void> disconnect({bool notify = true}) =>
      _translate(() => _legacyService.disconnect(notify: notify));

  @override
  Future<void> disconnectConnection(
    String connectionId, {
    bool notify = true,
    bool forgetPath = false,
  }) => _translate(
    () => _legacyService.disconnectConnection(
      connectionId,
      notify: notify,
      forgetPath: forgetPath,
    ),
  );

  @override
  Future<void> disconnectAll({bool notify = true}) =>
      _translate(() => _legacyService.disconnectAll(notify: notify));

  @override
  void cancelActiveTransfer() => _legacyService.cancelActiveTransfer();

  @override
  Future<Uint8List> downloadBytes(
    feature_sftp.SftpEntry entry, {
    int maxBytes = feature_sftp.SftpService.maxDownloadBytes,
    bool updateState = false,
    bool bypassCache = false,
  }) => _translate(
    () => _legacyService.downloadBytes(
      _toLegacyEntry(entry),
      maxBytes: maxBytes,
      updateState: updateState,
      bypassCache: bypassCache,
    ),
  );

  @override
  Future<String> readTextFile(
    feature_sftp.SftpEntry entry, {
    int maxBytes = feature_sftp.SftpService.maxTextPreviewBytes,
  }) => _translate(
    () =>
        _legacyService.readTextFile(_toLegacyEntry(entry), maxBytes: maxBytes),
  );

  @override
  Future<void> saveTextFile(
    feature_sftp.SftpEntry entry,
    String text, {
    int maxBytes = feature_sftp.SftpService.maxTextEditBytes,
  }) => _translate(
    () => _legacyService.saveTextFile(
      _toLegacyEntry(entry),
      text,
      maxBytes: maxBytes,
    ),
  );

  feature_sftp.SftpEntry _toFeatureEntry(legacy_sftp.SftpEntry entry) {
    return feature_sftp.SftpEntry(
      connectionId: entry.connectionId,
      targetFingerprint: entry.targetFingerprint,
      name: entry.name,
      path: entry.path,
      lowerName: entry.lowerName,
      isDirectory: entry.isDirectory,
      isLink: entry.isLink,
      size: entry.size,
      sizeLabel: entry.sizeLabel,
      modifiedAt: entry.modifiedAt,
      modifiedLabel: entry.modifiedLabel,
    );
  }

  legacy_sftp.SftpEntry _toLegacyEntry(feature_sftp.SftpEntry entry) {
    return legacy_sftp.SftpEntry(
      connectionId: entry.connectionId,
      targetFingerprint: entry.targetFingerprint,
      name: entry.name,
      path: entry.path,
      lowerName: entry.lowerName,
      isDirectory: entry.isDirectory,
      isLink: entry.isLink,
      size: entry.size,
      sizeLabel: entry.sizeLabel,
      modifiedAt: entry.modifiedAt,
      modifiedLabel: entry.modifiedLabel,
    );
  }

  feature_sftp.SftpPathInfo _toFeaturePathInfo(legacy_sftp.SftpPathInfo info) {
    return feature_sftp.SftpPathInfo(
      path: info.path,
      isDirectory: info.isDirectory,
      isLink: info.isLink,
      size: info.size,
      sizeLabel: info.sizeLabel,
      modifiedAt: info.modifiedAt,
    );
  }

  ssh_core.SshHostKeyPromptRequest _toCorePrompt(
    legacy_ssh.SshHostKeyPromptRequest request,
  ) {
    return ssh_core.SshHostKeyPromptRequest(
      connectionId: request.connectionId,
      connectionName: request.connectionName,
      host: request.host,
      port: request.port,
      username: request.username,
      algorithm: request.algorithm,
      fingerprint: request.fingerprint,
    );
  }

  Future<T> _translate<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(_translateError(error), stackTrace);
    }
  }

  Object _translateError(Object error) {
    if (error is legacy_sftp.SftpTransferCancelledException) {
      return feature_sftp.SftpTransferCancelledException(error.message);
    }
    if (error is legacy_sftp.SftpTextSizeLimitException) {
      return feature_sftp.SftpTextSizeLimitException(
        actualBytes: error.actualBytes,
        maxBytes: error.maxBytes,
      );
    }
    if (error is legacy_sftp.SftpFileSizeLimitException) {
      return feature_sftp.SftpFileSizeLimitException(
        observedBytes: error.observedBytes,
        maxBytes: error.maxBytes,
      );
    }
    if (error is legacy_sftp.SftpTargetChangedException) {
      return feature_sftp.SftpTargetChangedException();
    }
    return error;
  }
}

/// Test-only dependency bundle for the SFTP module scope.
///
/// Production routes continue to resolve these values from [AppRuntime] and
/// inherited providers.  The record keeps scope tests focused on lifecycle and
/// provider behavior without constructing every App Scope database.
typedef AppSftpModuleScopeDependencies = ({
  ssh_core.SshSessionManager sshSessionManager,
  legacy_sftp.SftpService sftpService,
  AppSettings settings,
  AppLogService logger,
  feature_connection.ConnectionViewModel? connectionViewModel,
});

/// SFTP Route 的 Module Scope，页面销毁时释放 feature-owned 数据库和监听。
final class AppSftpModuleScope extends StatefulWidget {
  /// 创建包级 SFTP 路由边界。
  const AppSftpModuleScope({
    super.key,
    required this.child,
    @visibleForTesting this.moduleFactory,
    @visibleForTesting this.dependencies,
  });

  /// Module 激活完成后显示的页面。
  final Widget child;

  /// 可选的测试 Module 构造器；生产路由仍使用默认数据库实现。
  @visibleForTesting
  final feature_sftp.SftpModule Function()? moduleFactory;

  /// Optional test dependencies that bypass the AppRuntime composition root.
  @visibleForTesting
  final AppSftpModuleScopeDependencies? dependencies;

  @override
  State<AppSftpModuleScope> createState() => _AppSftpModuleScopeState();
}

final class _AppSftpModuleScopeState extends State<AppSftpModuleScope> {
  late final feature_sftp.SftpModule _module;
  late final AppSftpSettingsAdapter _settings;
  late final AppSftpConnectionCatalogAdapter _catalog;
  late final AppSftpHostKeyConfirmationAdapter _hostKey;
  late final AppSftpLoggerAdapter _logger;
  late final Future<void> _activation;

  @override
  void initState() {
    super.initState();
    final dependencies = widget.dependencies;
    final runtime = dependencies == null ? context.read<AppRuntime>() : null;
    _module = widget.moduleFactory?.call() ?? feature_sftp.SftpModule();
    _settings = AppSftpSettingsAdapter(
      dependencies?.settings ?? runtime!.appSettings,
    );
    _catalog = AppSftpConnectionCatalogAdapter(
      dependencies == null
          ? context.read<feature_connection.ConnectionViewModel?>()
          : dependencies.connectionViewModel,
    );
    _hostKey = AppSftpHostKeyConfirmationAdapter(() => context);
    _logger = AppSftpLoggerAdapter(
      dependencies?.logger ?? runtime!.appLogService,
    );
    _activation = _activate(
      dependencies?.sshSessionManager ?? runtime!.sshSessionManager,
      dependencies?.sftpService ?? runtime!.sftpService,
    );
  }

  Future<void> _activate(
    ssh_core.SshSessionManager sshSessionManager,
    legacy_sftp.SftpService sftpService,
  ) async {
    final backend = AppSftpBackendAdapter(sftpService);
    await _module.register(
      ModuleContext.fromMap({
        ssh_core.SshSessionManager: sshSessionManager,
        feature_sftp.SftpBackend: backend,
      }),
    );
    await _module.activate();
  }

  @override
  void dispose() {
    unawaited(_module.dispose());
    _settings.dispose();
    _catalog.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _activation,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Scaffold(
            body: Center(child: Text('SFTP module failed to initialize.')),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          final isEn = _settings.language == feature_sftp.SftpLanguage.english;
          final strings = AppStrings(isEn ? AppLanguage.en : AppLanguage.zh);
          return Scaffold(body: _SftpModuleScopeSkeleton(strings: strings));
        }
        return MultiProvider(
          providers: [
            ListenableProvider<feature_sftp.SftpSettingsPort>.value(
              value: _settings,
            ),
            ListenableProvider<feature_sftp.SftpConnectionCatalogPort>.value(
              value: _catalog,
            ),
            Provider<feature_sftp.SftpHostKeyConfirmationPort>.value(
              value: _hostKey,
            ),
            Provider<feature_sftp.SftpLoggerPort>.value(value: _logger),
            ChangeNotifierProvider<feature_sftp.SftpViewModel>(
              create: (_) => feature_sftp.SftpViewModel(_module.service),
            ),
          ],
          child: widget.child,
        );
      },
    );
  }
}

class _SftpModuleScopeSkeleton extends StatelessWidget {
  const _SftpModuleScopeSkeleton({required this.strings});

  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AppSkeletonizer.zone(
      enabled: true,
      semanticsLabel: strings.sftp,
      child: AppPageSurface(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top Server Selector Strip
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusSmall,
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.dns_outlined, size: 16),
                          SizedBox(width: 6),
                          Text(
                            'Production-Server-01',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusSmall,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.dns_outlined,
                            size: 16,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Staging-Node',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    const Icon(Icons.chevron_left_rounded, size: 20),
                  ],
                ),
              ),
              const Divider(height: 1),

              // Path Breadcrumbs Bar
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusSmall,
                          ),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.folder_open_rounded, size: 18),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '/var/www/html/public',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.star_outline_rounded, size: 22),
                    const SizedBox(width: 10),
                    const Icon(Icons.refresh_rounded, size: 22),
                  ],
                ),
              ),
              const Divider(height: 1),

              // File & Folder Tiles
              Expanded(
                child: ListView(
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(12),
                  children: [
                    _buildEntryTile(
                      context,
                      Icons.folder_rounded,
                      colorScheme.primary,
                      'assets',
                      'Directory · 4 KB',
                    ),
                    _buildEntryTile(
                      context,
                      Icons.folder_rounded,
                      colorScheme.primary,
                      'config',
                      'Directory · 4 KB',
                    ),
                    _buildEntryTile(
                      context,
                      Icons.description_outlined,
                      colorScheme.onSurfaceVariant,
                      'index.html',
                      '12.4 KB · 2026-09-01',
                    ),
                    _buildEntryTile(
                      context,
                      Icons.code_rounded,
                      colorScheme.onSurfaceVariant,
                      'server.js',
                      '45.2 KB · 2026-09-01',
                    ),
                    _buildEntryTile(
                      context,
                      Icons.text_snippet_outlined,
                      colorScheme.onSurfaceVariant,
                      'README.md',
                      '3.1 KB · 2026-09-01',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntryTile(
    BuildContext context,
    IconData icon,
    Color iconColor,
    String name,
    String meta,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(
                  meta,
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.more_horiz_rounded),
        ],
      ),
    );
  }
}
