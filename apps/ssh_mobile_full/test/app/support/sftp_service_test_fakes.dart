// 旧 SFTP 服务共享测试替身。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/core/services/ssh_host_key_policy.dart'
    as legacy_ssh;
import 'package:ssh_mobile/services/sftp_service.dart' as legacy_sftp;

/// 记录旧 SFTP 服务调用并把可配置结果/异常暴露给断言。
final class FakeSftpService extends Fake implements legacy_sftp.SftpService {
  FakeSftpService({this.state = legacy_sftp.SftpConnectionState.connected});

  @override
  String? connectionId = 'conn-1';
  @override
  String? get targetFingerprint => 'fingerprint';
  @override
  String? connectionName = 'Server A';
  @override
  String currentPath = '/home/user';
  @override
  legacy_sftp.SftpConnectionState state;
  @override
  String? errorMessage = 'recent error';
  @override
  int entriesRevision = 7;
  @override
  List<legacy_sftp.SftpEntry> entries = <legacy_sftp.SftpEntry>[];
  @override
  bool isConnected = true;
  @override
  bool isBusy = false;
  @override
  legacy_sftp.SftpTransferState? activeTransfer;
  @override
  bool hasActiveTransfer = false;
  bool busyResult = false;
  bool openResult = true;
  List<legacy_sftp.SftpEntry> listResult = <legacy_sftp.SftpEntry>[];
  legacy_sftp.SftpPathInfo? statResult;
  String textResult = 'text';
  Uint8List bytesResult = Uint8List.fromList(<int>[1, 2, 3]);
  Object? nextError;
  bool invokeHostKeyCallback = false;
  bool? hostKeyCallbackResult;
  dynamic lastHostKeyCallback;
  String? lastConnectConnectionId;
  int refreshCalls = 0;
  int openParentCalls = 0;
  int cancelActiveTransferCalls = 0;
  final List<String> uploadedFilenames = <String>[];
  final List<String> uploadedLocalPaths = <String>[];
  final List<({String connectionId, String path})> listedDirectories =
      <({String connectionId, String path})>[];
  final List<({String connectionId, String path, int maxBytes})> reads =
      <({String connectionId, String path, int maxBytes})>[];
  final List<({String connectionId, String path, int maxBytes})> downloads =
      <({String connectionId, String path, int maxBytes})>[];
  final List<({String localPath, int maxBytes})> fileDownloads =
      <({String localPath, int maxBytes})>[];
  final List<({String connectionId, String path})> stats =
      <({String connectionId, String path})>[];
  final List<({String connectionId, String path, String text, int maxBytes})>
  writeTexts =
      <({String connectionId, String path, String text, int maxBytes})>[];
  final List<({String connectionId, String path, int maxBytes})> byteUploads =
      <({String connectionId, String path, int maxBytes})>[];
  final List<({String connectionId, String path})> createdDirectories =
      <({String connectionId, String path})>[];
  final List<({String connectionId, String path, String newPath})> renames =
      <({String connectionId, String path, String newPath})>[];
  final List<({String connectionId, String path})> deletedPaths =
      <({String connectionId, String path})>[];
  final List<String> openedPaths = <String>[];
  final List<bool> disconnectNotifies = <bool>[];
  final List<({String connectionId, bool notify, bool forgetPath})>
  connectionDisconnects =
      <({String connectionId, bool notify, bool forgetPath})>[];
  int disconnectAllCalls = 0;
  final List<String> deletedEntryNames = <String>[];
  final List<String> confirmedDeleteNames = <String>[];
  final List<legacy_sftp.SftpEntry> deletedEntries = <legacy_sftp.SftpEntry>[];
  final List<Uint8List> downloadBytesResults = <Uint8List>[];
  final List<({legacy_sftp.SftpEntry entry, int maxBytes})> readTextFiles =
      <({legacy_sftp.SftpEntry entry, int maxBytes})>[];
  final List<({legacy_sftp.SftpEntry entry, String text, int maxBytes})>
  savedTextFiles =
      <({legacy_sftp.SftpEntry entry, String text, int maxBytes})>[];

  final List<VoidCallback> _listeners = <VoidCallback>[];

  /// 当前转发给 Adapter 的监听器数量。
  int get listenerCount => _listeners.length;

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  Future<T> _run<T>(T Function() body) async {
    final error = nextError;
    if (error != null) {
      nextError = null;
      throw error;
    }
    return body();
  }

  @override
  bool isConnectionBusy(String connectionId) => busyResult;

  @override
  bool isConnectionOpen(String connectionId) => openResult;

