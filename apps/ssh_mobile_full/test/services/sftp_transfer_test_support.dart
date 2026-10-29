import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/sftp_backend_adapters.dart' hide SftpService;
import 'package:ssh_mobile/app/sftp_io_backend_adapters.dart';
import 'package:ssh_mobile/core/services/ssh_client_factory.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';

import '../test_utils/test_storage_adapter.dart';

ConnectionConfig makeConnection(String id) => ConnectionConfig(
  id: id,
  name: id,
  host: 'one.example.com',
  username: 'tester',
);

SftpEntry makeFileEntry(ConnectionConfig connection, String name, {int? size}) {
  final binding = ConnectionTargetBinding.fromConfig(connection);
  return SftpEntry(
    connectionId: connection.id,
    targetFingerprint: binding.fingerprint,
    name: name,
    path: '/srv/$name',
    lowerName: name.toLowerCase(),
    isDirectory: false,
    isLink: false,
    size: size,
    sizeLabel: size == null ? '-' : '$size B',
    modifiedAt: DateTime.utc(2026, 7, 14),
  );
}

SftpEntry makeDirEntry(ConnectionConfig connection, String name) {
  final binding = ConnectionTargetBinding.fromConfig(connection);
  return SftpEntry(
    connectionId: connection.id,
    targetFingerprint: binding.fingerprint,
    name: name,
    path: '/srv/$name',
    lowerName: name.toLowerCase(),
    isDirectory: true,
    isLink: false,
    sizeLabel: '-',
  );
}

SftpName makeRemoteFile(String filename, {required int size}) {
  return SftpName(
    filename: filename,
    longname: filename,
    attr: SftpFileAttrs(size: size, modifyTime: 1700000000),
  );
}

class TransferFixture {
  TransferFixture({
    required this.connection,
    required this.remote,
    required this.entry,
    String currentPath = '/srv',
    TelemetryClient? telemetryClient,
    Duration telemetryFailureTimeout = const Duration(milliseconds: 250),
  }) : storage = NoopStorageService() {
    service = SftpService.forTesting(
      storage.connectionRepository,
      storage.credentialRepository,
      storage.hostKeyRepository,
      connection: connection,
      sftpClient: remote,
      currentPath: currentPath,
      telemetryClient: telemetryClient,
      telemetryFailureTimeout: telemetryFailureTimeout,
    );
  }

  final ConnectionConfig connection;
  final MemorySftpClient remote;
  final SftpEntry entry;
  final NoopStorageService storage;
  late final SftpService service;

  void dispose() {
    service.dispose();
    storage.dispose();
  }
}

Future<DetachedFixture> makeDetachedFixture({
  required Uint8List bytes,
  bool withDirectory = false,
}) async {
  final connection = makeConnection('server-1');
  final storage = TestStorageAdapter();
  await storage.connectionRepository.addConnection(connection);
  final remote = MemorySftpClient();
  if (withDirectory) {
    remote.setDirectory('/srv');
  } else {
    remote.setFile('/srv/demo.bin', bytes);
  }
  final factory = FakeSshClientFactory(remote);
  final service = SftpService.forTesting(
    storage.connectionRepository,
    storage.credentialRepository,
    storage.hostKeyRepository,
    connection: connection,
    sftpClient: remote,
    currentPath: '/srv',
    clientFactory: factory,
  );
  return DetachedFixture(
    connection: connection,
    storage: storage,
    remote: remote,
    factory: factory,
    service: service,
  );
}

class DetachedFixture {
  const DetachedFixture({
    required this.connection,
    required this.storage,
    required this.remote,
    required this.factory,
    required this.service,
  });

  final ConnectionConfig connection;
  final TestStorageAdapter storage;
  final MemorySftpClient remote;
  final FakeSshClientFactory factory;
  final SftpService service;

  void dispose() {
    service.dispose();
    storage.dispose();
  }
}

class NoopStorageService extends TestStorageAdapter {
  @override
  Future<void> recordVisitedPath(String connectionId, String path) async {}
}

final class FakeSshClientFactory implements SshClientFactory {
  FakeSshClientFactory(this._sftp);

  final SftpClient _sftp;
  int connectCount = 0;

  @override
  Future<SSHClient> connectClient(
    ConnectionConfig config, {
    Duration timeout = const Duration(seconds: 15),
    ssh_core.SshCredentials? credentials,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    String? peerId,
    String? traceId,
    bool persistHostKeyTrust = true,
    Future<void> Function(ConnectionConfig? authenticatedConfig)?
    validateTarget,
  }) async {
    connectCount++;
    return FakeSshClient(_sftp);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SshClientFactory call: $invocation');
}

final class FakeSshClient implements SSHClient {
  FakeSshClient(this._sftp);

  final SftpClient _sftp;
  int closeCount = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #sftp) {
      return Future<SftpClient>.value(_sftp);
    }
    if (invocation.memberName == #close) {
      closeCount++;
      return Future<void>.value();
    }
    throw UnsupportedError('Unexpected SSHClient call: $invocation');
  }
}

