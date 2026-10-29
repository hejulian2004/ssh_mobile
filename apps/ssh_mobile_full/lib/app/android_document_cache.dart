part of 'android_system_documents.dart';

/// Owns the cache file and grant for one source, including late native results.
final class _CacheReader {
  _CacheReader(this._owner, this._document, this.maxBytes);

  final AndroidSystemDocuments _owner;
  final _PickedDocument _document;
  final int maxBytes;
  final String _copyId = AndroidSystemDocuments._copyId();
  RandomAccessFile? _handle;
  File? _file;
  int _remaining = 0;
  Future<Uint8List?>? _reading;
  Future<void>? _closing;
  var _ready = false;
  var _closed = false;

  String get displayName => _document.displayName;
  int? get sizeBytes => _document.sizeBytes;

  Future<Uint8List?> readChunk() {
    if (_closed || _reading != null) {
      return Future.error(
        const AndroidDocumentException(AndroidDocumentException.io),
      );
    }
    final reading = _read();
    _reading = reading;
    return reading.whenComplete(() => _reading = null);
  }

  Future<Uint8List?> _read() async {
    try {
      final declared = sizeBytes;
      if (maxBytes < 0 || (declared != null && declared > maxBytes)) {
        throw const AndroidDocumentException(AndroidDocumentException.tooLarge);
      }
      if (!_ready) {
        final copied = await _owner.copyToCache(
          uri: _document.uri,
          maxBytes: maxBytes,
          operationId: _copyId,
        );
        _file = File(copied.path);
        if (_closed) {
          throw const AndroidDocumentException(AndroidDocumentException.io);
        }
        if (copied.size > maxBytes) {
          throw const AndroidDocumentException(
            AndroidDocumentException.tooLarge,
          );
        }
        _handle = await _file!.open();
        if (await _handle!.length() != copied.size) {
          throw const AndroidDocumentException(AndroidDocumentException.io);
        }
        _remaining = copied.size;
        _ready = true;
      }
      if (_closed) {
        throw const AndroidDocumentException(AndroidDocumentException.io);
      }
      if (_remaining == 0) return null;
      final buffer = Uint8List(
        _remaining.clamp(0, AndroidSystemDocuments.chunkBytes),
      );
      final count = await _handle!.readInto(buffer);
      if (count <= 0 || _closed) {
        throw const AndroidDocumentException(AndroidDocumentException.io);
      }
      _remaining -= count;
      return count == buffer.length
          ? buffer
          : Uint8List.sublistView(buffer, 0, count);
    } on FileSystemException {
      throw const AndroidDocumentException(AndroidDocumentException.io);
    }
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    if (_reading != null && !_ready) {
      await _cancelQuietly(_owner, _copyId);
    }
    try {
      await _reading;
    } catch (_) {
      // The consumer receives the read failure. Cleanup still owns the file.
    }
    try {
      await _handle?.close();
    } finally {
      _handle = null;
      try {
        final file = _file;
        if (file != null) await _deleteQuietly(file);
      } finally {
        await _releaseGrant(_owner, _document.uri, 'read');
      }
    }
  }
}

/// Owns staging until native commit completes; repeated close preserves failure.
final class _CacheWriter {
  _CacheWriter(this._owner, this._uri);

  final AndroidSystemDocuments _owner;
  final String _uri;
  final String _copyId = AndroidSystemDocuments._copyId();
  RandomAccessFile? _handle;
  File? _file;
  Future<void>? _writing;
  Future<void>? _closing;
  Future<void>? _discarding;
  Future<void>? _aborting;
  var _closed = false;
  var _aborted = false;
  var _copying = false;

  Future<void> addChunk(Uint8List bytes) {
    if (_closed || _aborted || _writing != null) {
      return Future.error(
        const AndroidDocumentException(AndroidDocumentException.io),
      );
    }
    final writing = _add(bytes);
    _writing = writing;
    return writing.whenComplete(() => _writing = null);
  }

  Future<void> _add(Uint8List bytes) async {
    try {
      if (bytes.isEmpty) return;
      _handle ??= await _open();
      if (_aborted) {
        throw const AndroidDocumentException(AndroidDocumentException.io);
      }
      await _handle!.writeFrom(bytes);
    } on FileSystemException {
      throw const AndroidDocumentException(AndroidDocumentException.io);
    }
  }

  Future<void> close() {
    if (_aborted) {
      return Future.error(
        const AndroidDocumentException(AndroidDocumentException.io),
      );
    }
    _closed = true;
    return _closing ??= _commit();
  }

  Future<void> _commit() async {
    try {
      await _writing;
      if (_aborted) {
        throw const AndroidDocumentException(AndroidDocumentException.io);
      }
      _handle ??= await _open();
      await _handle!.flush();
      await _handle!.close();
      _handle = null;
      if (_aborted) {
        throw const AndroidDocumentException(AndroidDocumentException.io);
      }
      _copying = true;
      await _owner.copyFromCache(
        path: _file!.path,
        uri: _uri,
        operationId: _copyId,
      );
      if (_aborted) {
        throw const AndroidDocumentException(
          AndroidDocumentException.cancelled,
        );
      }
    } on FileSystemException {
      throw const AndroidDocumentException(AndroidDocumentException.io);
    } finally {
      _copying = false;
      await _discard();
    }
  }

  Future<void> abort() {
    _aborted = true;
    return _aborting ??= _abort();
  }

  Future<void> _abort() async {
    if (_copying) await _cancelQuietly(_owner, _copyId);
    try {
      await (_closing ?? _writing);
    } catch (_) {
      // Abort never turns the consumer's commit/write failure into success.
    }
    await _discard();
  }

  Future<RandomAccessFile> _open() async {
    _file = File(await _owner.reserveStaging());
    return _file!.open(mode: FileMode.write);
  }

  Future<void> _discard() => _discarding ??= _cleanup();

  Future<void> _cleanup() async {
    try {
      await _handle?.close();
    } finally {
      _handle = null;
      try {
        final file = _file;
        if (file != null) await _deleteQuietly(file);
      } finally {
        await _releaseGrant(_owner, _uri, 'write');
      }
    }
  }
}

Future<void> _deleteQuietly(File file) async {
  if (await file.exists()) await file.delete();
}

Future<void> _cancelQuietly(
  AndroidSystemDocuments owner,
  String operationId,
) async {
  try {
    await owner.cancelCopy(operationId);
  } on AndroidDocumentException {
    // A completed operation has nothing left to cancel. Drain its result below.
  }
}

Future<void> _releaseGrant(
  AndroidSystemDocuments owner,
  String uri,
  String mode,
) async {
  try {
    await owner.release(uri: uri, mode: mode);
  } on AndroidDocumentException {
    // The native activity also releases its outstanding grants on destruction.
  }
}