  @override
  Future<void> connect(String connectionId, {dynamic onUnknownHostKey}) async {
    lastConnectConnectionId = connectionId;
    lastHostKeyCallback = onUnknownHostKey;
    if (invokeHostKeyCallback && onUnknownHostKey != null) {
      final result = await onUnknownHostKey(
        legacy_ssh.SshHostKeyPromptRequest(
          connectionId: 'conn-1',
          connectionName: 'Server A',
          host: '10.0.0.1',
          port: 22,
          username: 'root',
          algorithm: 'ssh-ed25519',
          fingerprint: 'SHA256:hostkey',
        ),
      );
      hostKeyCallbackResult = result as bool?;
    }
    final error = nextError;
    if (error != null) {
      nextError = null;
      throw error;
    }
  }

  @override
  Future<void> refresh() async {
    refreshCalls++;
    final error = nextError;
    if (error != null) {
      nextError = null;
      throw error;
    }
  }

  @override
  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  }) => _run(() => uploadedFilenames.add(filename));

  @override
  Future<void> uploadFile({
    required String localPath,
    required String filename,
  }) => _run(() => uploadedLocalPaths.add(localPath));

  @override
  Future<void> deleteEntry(
    legacy_sftp.SftpEntry entry, {
    required String confirmedName,
  }) {
    return _run(() {
      deletedEntries.add(entry);
      deletedEntryNames.add(entry.name);
      confirmedDeleteNames.add(confirmedName);
    });
  }

  @override
  Future<List<legacy_sftp.SftpEntry>> listDirectoryForConnection(
    String connectionId,
    String path,
  ) => _run(() {
    listedDirectories.add((connectionId: connectionId, path: path));
    return List<legacy_sftp.SftpEntry>.of(listResult);
  });

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = 1,
  }) => _run(() {
    reads.add((connectionId: connectionId, path: path, maxBytes: maxBytes));
    return textResult;
  });

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = 1,
  }) => _run(() {
    downloads.add((connectionId: connectionId, path: path, maxBytes: maxBytes));
    return bytesResult;
  });

  @override
  Future<void> downloadFile(
    legacy_sftp.SftpEntry entry, {
    required String localPath,
    int maxBytes = 1,
  }) =>
      _run(() => fileDownloads.add((localPath: localPath, maxBytes: maxBytes)));

  @override
  Future<legacy_sftp.SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  }) => _run(() {
    stats.add((connectionId: connectionId, path: path));
    final result = statResult;
    return result ??
        legacy_sftp.SftpPathInfo(
          path: path,
          isDirectory: true,
          isLink: false,
          size: 42,
          sizeLabel: '42 B',
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(1),
        );
  });

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = 1,
  }) => _run(() {
    writeTexts.add((
      connectionId: connectionId,
      path: path,
      text: text,
      maxBytes: maxBytes,
    ));
  });

  @override
  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = 1,
  }) => _run(() {
    byteUploads.add((
      connectionId: connectionId,
      path: path,
      maxBytes: maxBytes,
    ));
  });

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) => _run(
    () => createdDirectories.add((connectionId: connectionId, path: path)),
  );

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) => _run(() {
    renames.add((connectionId: connectionId, path: path, newPath: newPath));
  });

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) => _run(() => deletedPaths.add((connectionId: connectionId, path: path)));

  @override
  Future<void> openPath(String path) => _run(() => openedPaths.add(path));

  @override
  Future<void> openParent() async {
    openParentCalls++;
    final error = nextError;
    if (error != null) {
      nextError = null;
      throw error;
    }
  }

  @override
  Future<void> disconnect({bool notify = true}) =>
      _run(() => disconnectNotifies.add(notify));

  @override
  Future<void> disconnectConnection(
    String connectionId, {
    bool notify = true,
    bool forgetPath = false,
  }) => _run(() {
    connectionDisconnects.add((
      connectionId: connectionId,
      notify: notify,
      forgetPath: forgetPath,
    ));
  });

  @override
  Future<void> disconnectAll({bool notify = true}) async {
    disconnectAllCalls++;
    final error = nextError;
    if (error != null) {
      nextError = null;
      throw error;
    }
  }

  @override
  void cancelActiveTransfer() {
    cancelActiveTransferCalls++;
  }

  @override
  Future<Uint8List> downloadBytes(
    legacy_sftp.SftpEntry entry, {
    int maxBytes = 1,
    bool updateState = false,
    bool bypassCache = false,
  }) => _run(() {
    downloadBytesResults.add(bytesResult);
    return bytesResult;
  });

  @override
  Future<String> readTextFile(
    legacy_sftp.SftpEntry entry, {
    int maxBytes = 1,
  }) => _run(() {
    readTextFiles.add((entry: entry, maxBytes: maxBytes));
    return textResult;
  });

  @override
  Future<void> saveTextFile(
    legacy_sftp.SftpEntry entry,
    String text, {
    int maxBytes = 1,
  }) => _run(() {
    savedTextFiles.add((entry: entry, text: text, maxBytes: maxBytes));
  });
}