final class MemorySftpClient implements SftpClient {
  final Map<String, Uint8List> files = {};
  final Map<String, List<SftpName>> listings = {};
  final Set<String> directories = {};
  final Set<String> removedPaths = {};
  final Map<String, int> openReadCounts = {};
  final Set<String> openReadPaths = {};
  final Set<String> closedReadPaths = {};
  final Set<String> closedWritePaths = {};
  final Set<String> createdDirectories = {};
  final Set<String> removedDirectories = {};
  final Map<String, String> renamedPaths = {};
  final Set<String> listErrorPaths = {};
  final Map<String, int> _listCounts = {};
  final List<String> events = [];

  Object? openError;
  Object? absoluteError;
  Object? closeReadError;
  Object? readError;
  Object? writeError;
  Object? removeError;
  Object? rmdirError;
  Object? mkdirError;
  Object? renameError;
  bool ignoreReadLength = false;
  Completer<void>? readGate;
  Completer<void>? writeGate;
  final Completer<void> readStarted = Completer<void>();
  final Completer<void> writeStarted = Completer<void>();

  void setFile(String path, Uint8List bytes) {
    files[path] = Uint8List.fromList(bytes);
  }

  Uint8List? fileBytes(String path) {
    final bytes = files[path];
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  void setListing(String path, List<SftpName> entries) {
    listings[path] = List<SftpName>.from(entries);
  }

  void setDirectory(String path) {
    directories.add(path);
  }

  int listCount(String path) => _listCounts[path] ?? 0;

  int openReadCount(String path) => openReadCounts[path] ?? 0;

  @override
  Future<String> absolute(String path) async {
    final error = absoluteError;
    if (error != null) throw error;
    return path;
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    if (directories.contains(path)) {
      return SftpFileAttrs(
        size: 0,
        mode: SftpFileMode.value(1 << 14),
        modifyTime: 1700000000,
      );
    }
    return SftpFileAttrs(
      size: files[path]?.length,
      mode: SftpFileMode.value(1 << 15),
      modifyTime: 1700000000,
    );
  }

  @override
  Future<List<SftpName>> listdir(String path) async {
    if (listErrorPaths.contains(path)) {
      throw StateError('list failed for $path');
    }
    _listCounts[path] = listCount(path) + 1;
    events.add('list:$path');
    return List<SftpName>.from(listings[path] ?? const []);
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    if (openError != null) throw openError!;
    final isWritable = (mode.flag & SftpFileOpenMode.write.flag) != 0;
    if ((mode.flag & SftpFileOpenMode.truncate.flag) != 0) {
      files[path] = Uint8List(0);
    }
    if (!isWritable) {
      openReadCounts[path] = openReadCount(path) + 1;
      openReadPaths.add(path);
    }
    return MemorySftpFile(this, path, writable: isWritable);
  }

  @override
  Future<void> remove(String path) async {
    if (removeError != null) throw removeError!;
    removedPaths.add(path);
    files.remove(path);
  }

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {
    if (mkdirError != null) throw mkdirError!;
    createdDirectories.add(path);
    directories.add(path);
  }

  @override
  Future<void> rmdir(String path) async {
    if (rmdirError != null) throw rmdirError!;
    removedDirectories.add(path);
    directories.remove(path);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    if (renameError != null) throw renameError!;
    renamedPaths[oldPath] = newPath;
    final bytes = files.remove(oldPath);
    if (bytes != null) files[newPath] = bytes;
    if (directories.remove(oldPath)) directories.add(newPath);
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SFTP client call: $invocation');
}

final class MemorySftpFile implements SftpFile {
  MemorySftpFile(this._client, this._path, {required this.writable});

  final MemorySftpClient _client;
  final String _path;
  final bool writable;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  @override
  Future<Uint8List> readBytes({int? length, int offset = 0}) async {
    if (_isClosed) throw StateError('File is closed');
    if (_client.readError != null) throw _client.readError!;
    if (!_client.readStarted.isCompleted) _client.readStarted.complete();
    final gate = _client.readGate;
    if (gate != null) await gate.future;
    final bytes = _client.files[_path] ?? Uint8List(0);
    if (offset >= bytes.length) return Uint8List(0);
    final end = _client.ignoreReadLength || length == null
        ? bytes.length
        : (offset + length) > bytes.length
        ? bytes.length
        : offset + length;
    return Uint8List.sublistView(bytes, offset, end);
  }

  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {
    if (_isClosed) throw StateError('File is closed');
    if (!writable) throw StateError('File is not writable');
    if (_client.writeError != null) throw _client.writeError!;
    if (!_client.writeStarted.isCompleted) _client.writeStarted.complete();
    final gate = _client.writeGate;
    if (gate != null) await gate.future;
    final current = _client.files[_path] ?? Uint8List(0);
    final requiredLength = offset + data.length;
    final result = Uint8List(
      requiredLength > current.length ? requiredLength : current.length,
    )..setAll(0, current);
    result.setAll(offset, data);
    _client.files[_path] = result;
    _client.events.add('write:$_path');
  }

  @override
  Future<void> close() async {
    if (_client.closeReadError != null) throw _client.closeReadError!;
    _isClosed = true;
    if (writable) {
      _client.closedWritePaths.add(_path);
      _client.events.add('close:$_path');
    } else {
      _client.closedReadPaths.add(_path);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SFTP file call: $invocation');
}
