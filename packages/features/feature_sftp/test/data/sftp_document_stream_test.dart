import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:feature_sftp/feature_sftp.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/sftp_test_fakes.dart';

void main() {
  test('document I/O diagnostics omit untrusted provider messages', () {
    const error = SftpDocumentIoException('untrusted-provider-error');
    expect(error.toString(), isNot(contains('untrusted-provider-error')));
  });
  late Directory spillDirectory;
  late FakeSftpBackend backend;
  late _TransferLog log;
  late SftpViewModel viewModel;
  late SftpService service;

  setUp(() async {
    spillDirectory = await Directory.systemTemp.createTemp(
      'sftp-document-stream-',
    );
    log = _TransferLog();
    backend = FakeSftpBackend()
      ..connectionId = 'connection-1'
      ..currentPath = '/home'
      ..isConnected = true
      ..onUploadFile = ({required localPath, required filename}) async {
        log.uploadCount += 1;
        log.uploadedName = filename;
        log.uploadedBytes = await File(localPath).readAsBytes();
        log.stored = log.uploadedBytes;
      }
      ..onDownloadFile =
          (entry, {required localPath, required maxBytes}) async {
            log.downloadCount += 1;
            final bytes = log.stored ?? Uint8List(0);
            if (bytes.length > maxBytes) {
              throw SftpFileSizeLimitException(
                observedBytes: bytes.length,
                maxBytes: maxBytes,
              );
            }
            await File(localPath).writeAsBytes(bytes);
          };
    service = SftpService(
      backend: backend,
      historyRepository: _UnusedHistory(),
      sshSessionManager: FakeSshSessionManager(),
      documentSpillDirectory: () => spillDirectory,
    );
    viewModel = SftpViewModel(service);
  });

  tearDown(() async {
    viewModel.dispose();
    service.dispose();
    if (await spillDirectory.exists()) {
      await spillDirectory.delete(recursive: true);
    }
  });

  test(
    'upload and download round-trip a document larger than one chunk',
    () async {
      final payload = Uint8List.fromList(
        List<int>.generate(20 * 1024 + 50, (index) => index % 251),
      );
      final source = _ChunkSource(
        payload,
        displayName: 'notes.txt',
        pieceBytes: 1000,
      );
      final entry = _entry(size: payload.length);

      await viewModel.uploadFromDocument(
        source: source,
        filename: 'notes.txt',
        maxBytes: SftpService.maxUploadBytes,
      );
      expect(source.readCount, greaterThan(1));
      expect(log.uploadCount, 1);
      expect(log.uploadedName, 'notes.txt');
      expect(log.uploadedBytes, payload);
      expect(await _spillFiles(spillDirectory), isEmpty);

      final sink = _CollectingSink();
      await viewModel.downloadToDocument(
        entry: entry,
        sink: sink,
        maxBytes: SftpService.maxDownloadBytes,
      );
      expect(log.downloadCount, 1);
      expect(sink.chunks.length, greaterThan(1));
      expect(sink.bytes, payload);
      expect(sink.closed, isTrue);
      expect(sink.aborted, isFalse);
      expect(await _spillFiles(spillDirectory), isEmpty);
    },
  );

  test(
    'a directory change during document copy cannot retarget upload',
    () async {
      final source = _ChunkSource(
        Uint8List.fromList([1, 2, 3]),
        displayName: 'notes.txt',
        pieceBytes: 1,
        onRead: (_) {
          backend.currentPath = '/other';
        },
      );
      await expectLater(
        viewModel.uploadFromDocument(source: source, filename: 'notes.txt'),
        throwsA(isA<SftpTargetChangedException>()),
      );
      expect(log.uploadCount, 0);
      expect(source.closed, isTrue);
      expect(await _spillFiles(spillDirectory), isEmpty);
    },
  );

  test('the destination captured before the picker must still match', () async {
    final target = viewModel.documentUploadTarget;
    expect(target.connectionId, 'connection-1');
    expect(target.targetFingerprint, 'fingerprint');
    expect(target.directory, '/home');
    for (final change in <void Function()>[
      () {
        backend.targetFingerprint = 'rebound-host';
      },
      () {
        backend.targetFingerprint = 'fingerprint';
        backend.connectionId = 'other';
      },
      () {
        backend.connectionId = 'connection-1';
        backend.currentPath = '/other';
      },
    ]) {
      change();
      final source = _ChunkSource(
        Uint8List.fromList([1]),
        displayName: 'notes.txt',
        pieceBytes: 1,
      );
      await expectLater(
        viewModel.uploadFromDocument(
          source: source,
          filename: 'notes.txt',
          target: target,
        ),
        throwsA(isA<SftpTargetChangedException>()),
      );
      expect(source.readCount, 0);
      expect(source.closed, isTrue);
    }
    expect(log.uploadCount, 0);
    backend.isConnected = false;
    expect(() => viewModel.documentUploadTarget, throwsStateError);
  });

  test('fingerprint rebind during copy cannot retarget upload', () async {
    final source = _ChunkSource(
      Uint8List.fromList([1]),
      displayName: 'notes.txt',
      pieceBytes: 1,
      onRead: (_) {
        backend.targetFingerprint = 'changed-host';
      },
    );
    await expectLater(
      viewModel.uploadFromDocument(source: source, filename: 'notes.txt'),
      throwsA(isA<SftpTargetChangedException>()),
    );
    expect(log.uploadCount, 0);
  });

  test(
    'invalid names and negative limits close the source without upload',
    () async {
      for (final name in [
        '',
        '.',
        '..',
        '../escape',
        'a/b',
        r'a\b',
        'a\u0000b',
        'a\u001fb',
      ]) {
        final source = _ChunkSource(
          Uint8List(0),
          displayName: name,
          pieceBytes: 1,
        );
        await expectLater(
          viewModel.uploadFromDocument(source: source, filename: name),
          throwsArgumentError,
        );
        expect(source.closed, isTrue);
      }
      final source = _ChunkSource(
        Uint8List(0),
        displayName: 'ok.txt',
        pieceBytes: 1,
      );
      await expectLater(
        viewModel.uploadFromDocument(
          source: source,
          filename: 'ok.txt',
          maxBytes: -1,
        ),
        throwsArgumentError,
      );
      expect(source.closed, isTrue);
      expect(log.uploadCount, 0);
      expect(await _spillFiles(spillDirectory), isEmpty);
    },
  );

  test(
    'staging publishes progress and releases busy state after failure',
    () async {
      var largest = 0;
      var sawBusy = false;
      service.addListener(() {
        sawBusy = sawBusy || (service.isBusy && service.hasActiveTransfer);
        largest = (service.activeTransfer?.bytesTransferred ?? 0) > largest
            ? service.activeTransfer!.bytesTransferred
            : largest;
      });
      final source = _ChunkSource(
        Uint8List.fromList([1, 2, 3]),
        displayName: 'notes.txt',
        pieceBytes: 1,
      );
      await viewModel.uploadFromDocument(source: source, filename: 'notes.txt');
      expect(sawBusy, isTrue);
      expect(largest, 3);
      expect(service.isBusy, isFalse);
      expect(service.activeTransfer, isNull);
    },
  );

  test(
    'empty documents and configured large downloads use the caller limit',
    () async {
      final empty = _ChunkSource(
        Uint8List(0),
        displayName: 'empty',
        pieceBytes: 1,
      );
      await viewModel.uploadFromDocument(
        source: empty,
        filename: 'empty',
        maxBytes: 0,
      );
      expect(log.uploadedBytes, isEmpty);
      final sink = _CollectingSink();
      int? observedLimit;
      backend.onDownloadFile =
          (entry, {required localPath, required maxBytes}) async {
            observedLimit = maxBytes;
            await File(localPath).writeAsBytes([]);
          };
      await viewModel.downloadToDocument(
        entry: _entry(size: 0),
        sink: sink,
        maxBytes: SftpSettingsLimits.maxBytes,
      );
      expect(observedLimit, SftpSettingsLimits.maxBytes);
      expect(sink.closed, isTrue);
      expect(sink.bytes, isEmpty);
      expect(await _spillFiles(spillDirectory), isEmpty);
    },
  );

  test(
    'download overrun and close failure abort without keeping staging',
    () async {
      backend.onDownloadFile =
          (entry, {required localPath, required maxBytes}) async {
            await File(localPath).writeAsBytes([1, 2, 3]);
          };
      final overrun = _CollectingSink();
      await expectLater(
        viewModel.downloadToDocument(
          entry: _entry(size: 0),
          sink: overrun,
          maxBytes: 2,
        ),
        throwsA(isA<SftpFileSizeLimitException>()),
      );
      expect(overrun.aborted, isTrue);
      final closeFailure = _CollectingSink(
        closeError: const SftpDocumentIoException('close failed'),
        abortError: StateError('abort failed'),
      );
      await expectLater(
        viewModel.downloadToDocument(
          entry: _entry(size: 3),
          sink: closeFailure,
          maxBytes: 4,
        ),
        throwsA(isA<SftpDocumentIoException>()),
      );
      expect(closeFailure.aborted, isTrue);
      final invalidLimit = _CollectingSink();
      await expectLater(
        viewModel.downloadToDocument(
          entry: _entry(size: 0),
          sink: invalidLimit,
          maxBytes: -1,
        ),
        throwsArgumentError,
      );
      expect(invalidLimit.aborted, isTrue);
      expect(await _spillFiles(spillDirectory), isEmpty);
    },
  );

  test('dispose during document copy cancels before remote upload', () async {
    final source = _ChunkSource(
      Uint8List.fromList([1, 2, 3]),
      displayName: 'notes.txt',
      pieceBytes: 1,
      onRead: (_) {
        service.dispose();
      },
    );
    await expectLater(
      viewModel.uploadFromDocument(source: source, filename: 'notes.txt'),
      throwsA(isA<SftpTransferCancelledException>()),
    );
    expect(log.uploadCount, 0);
    expect(source.closed, isTrue);
    expect(await _spillFiles(spillDirectory), isEmpty);
  });

  test(
    'cancel closes a blocked document source and drains the attempt',
    () async {
      final source = _BlockedSource();
      final operation = viewModel.uploadFromDocument(
        source: source,
        filename: 'blocked.bin',
      );
      final checked = expectLater(
        operation,
        throwsA(isA<SftpTransferCancelledException>()),
      );
      await source.readStarted.future;
      viewModel.cancelActiveTransfer();
      expect(service.activeTransfer?.isCancelled, isTrue);
      try {
        await checked.timeout(const Duration(seconds: 2));
        expect(source.closeCount, 1);
        expect(log.uploadCount, 0);
        expect(service.hasActiveTransfer, isFalse);
      } finally {
        await source.close();
      }
    },
  );

  test(
    'cancel aborts an in-flight document publication and drains close',
    () async {
      log.stored = Uint8List.fromList([1, 2, 3]);
      final sink = _BlockedSink();
      final operation = viewModel.downloadToDocument(
        entry: _entry(size: 3),
        sink: sink,
        maxBytes: 3,
      );
      final checked = expectLater(
        operation,
        throwsA(isA<SftpTransferCancelledException>()),
      );
      await sink.closeStarted.future;
      viewModel.cancelActiveTransfer();
      try {
        await checked.timeout(const Duration(seconds: 2));
        expect(sink.abortCount, 1);
        expect(service.hasActiveTransfer, isFalse);
        expect(await _spillFiles(spillDirectory), isEmpty);
      } finally {
        await sink.abort();
      }
    },
  );

  test('source close failure cannot leave plaintext staging behind', () async {
    final source = _ChunkSource(
      Uint8List.fromList([1, 2, 3]),
      displayName: 'notes.txt',
      pieceBytes: 1,
      closeError: const SftpDocumentIoException('close failed'),
    );
    await expectLater(
      viewModel.uploadFromDocument(source: source, filename: 'notes.txt'),
      throwsA(isA<SftpDocumentIoException>()),
    );
    expect(await _spillFiles(spillDirectory), isEmpty);
  });

  test(
    'a concurrent document call cannot reset cancellation of the first',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      final first = _ChunkSource(
        Uint8List.fromList([1, 2, 3]),
        displayName: 'first.txt',
        pieceBytes: 1,
        onReadAsync: (_) async {
          if (!started.isCompleted) {
            started.complete();
            await gate.future;
          }
        },
      );
      final firstResult = expectLater(
        viewModel.uploadFromDocument(source: first, filename: 'first.txt'),
        throwsA(isA<SftpTransferCancelledException>()),
      );
      await started.future;
      viewModel.cancelActiveTransfer();
      final second = _ChunkSource(
        Uint8List(0),
        displayName: 'second.txt',
        pieceBytes: 1,
      );
      final secondResult = expectLater(
        viewModel.uploadFromDocument(source: second, filename: 'second.txt'),
        throwsA(isA<StateError>()),
      );
      gate.complete();
      await Future.wait([firstResult, secondResult]);
      expect(log.uploadCount, 0);
      expect(first.closed, isTrue);
      expect(second.closed, isTrue);
    },
  );

  test(
    'upload rejects an oversized document before the backend write',
    () async {
      final declared = _ChunkSource(
        Uint8List(0),
        displayName: 'huge.bin',
        pieceBytes: 1,
        sizeBytes: SftpService.maxUploadBytes + 1,
      );
      await expectLater(
        viewModel.uploadFromDocument(source: declared, filename: 'huge.bin'),
        throwsA(isA<SftpFileSizeLimitException>()),
      );
      expect(declared.readCount, 0);
      expect(log.uploadCount, 0);

      final streaming = _ChunkSource(
        Uint8List.fromList(List<int>.filled(80, 7)),
        displayName: 'stream.bin',
        pieceBytes: 20,
      );
      await expectLater(
        viewModel.uploadFromDocument(
          source: streaming,
          filename: 'stream.bin',
          maxBytes: 50,
        ),
        throwsA(isA<SftpFileSizeLimitException>()),
      );
      expect(log.uploadCount, 0);
      expect(await _spillFiles(spillDirectory), isEmpty);

      final remote = _entry(size: SftpService.maxDownloadBytes + 1);
      final sink = _CollectingSink();
      await expectLater(
        viewModel.downloadToDocument(
          entry: remote,
          sink: sink,
          maxBytes: SftpService.maxDownloadBytes,
        ),
        throwsA(isA<SftpFileSizeLimitException>()),
      );
      expect(log.downloadCount, 0);
      expect(sink.chunks, isEmpty);
      expect(sink.closed, isFalse);
    },
  );

  test(
    'cancel, a missing document, and a mid-stream failure do not succeed',
    () async {
      final cancelled = _ChunkSource(
        Uint8List.fromList(List<int>.filled(300, 1)),
        displayName: 'cancel.bin',
        pieceBytes: 100,
        onRead: (index) {
          if (index == 1) viewModel.cancelActiveTransfer();
        },
      );
      await expectLater(
        viewModel.uploadFromDocument(
          source: cancelled,
          filename: 'cancel.bin',
          maxBytes: 1000,
        ),
        throwsA(isA<SftpTransferCancelledException>()),
      );

      final missing = _ChunkSource(
        Uint8List.fromList(const [1, 2, 3]),
        displayName: 'missing.bin',
        pieceBytes: 1,
        onRead: (_) => throw const SftpDocumentMissingException(),
      );
      await expectLater(
        viewModel.uploadFromDocument(
          source: missing,
          filename: 'missing.bin',
          maxBytes: 1000,
        ),
        throwsA(isA<SftpDocumentMissingException>()),
      );

      final broken = _ChunkSource(
        Uint8List.fromList(List<int>.filled(300, 4)),
        displayName: 'broken.bin',
        pieceBytes: 100,
        onRead: (index) {
          if (index == 2) throw const SftpDocumentIoException('read failed');
        },
      );
      await expectLater(
        viewModel.uploadFromDocument(
          source: broken,
          filename: 'broken.bin',
          maxBytes: 1000,
        ),
        throwsA(isA<SftpDocumentIoException>()),
      );

      expect(log.uploadCount, 0);
      expect(await _spillFiles(spillDirectory), isEmpty);

      log.stored = Uint8List.fromList(
        List<int>.generate(20 * 1024 + 10, (index) => index % 17),
      );
      final sink = _CollectingSink(
        onChunk: (index) {
          if (index == 1) viewModel.cancelActiveTransfer();
        },
      );
      await expectLater(
        viewModel.downloadToDocument(
          entry: _entry(size: log.stored!.length),
          sink: sink,
          maxBytes: SftpService.maxDownloadBytes,
        ),
        throwsA(isA<SftpTransferCancelledException>()),
      );
      expect(sink.closed, isFalse);

      final failingSink = _CollectingSink(failOnChunk: 1);
      await expectLater(
        viewModel.downloadToDocument(
          entry: _entry(size: log.stored!.length),
          sink: failingSink,
          maxBytes: SftpService.maxDownloadBytes,
        ),
        throwsA(isA<SftpDocumentIoException>()),
      );
      expect(failingSink.closed, isFalse);
      expect(failingSink.chunks.length, 1);
      expect(await _spillFiles(spillDirectory), isEmpty);
    },
  );
}

