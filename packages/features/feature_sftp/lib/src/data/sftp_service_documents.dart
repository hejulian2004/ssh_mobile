part of 'sftp_service.dart';

/// Owns a single document staging attempt; the SSH backend remains borrowed.
extension _SftpServiceDocuments on SftpService {
  SftpDocumentUploadTarget _captureDocumentTarget() {
    final id = connectionId;
    final fingerprint = _backend.targetFingerprint;
    if (_disposed || !isConnected || id == null || fingerprint == null) {
      throw StateError('SFTP is not connected');
    }
    return (
      connectionId: id,
      targetFingerprint: fingerprint,
      directory: currentPath,
    );
  }

  void _checkDocumentTarget(SftpDocumentUploadTarget target) {
    if (connectionId != target.connectionId ||
        _backend.targetFingerprint != target.targetFingerprint ||
        currentPath != target.directory ||
        !isConnected) {
      throw SftpTargetChangedException();
    }
  }

  void _beginDocument(String name, int? size, {required bool isUpload}) {
    if (_disposed) throw const SftpTransferCancelledException();
    if (isBusy || hasActiveTransfer) {
      throw StateError('A transfer is already active');
    }
    _documentCancelled = false;
    _documentTransfer = SftpTransferState(
      id: 'document',
      name: name,
      totalBytes: size ?? 0,
      isUpload: isUpload,
    );
    _forwardBackendChanged();
  }

  void _finishDocument() {
    _documentReadLease = null;
    _documentWriteLease = null;
    _documentTransfer = null;
    _forwardBackendChanged();
  }

  void _cancelDocument() {
    _documentCancelled = true;
    _documentTransfer = _documentTransfer?.copyWith(isCancelled: true);
    final read = _documentReadLease;
    final write = _documentWriteLease;
    if (read != null) unawaited(read.close());
    if (write != null) unawaited(write.abort());
    _forwardBackendChanged();
  }

  void _documentProgress(int bytes) {
    _documentTransfer = _documentTransfer?.copyWith(bytesTransferred: bytes);
    _forwardBackendChanged();
  }

  Future<void> _uploadDocument(
    SftpDocumentSource source,
    String filename,
    SftpDocumentUploadTarget? requestedTarget,
    int maxBytes,
  ) async {
    File? spill;
    var began = false;
    final lease = _SftpDocumentReadLease(source);
    try {
      _beginDocument(filename, source.sizeBytes, isUpload: true);
      began = true;
      _documentReadLease = lease;
      final target = requestedTarget ?? _captureDocumentTarget();
      _checkDocumentTarget(target);
      if (filename.isEmpty ||
          filename == '.' ||
          filename == '..' ||
          filename.codeUnits.any(
            (unit) => unit < 32 || unit == 47 || unit == 92,
          )) {
        throw ArgumentError('Document filename must be a single name');
      }
      final limit = _checkedLimit(maxBytes, SftpService.maxUploadBytes);
      spill = await SftpDocumentTransfer.copySource(
        source: source,
        directory: _spillDirectory(),
        maxBytes: limit,
        isCancelled: () => _documentCancelled || _disposed,
        onProgress: _documentProgress,
      );
      if (_documentCancelled || _disposed) {
        throw const SftpTransferCancelledException();
      }
      _checkDocumentTarget(target);
      _documentBackendActive = true;
      try {
        await _backend.uploadFile(localPath: spill.path, filename: filename);
      } finally {
        _documentBackendActive = false;
      }
      if (_documentCancelled || _disposed) {
        throw const SftpTransferCancelledException();
      }
    } catch (_) {
      if (began && (_documentCancelled || _disposed)) {
        throw const SftpTransferCancelledException();
      }
      rethrow;
    } finally {
      try {
        await lease.release();
      } finally {
        try {
          await _deleteSpill(spill);
        } finally {
          if (began) _finishDocument();
        }
      }
    }
  }

  Future<void> _downloadDocument(
    SftpEntry entry,
    SftpDocumentSink sink,
    int maxBytes,
  ) async {
    File? spill;
    var began = false;
    final lease = _SftpDocumentWriteLease(sink);
    try {
      _beginDocument(entry.name, entry.size, isUpload: false);
      began = true;
      _documentWriteLease = lease;
      // Match path downloads: the settings limit may exceed the default 512 MiB.
      final limit = _checkedLimit(maxBytes, SftpSettingsLimits.maxBytes);
      final declared = entry.size;
      if (declared != null && declared > limit) {
        throw SftpFileSizeLimitException(
          observedBytes: declared,
          maxBytes: limit,
        );
      }
      spill = await SftpDocumentTransfer.reserve(_spillDirectory());
      _documentBackendActive = true;
      try {
        await _backend.downloadFile(
          entry,
          localPath: spill.path,
          maxBytes: limit,
        );
      } finally {
        _documentBackendActive = false;
      }
      if (_documentCancelled || _disposed) {
        throw const SftpTransferCancelledException();
      }
      final actual = await spill.length();
      if (actual > limit) {
        throw SftpFileSizeLimitException(
          observedBytes: actual,
          maxBytes: limit,
        );
      }
      await SftpDocumentTransfer.copyFileToSink(
        file: spill,
        sink: sink,
        isCancelled: () => _documentCancelled || _disposed,
        onProgress: _documentProgress,
      );
      await sink.close();
      if (_documentCancelled || _disposed) {
        throw const SftpTransferCancelledException();
      }
    } catch (_) {
      await lease.abort();
      if (began && (_documentCancelled || _disposed)) {
        throw const SftpTransferCancelledException();
      }
      rethrow;
    } finally {
      try {
        await _deleteSpill(spill);
      } finally {
        if (began) _finishDocument();
      }
    }
  }

  Directory _spillDirectory() =>
      _documentSpillDirectory?.call() ?? Directory.systemTemp;

  int _checkedLimit(int requested, int ceiling) {
    if (requested < 0) throw ArgumentError.value(requested, 'maxBytes');
    return requested < ceiling ? requested : ceiling;
  }

  Future<void> _deleteSpill(File? spill) async {
    if (spill != null && await spill.exists()) await spill.delete();
  }
}

/// A cancellation can request closure while readChunk is awaiting the provider.
/// Errors are retained and observed by the attempt's finally, never left unhandled.
final class _SftpDocumentReadLease {
  _SftpDocumentReadLease(this.source);
  final SftpDocumentSource source;
  Future<void>? _closing;
  Object? _error;
  StackTrace? _stack;

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await source.close();
    } catch (error, stack) {
      _error = error;
      _stack = stack;
    }
  }

  Future<void> release() async {
    await close();
    final error = _error;
    if (error != null) Error.throwWithStackTrace(error, _stack!);
  }
}

final class _SftpDocumentWriteLease {
  _SftpDocumentWriteLease(this.sink);
  final SftpDocumentSink sink;
  Future<void>? _aborting;
  Future<void> abort() => _aborting ??= _abort();
  Future<void> _abort() async {
    try {
      await sink.abort();
    } catch (_) {}
  }
}
