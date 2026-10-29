part of 'sftp_service_io.dart';

extension _SftpDirectoryNavigation on SftpService {
  Future<void> _openPath(
    _SftpSession session,
    String path, {
    bool bypassCache = false,
  }) async {
    final sftp = session.sftp;
    if (sftp == null) return;

    session.state = SftpConnectionState.loading;
    session.errorMessage = null;
    notify();

    try {
      final absolutePath = await sftp.absolute(path);

      // Check directory cache
      final cached = bypassCache
          ? null
          : _directoryCache.get(
              session.connectionId,
              session.targetFingerprint,
              absolutePath,
            );
      if (cached != null) {
        session.currentPath = absolutePath;
        _lastPaths[session.connectionId] = absolutePath;
        unawaited(
          _pathHistoryStore.recordVisitedPath(
            session.connectionId,
            absolutePath,
          ),
        );
        session.entries = cached;
        session.entriesRevision++;
        session.state = SftpConnectionState.connected;
        notify();
        return;
      }

      final names = await sftp.listdir(absolutePath);
      final entries = await _buildEntries(
        connectionId: session.connectionId,
        targetFingerprint: session.targetFingerprint,
        absolutePath: absolutePath,
        names: names,
      );

      _directoryCache.set(
        session.connectionId,
        session.targetFingerprint,
        absolutePath,
        entries,
      );

      session.currentPath = absolutePath;
      _lastPaths[session.connectionId] = absolutePath;
      unawaited(
        _pathHistoryStore.recordVisitedPath(session.connectionId, absolutePath),
      );
      session.entries = entries;
      session.entriesRevision++;
      session.state = SftpConnectionState.connected;
      notify();
    } catch (e) {
      AppLogService.instance.error(
        'SFTP list directory failed',
        details: SftpLogSafety.details(
          operation: 'list_directory',
          connectionId: session.connectionId,
          path: path,
          error: e,
        ),
      );
      session.state = SftpConnectionState.error;
      session.errorMessage = 'Unable to read directory: $e';
      notify();
    }
  }

  Future<void> _openLastKnownPath(_SftpSession session) async {
    final targetPath = _lastPaths[session.connectionId] ?? session.currentPath;
    await _openPath(session, targetPath);
    if (session.state != SftpConnectionState.error || targetPath == '.') {
      return;
    }

    AppLogService.instance.warning(
      'SFTP last path unavailable, falling back to default directory',
      details: SftpLogSafety.details(
        operation: 'last_path_fallback',
        connectionId: session.connectionId,
        path: targetPath,
      ),
    );
    session.errorMessage = null;
    await _openPath(session, '.');
  }

  Future<T> _withDetachedSftp<T>(
    String connectionId,
    Future<T> Function(
      SftpClient sftp,
      ConnectionConfig config,
      ConnectionTargetBinding targetBinding,
    )
    action,
  ) async {
    final target = await RemoteTargetScope.resolveIfBound(
      connectionRepository: _connectionRepository,
      credentialRepository: _credentialRepository,
      connectionId: connectionId,
    );
    final config = target.config;
    final credentials = SshCredentials(
      password: target.password,
      privateKey: target.privateKey,
    );

    try {
      final client = await _clientFactory.connectClient(
        config,
        credentials: credentials,
        validateTarget: target.validateCurrent,
      );
      SftpClient? sftp;
      try {
        sftp = await client.sftp().timeout(const Duration(seconds: 15));
        return await action(sftp, config, target.binding);
      } finally {
        sftp?.close();
        client.close();
      }
    } catch (e) {
      AppLogService.instance.error(
        'SFTP detached operation failed',
        details: SftpLogSafety.details(
          operation: 'detached_operation',
          connectionId: connectionId,
          error: e,
        ),
      );
      rethrow;
    }
  }

  Future<List<SftpEntry>> _buildEntries({
    required String connectionId,
    required String targetFingerprint,
    required String absolutePath,
    required Iterable<SftpName> names,
  }) => SftpEntryParser.parse(
    connectionId: connectionId,
    targetFingerprint: targetFingerprint,
    absolutePath: absolutePath,
    names: names,
  );

  String _joinRemotePath(String base, String name) {
    if (base == '/' || base.isEmpty) return '/$name';
    return '$base/$name';
  }

  _SftpSession _sessionForEntry(SftpEntry entry) {
    final session = _sessions[entry.connectionId];
    if (session == null) {
      throw StateError('SFTP connection is no longer available');
    }
    if (session.sftp == null) {
      return session;
    }
    if (entry.targetFingerprint != session.targetFingerprint) {
      throw SftpTargetChangedException();
    }
    return session;
  }

  void _assertWithinMemoryLimit(
    int? bytes,
    String action, {
    int maxBytes = SftpService.maxInMemoryTransferBytes,
  }) {
    if (maxBytes < 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must not be negative');
    }
    if (bytes == null || bytes <= maxBytes) return;
    throw SftpFileSizeLimitException(observedBytes: bytes, maxBytes: maxBytes);
  }

  Future<Uint8List> _readFileBytesWithinLimit(
    SftpFile file, {
    required int maxBytes,
  }) async {
    if (maxBytes < 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must not be negative');
    }

    const chunkSize = 64 * 1024;
    final buffer = BytesBuilder(copy: false);
    var offset = 0;

    while (offset <= maxBytes) {
      final remainingWithSentinel = maxBytes - offset + 1;
      final requestedBytes = remainingWithSentinel < chunkSize
          ? remainingWithSentinel
          : chunkSize;
      final chunk = await file.readBytes(
        length: requestedBytes,
        offset: offset,
      );
      if (chunk.isEmpty) break;

      buffer.add(chunk);
      offset += chunk.length;
      if (offset > maxBytes) {
        throw SftpFileSizeLimitException(
          observedBytes: offset,
          maxBytes: maxBytes,
        );
      }

      // dartssh2's readBytes(length:) reads until the requested length or EOF.
      if (chunk.length < requestedBytes) break;
    }

    return buffer.takeBytes();
  }

  String _formatBytes(int? bytes) {
    if (bytes == null) return '-';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
  }

  Future<void> _closeFileQuietly(SftpFile? file) async {
    if (file == null) return;
    try {
      await file.close();
    } catch (e) {
      AppLogService.instance.warning(
        'SFTP file close failed',
        details: SftpLogSafety.details(operation: 'file_close', error: e),
      );
    }
  }
}