SftpEntry _entry({required int size}) {
  return SftpEntry(
    connectionId: 'connection-1',
    targetFingerprint: 'fingerprint',
    name: 'notes.txt',
    path: '/home/notes.txt',
    lowerName: 'notes.txt',
    isDirectory: false,
    isLink: false,
    size: size,
    sizeLabel: '$size B',
  );
}

Future<List<File>> _spillFiles(Directory directory) async {
  if (!await directory.exists()) return const [];
  return directory.listSync().whereType<File>().toList();
}

final class _ChunkSource implements SftpDocumentSource {
  _ChunkSource(
    this.payload, {
    required this.displayName,
    required this.pieceBytes,
    this.sizeBytes,
    this.onRead,
    this.onReadAsync,
    this.closeError,
  });

  final Uint8List payload;
  @override
  final String displayName;
  final int pieceBytes;
  @override
  final int? sizeBytes;
  final void Function(int index)? onRead;
  final Future<void> Function(int index)? onReadAsync;
  final Object? closeError;
  int readCount = 0;
  int _offset = 0;
  var closed = false;

  @override
  Future<Uint8List?> readChunk() async {
    final index = readCount;
    readCount += 1;
    onRead?.call(index);
    await onReadAsync?.call(index);
    if (_offset >= payload.length) return null;
    final end = _offset + pieceBytes;
    final next = end > payload.length ? payload.length : end;
    final chunk = Uint8List.sublistView(payload, _offset, next);
    _offset = next;
    return Uint8List.fromList(chunk);
  }

