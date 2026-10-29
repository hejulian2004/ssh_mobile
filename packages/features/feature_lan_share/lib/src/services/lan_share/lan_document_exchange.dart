import 'dart:io';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';
import 'package:path/path.dart' as p;

import '../../domain/lan_document_access.dart';
import 'lan_storage_service.dart';

/// A bounded document operation failed before it could be published.
final class LanDocumentTransferException implements Exception {
  const LanDocumentTransferException(this.code, this.message);

  final NetworkErrorCode code;
  final String message;

  @override
  String toString() => 'LanDocumentTransferException: $message';
}

/// Borrows the existing sandbox owner; never creates a second transfer runtime.
final class LanDocumentExchange {
  LanDocumentExchange(this._storage);

  final LanStorageService _storage;
  static const int chunkBytes = 16 * 1024;
  static const int _spaceCheckBytes = 1024 * 1024;

  /// Copies completely before handing the file to the normal send/history path.
  /// Native acceptance is asynchronous: history and sandbox TTL retain the source
  /// after handoff, including failures that can be retried. Only an unsubmitted
  /// partial file belongs to this attempt's cleanup.
  Future<NetworkResult<TransferSession>> sendFromDocument({
    required LanDocumentSource source,
    required int maxBytes,
    required String peerId,
    required Future<NetworkResult<TransferSession>> Function(String path)
    sendRegularFile,
    required bool Function() isCancelled,
  }) async {
    File? spill;
    RandomAccessFile? handle;
    var handedOff = false;
    var sourceClosed = false;
    try {
      _checkCancelled(isCancelled);
      if (maxBytes < 0) {
        throw const LanDocumentTransferException(
          NetworkErrorCode.invalidArgument,
          'Document byte limit is invalid.',
        );
      }
      final limit = maxBytes < LanDocumentLimits.maxSendBytes
          ? maxBytes
          : LanDocumentLimits.maxSendBytes;
      final declared = source.sizeBytes;
      if (declared != null && (declared < 0 || declared > limit)) {
        throw _tooLarge;
      }
      await _checkSpace(declared ?? 0);
      _checkCancelled(isCancelled);
      spill = await _storage.getSandboxTargetFile(source.displayName);
      handle = await spill.open(mode: FileMode.writeOnly);
      var total = 0;
      var spaceBudget = 0;
      while (true) {
        _checkCancelled(isCancelled);
        final chunk = await source.readChunk();
        _checkCancelled(isCancelled);
        if (chunk == null) break;
        if (chunk.isEmpty) continue;
        if (chunk.length > limit - total) throw _tooLarge;
        if (chunk.length > spaceBudget) {
          final remaining = limit - total;
          final batch = remaining < _spaceCheckBytes
              ? remaining
              : _spaceCheckBytes;
          spaceBudget = chunk.length > batch ? chunk.length : batch;
          await _checkSpace(spaceBudget);
          _checkCancelled(isCancelled);
        }
        await handle.writeFrom(chunk);
        total += chunk.length;
        spaceBudget -= chunk.length;
      }
      await handle.flush();
      await handle.close();
      handle = null;
      sourceClosed = true;
      await source.close();
      _checkCancelled(isCancelled);
      handedOff = true;
      return await sendRegularFile(spill.path);
    } catch (error) {
      final failure = isCancelled()
          ? const LanDocumentTransferException(
              NetworkErrorCode.cancelled,
              'Document operation was cancelled.',
            )
          : error is LanDocumentTransferException
          ? error
          : const LanDocumentTransferException(
              NetworkErrorCode.ioError,
              'Document import failed.',
            );
      return NetworkFailure<TransferSession>(
        NetworkError(
          code: failure.code,
          message: failure.message,
          operation: NetworkOperation.sendFile,
          peerId: peerId,
        ),
      );
    } finally {
      try {
        await handle?.close();
      } finally {
        try {
          if (!sourceClosed) await source.close();
        } catch (_) {
          // Closing an already-failed source must not skip sandbox cleanup.
        } finally {
          if (!handedOff && spill != null) {
            await _storage.deleteSandboxFile(spill.path);
          }
        }
      }
    }
  }

  /// Exports only a regular file whose lexical and resolved paths are contained
  /// in the sandbox. Every rejected or failed export aborts its selected sink.
  Future<void> exportSandboxFile({
    required File source,
    required LanDocumentSink sink,
    required bool Function() isCancelled,
  }) async {
    RandomAccessFile? handle;
    try {
      _checkCancelled(isCancelled);
      final sandbox = await _storage.getSandboxDirectory();
      if (!_within(sandbox.path, source.path) ||
          await FileSystemEntity.type(source.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const LanDocumentTransferException(
          NetworkErrorCode.invalidArgument,
          'Only a regular sandbox file can be exported.',
        );
      }
      final root = await sandbox.resolveSymbolicLinks();
      final candidate = await source.resolveSymbolicLinks();
      if (!_within(root, candidate)) {
        throw const LanDocumentTransferException(
          NetworkErrorCode.invalidArgument,
          'Only a sandbox file can be exported.',
        );
      }
      _checkCancelled(isCancelled);
      handle = await File(candidate).open();
      final buffer = Uint8List(chunkBytes);
      while (true) {
        _checkCancelled(isCancelled);
        final count = await handle.readInto(buffer);
        if (count == 0) break;
        await sink.addChunk(Uint8List.sublistView(buffer, 0, count));
        _checkCancelled(isCancelled);
      }
      _checkCancelled(isCancelled);
      await sink.close();
    } catch (error) {
      try {
        await sink.abort();
      } catch (_) {}
      if (error is LanDocumentTransferException) rethrow;
      throw const LanDocumentTransferException(
        NetworkErrorCode.ioError,
        'Document export failed.',
      );
    } finally {
      await handle?.close();
    }
  }

  Future<void> _checkSpace(int requiredBytes) async {
    if (!await _storage.hasSufficientSpace(requiredBytes)) {
      throw const LanDocumentTransferException(
        NetworkErrorCode.resourceLimit,
        'Sandbox space is insufficient or unavailable.',
      );
    }
  }

  void _checkCancelled(bool Function() isCancelled) {
    if (isCancelled()) {
      throw const LanDocumentTransferException(
        NetworkErrorCode.cancelled,
        'Document operation was cancelled.',
      );
    }
  }

  bool _within(String root, String candidate) {
    var rootKey = p.normalize(p.absolute(root));
    var candidateKey = p.normalize(p.absolute(candidate));
    if (Platform.isWindows) {
      rootKey = rootKey.toLowerCase();
      candidateKey = candidateKey.toLowerCase();
    }
    return p.isWithin(rootKey, candidateKey);
  }

  static const _tooLarge = LanDocumentTransferException(
    NetworkErrorCode.resourceLimit,
    'Document is larger than the send limit.',
  );
}
