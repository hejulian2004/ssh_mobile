part of 'sftp_service_io.dart';

/// Owns bounded uploads for the active session and detached tool calls.
extension SftpServiceTransferUploads on SftpService {
  Future<void> _uploadFileImpl({
    required String localPath,
    required String filename,
  }) async {
    final session = _activeSession;
    final sftp = session?.sftp;
    if (sftp == null) throw StateError('SFTP is not connected');
    final activeSession = session!;
    final remotePath = _joinRemotePath(activeSession.currentPath, filename);
    final cancelGeneration = _transferCancelGeneration;

    final localFile = File(localPath);
    if (!await localFile.exists()) {
      throw FileSystemException('Local file not found', localPath);
    }
    final totalSize = await localFile.length();
    _assertWithinMemoryLimit(
      totalSize,
      'upload',
      maxBytes: SftpService.maxUploadBytes,
    );
    if (_disposed ||
        !activeSession.isCurrent(_sessions) ||
        cancelGeneration != _transferCancelGeneration) {
      throw const SftpTransferCancelledException();
    }

    final transferId = DateTime.now().millisecondsSinceEpoch.toString();
    final transfer = SftpTransferState(
      id: transferId,
      name: filename,
      totalBytes: totalSize,
      isUpload: true,
    );
    _activeTransfer = transfer;
    _cancelTransferId = null;
    activeSession.state = SftpConnectionState.loading;
    notifyListeners();
    _startTransferTelemetry(transferId, transfer);

    RandomAccessFile? raf;
    SftpFile? remoteFile;
    try {
      raf = await localFile.open(mode: FileMode.read);
      if (_cancelTransferId == transferId) {
        throw const SftpTransferCancelledException();
      }
      remoteFile = await sftp.open(
        remotePath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );

      const chunkSize = 256 * 1024; // 256KB chunks
      int offset = 0;

      while (offset < totalSize) {
        if (_cancelTransferId == transferId) {
          throw const SftpTransferCancelledException();
        }

        final len = (totalSize - offset) < chunkSize
            ? (totalSize - offset)
            : chunkSize;
        final chunk = await raf.read(len);
        if (chunk.isEmpty) break;

        await remoteFile.writeBytes(chunk, offset: offset);
        offset += chunk.length;

        _activeTransfer = transfer.copyWith(bytesTransferred: offset);
        notifyListeners();
      }

      _directoryCache.invalidate(
        activeSession.connectionId,
        activeSession.targetFingerprint,
      );
      await SftpFileCache.invalidate(
        activeSession.connectionId,
        activeSession.targetFingerprint,
        remotePath,
      );
      AppLogService.instance.info(
        'SFTP file uploaded via stream',
        details: SftpLogSafety.details(
          operation: 'stream_upload',
          connectionId: activeSession.connectionId,
          path: remotePath,
          bytes: totalSize,
        ),
      );
      _completeTransferTelemetry(
        transferId,
        transfer.copyWith(bytesTransferred: totalSize),
      );
      await _openPath(activeSession, activeSession.currentPath);
    } catch (e) {
      if (e is SftpTransferCancelledException) {
        AppLogService.instance.info(
          'SFTP upload cancelled',
          details: SftpLogSafety.details(
            operation: 'stream_upload_cancelled',
            connectionId: activeSession.connectionId,
            path: remotePath,
          ),
        );
        if (remoteFile != null) {
          try {
            await sftp.remove(remotePath);
          } catch (_) {}
        }
        activeSession.state = SftpConnectionState.connected;
        await _failTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
          errorCode: TelemetryErrorCodes.sftpTransferAborted,
          stage: 'upload',
          errorMessage: 'Transfer cancelled by user',
        );
      } else {
        AppLogService.instance.error(
          'SFTP upload failed',
          details: SftpLogSafety.details(
            operation: 'stream_upload',
            connectionId: activeSession.connectionId,
            path: remotePath,
            error: e,
          ),
        );
        activeSession.state = SftpConnectionState.error;
        activeSession.errorMessage = 'Upload failed: $e';
        await _failTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
          errorCode: _mapSftpErrorCode(e, isUpload: true),
          stage: 'upload',
          errorMessage: '$e',
        );
      }
      notifyListeners();
      rethrow;
    } finally {
      await raf?.close();
      await _closeFileQuietly(remoteFile);
      _activeTransfer = null;
      _cancelTransferId = null;
      notifyListeners();
    }
  }

  Future<void> _uploadBytesImpl({
    required String filename,
    required Uint8List bytes,
  }) async {
    final session = _activeSession;
    final sftp = session?.sftp;
    if (sftp == null) return;
    _assertWithinMemoryLimit(
      bytes.length,
      'upload',
      maxBytes: SftpService.maxUploadBytes,
    );

    session!.state = SftpConnectionState.loading;
    session.errorMessage = null;
    notifyListeners();

    final remotePath = _joinRemotePath(session.currentPath, filename);
    final transferId = DateTime.now().millisecondsSinceEpoch.toString();
    final transfer = SftpTransferState(
      id: transferId,
      name: filename,
      totalBytes: bytes.length,
      isUpload: true,
    );
    _startTransferTelemetry(transferId, transfer);
    SftpFile? file;
    try {
      file = await sftp.open(
        remotePath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      await file.writeBytes(bytes);
      _directoryCache.invalidate(
        session.connectionId,
        session.targetFingerprint,
      );
      await SftpFileCache.invalidate(
        session.connectionId,
        session.targetFingerprint,
        remotePath,
      );
      AppLogService.instance.info(
        'SFTP file uploaded',
        details: SftpLogSafety.details(
          operation: 'upload_bytes',
          connectionId: session.connectionId,
          path: remotePath,
          bytes: bytes.length,
        ),
      );
      _completeTransferTelemetry(
        transferId,
        transfer.copyWith(bytesTransferred: bytes.length),
      );
      await _openPath(session, session.currentPath);
    } catch (e) {
      AppLogService.instance.error(
        'SFTP upload failed',
        details: SftpLogSafety.details(
          operation: 'upload_bytes',
          connectionId: session.connectionId,
          path: remotePath,
          error: e,
        ),
      );
      await _failTransferTelemetry(
        transferId,
        transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
        errorCode: _mapSftpErrorCode(e, isUpload: true),
        stage: 'upload',
        errorMessage: '$e',
      );
      session.state = SftpConnectionState.error;
      session.errorMessage = 'Upload failed: $e';
      notifyListeners();
      rethrow;
    } finally {
      await _closeFileQuietly(file);
    }
  }

  Future<void> _uploadBytesPathForConnectionImpl({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = SftpService.maxUploadBytes,
  }) async {
    _assertWithinMemoryLimit(bytes.length, 'upload', maxBytes: maxBytes);
    await _withDetachedSftp(connectionId, (sftp, config, targetBinding) async {
      final absolutePath = await sftp.absolute(path);
      final transferId =
          '${config.id}-up-${DateTime.now().millisecondsSinceEpoch}';
      final transfer = SftpTransferState(
        id: transferId,
        name: p.basename(absolutePath),
        totalBytes: bytes.length,
        isUpload: true,
      );
      _startTransferTelemetry(transferId, transfer);
      SftpFile? file;
      try {
        file = await sftp.open(
          absolutePath,
          mode:
              SftpFileOpenMode.create |
              SftpFileOpenMode.truncate |
              SftpFileOpenMode.write,
        );
        await file.writeBytes(bytes);
        _directoryCache.invalidate(connectionId, targetBinding.fingerprint);
        await SftpFileCache.invalidate(
          connectionId,
          targetBinding.fingerprint,
          absolutePath,
        );
        AppLogService.instance.info(
          'SFTP file uploaded for tool',
          details: SftpLogSafety.details(
            operation: 'tool_upload',
            connectionId: config.id,
            path: absolutePath,
            bytes: bytes.length,
          ),
        );
        _completeTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: bytes.length),
        );
      } catch (e) {
        await _failTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
          errorCode: _mapSftpErrorCode(e, isUpload: true),
          stage: 'upload',
          errorMessage: '$e',
        );
        rethrow;
      } finally {
        await _closeFileQuietly(file);
      }
    });
  }
}