  @override
  Future<void> close() async {
    closed = true;
    if (closeError != null) throw closeError!;
  }
}

final class _CollectingSink implements SftpDocumentSink {
  _CollectingSink({
    this.failOnChunk,
    this.onChunk,
    this.closeError,
    this.abortError,
  });

  final int? failOnChunk;
  final void Function(int index)? onChunk;
  final Object? closeError;
  final Object? abortError;
  final chunks = <Uint8List>[];
  var closed = false;
  var aborted = false;

  Uint8List get bytes {
    final builder = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> addChunk(Uint8List bytes) async {
    final index = chunks.length;
    onChunk?.call(index);
    if (failOnChunk != null && index == failOnChunk) {
      throw const SftpDocumentIoException('sink failed');
    }
    chunks.add(Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    if (closeError != null) throw closeError!;
    closed = true;
  }

  @override
  Future<void> abort() async {
    aborted = true;
    if (abortError != null) throw abortError!;
  }
}

final class _TransferLog {
  int uploadCount = 0;
  int downloadCount = 0;
  String? uploadedName;
  Uint8List? uploadedBytes;
  Uint8List? stored;
}

final class _BlockedSource implements SftpDocumentSource {
  final readStarted = Completer<void>();
  final _readFinished = Completer<void>();
  int closeCount = 0;
  @override
  String get displayName => 'blocked.bin';
  @override
  int? get sizeBytes => null;
  @override
  Future<Uint8List?> readChunk() async {
    readStarted.complete();
    await _readFinished.future;
    throw const SftpDocumentMissingException();
  }

  @override
  Future<void> close() async {
    closeCount++;
    if (!_readFinished.isCompleted) _readFinished.complete();
  }
}

final class _BlockedSink implements SftpDocumentSink {
  final closeStarted = Completer<void>();
  final _closeFinished = Completer<void>();
  int abortCount = 0;
  @override
  Future<void> addChunk(Uint8List bytes) async {}
  @override
  Future<void> close() async {
    closeStarted.complete();
    await _closeFinished.future;
  }

  @override
  Future<void> abort() async {
    abortCount++;
    if (!_closeFinished.isCompleted) _closeFinished.complete();
  }
}

final class _UnusedHistory implements SftpPathHistoryRepository {
  @override
  Future<SftpFavoritePathRecord> addFavoritePath(
    String connectionId,
    String path,
    String name,
  ) => Future<SftpFavoritePathRecord>.error(UnimplementedError());

  @override
  Future<SftpFavoritePathRecord?> findFavoritePath(
    String connectionId,
    String path,
  ) async => null;

  @override
  Future<List<SftpFavoritePathRecord>> loadFavoritePaths(
    String connectionId,
  ) async => const [];

  @override
  Future<List<SftpRecentPathRecord>> loadRecentPaths(
    String connectionId, {
    int limit = 30,
  }) async => const [];

  @override
  Future<void> recordVisitedPath(String connectionId, String path) async {}

  @override
  Future<void> removeFavoritePath(String id) async {}

  @override
  Future<void> renameFavoritePath(String id, String name) async {}
}
