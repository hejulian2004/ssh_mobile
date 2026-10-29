import 'dart:io';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late LanStorageService storage;
  late LanDocumentExchange exchange;
  var cancelled = false;
  int? freeBytes;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lan-document-exchange-');
    freeBytes = 1024 * 1024 * 1024 * 1024;
    cancelled = false;
    storage = LanStorageService(
      sandboxDirectoryProvider: () async => root,
      freeDiskSpaceBytesProvider: () async => freeBytes,
    );
    exchange = LanDocumentExchange(storage);
  });

  tearDown(() async => root.delete(recursive: true));

  Future<NetworkResult<TransferSession>> send(
    _Source source, {
    int maxBytes = 100,
    Future<NetworkResult<TransferSession>> Function(String)? submit,
  }) => exchange.sendFromDocument(
    source: source,
    maxBytes: maxBytes,
    peerId: 'peer-a',
    isCancelled: () => cancelled,
    sendRegularFile:
        submit ??
        (path) async => NetworkSuccess(
          TransferSession(
            transferId: 'transfer-1',
            peerId: 'peer-a',
            filePath: path,
            routeType: NetworkRouteType.lan,
          ),
        ),
  );

  Future<void> export(File file, _Sink sink) => exchange.exportSandboxFile(
    source: file,
    sink: sink,
    isCancelled: () => cancelled,
  );

  test(
    'native acceptance retains bytes until sandbox GC and closes source',
    () async {
      final source = _Source([
        Uint8List.fromList([1, 2]),
        Uint8List(0),
        Uint8List.fromList([3]),
      ]);
      final result = await send(source);
      final session = (result as NetworkSuccess<TransferSession>).data;
      expect(source.closed, isTrue);
      expect(p.basename(session.filePath), 'document.bin');
      expect(await File(session.filePath).readAsBytes(), [1, 2, 3]);
      await File(
        session.filePath,
      ).setLastModified(DateTime.now().subtract(const Duration(days: 8)));
      expect(await storage.perform7DayGarbageCollection(), 1);
    },
  );

  test(
    'failed accepted sends keep their source for the history retry owner',
    () async {
      String? submitted;
      final result = await send(
        _Source([
          Uint8List.fromList([7]),
        ]),
        submit: (path) async {
          submitted = path;
          return const NetworkFailure(
            NetworkError(
              code: NetworkErrorCode.noRoute,
              message: 'No route',
              operation: NetworkOperation.sendFile,
            ),
          );
        },
      );
      expect(result, isA<NetworkFailure<TransferSession>>());
      expect(await File(submitted!).readAsBytes(), [7]);
    },
  );

  test(
    'concurrent same-name documents never overwrite each other or an existing file',
    () async {
      final existing = File(p.join(root.path, 'document.bin'));
      await existing.writeAsBytes([9]);
      final results = await Future.wait([
        send(
          _Source([
            Uint8List.fromList([1]),
          ]),
        ),
        send(
          _Source([
            Uint8List.fromList([2]),
          ]),
        ),
      ]);
      final paths = results
          .map(
            (result) =>
                (result as NetworkSuccess<TransferSession>).data.filePath,
          )
          .toSet();
      expect(paths, hasLength(2));
      expect(paths, isNot(contains(existing.path)));
      expect(await existing.readAsBytes(), [9]);
      final values = await Future.wait(
        paths.map((path) => File(path).readAsBytes()),
      );
      expect(values.map((bytes) => bytes.single).toSet(), {1, 2});
    },
  );

  for (final declared in [-1, 101, LanDocumentLimits.maxSendBytes + 1]) {
    test(
      'known invalid or oversized length rejects before read: $declared',
      () async {
        final source = _Source([], sizeBytes: declared);
        final result = await send(source);
        expect(
          (result as NetworkFailure).error.code,
          NetworkErrorCode.resourceLimit,
        );
        expect(source.reads, 0);
        expect(source.closed, isTrue);
        expect(await root.list().isEmpty, isTrue);
      },
    );
  }

  test(
    'caller cannot bypass hard send ceiling with a larger maxBytes',
    () async {
      final result = await send(
        _Source([], sizeBytes: LanDocumentLimits.maxSendBytes + 1),
        maxBytes: LanDocumentLimits.maxSendBytes * 2,
      );
      expect(
        (result as NetworkFailure).error.code,
        NetworkErrorCode.resourceLimit,
      );
    },
  );

  test('negative limit rejects while zero permits an empty document', () async {
    final result = await send(_Source([]), maxBytes: -1);
    expect(
      (result as NetworkFailure).error.code,
      NetworkErrorCode.invalidArgument,
    );
    final empty = await send(_Source([]), maxBytes: 0);
    final path = (empty as NetworkSuccess<TransferSession>).data.filePath;
    expect(await File(path).length(), 0);
  });

  for (final free in [null, LanStorageService.safetyBufferBytes - 1]) {
    test(
      'insufficient or unknown free space fails before read: $free',
      () async {
        freeBytes = free;
        final source = _Source([
          Uint8List.fromList([1]),
        ]);
        final result = await send(source);
        expect(
          (result as NetworkFailure).error.code,
          NetworkErrorCode.resourceLimit,
        );
        expect(source.reads, 0);
        expect(await root.list().isEmpty, isTrue);
      },
    );
  }

  test(
    'unknown length checks available space before its first write',
    () async {
      final source = _Source(
        [Uint8List(100)],
        onRead: (_) {
          freeBytes = LanStorageService.safetyBufferBytes + 50;
        },
      );
      final result = await send(source);
      expect(
        (result as NetworkFailure).error.code,
        NetworkErrorCode.resourceLimit,
      );
      expect(await root.list().isEmpty, isTrue);
    },
  );

  test('streaming overflow deletes partial file and never submits', () async {
    var submissions = 0;
    final source = _Source([Uint8List(2), Uint8List(2)]);
    final result = await send(
      source,
      maxBytes: 3,
      submit: (_) async {
        submissions++;
        throw StateError('unexpected submit');
      },
    );
    expect(
      (result as NetworkFailure).error.code,
      NetworkErrorCode.resourceLimit,
    );
    expect(submissions, 0);
    expect(source.closed, isTrue);
    expect(await root.list().isEmpty, isTrue);
  });

  test(
    'source I/O and close errors are redacted and cannot skip partial cleanup',
    () async {
      final source = _Source(
        [Uint8List(2)],
        onRead: (index) {
          if (index == 1) throw StateError('private path must not escape');
        },
        closeError: StateError('private close'),
      );
      final result = await send(source);
      final error = (result as NetworkFailure).error;
      expect(error.code, NetworkErrorCode.ioError);
      expect(error.message, 'Document import failed.');
      expect(await root.list().isEmpty, isTrue);
    },
  );

  test(
    'source close must finish before handoff; close failure prevents send',
    () async {
      var submitted = false;
      final result = await send(
        _Source([Uint8List(1)], closeError: StateError('close')),
        submit: (_) async {
          submitted = true;
          throw StateError('unexpected');
        },
      );
      expect((result as NetworkFailure).error.code, NetworkErrorCode.ioError);
      expect(submitted, isFalse);
      expect(await root.list().isEmpty, isTrue);
    },
  );

  test('typed source failure preserves stable code', () async {
    final result = await send(
      _Source(
        [],
        onRead: (_) {
          throw const LanDocumentTransferException(
            NetworkErrorCode.resourceLimit,
            'Limit',
          );
        },
      ),
    );
    expect(
      (result as NetworkFailure).error.code,
      NetworkErrorCode.resourceLimit,
    );
  });

  test(
    'cancel before and during read never submits or keeps a partial',
    () async {
      cancelled = true;
      final initial = _Source([]);
      final before = await send(initial);
      expect((before as NetworkFailure).error.code, NetworkErrorCode.cancelled);
      expect(initial.reads, 0);
      cancelled = false;
      final during = await send(
        _Source(
          [Uint8List(1)],
          onRead: (_) {
            cancelled = true;
          },
        ),
      );
      expect((during as NetworkFailure).error.code, NetworkErrorCode.cancelled);
      expect(await root.list().isEmpty, isTrue);
    },
  );

  test(
    'export writes bounded bytes, commits once, and keeps original',
    () async {
      final payload = List<int>.generate(40000, (index) => index % 251);
      final file = await storage.getSandboxTargetFile('original.bin');
      await file.writeAsBytes(payload);
      final sink = _Sink();
      await export(file, sink);
      expect(sink.bytes, payload);
      expect(
        sink.largestChunk,
        lessThanOrEqualTo(LanDocumentExchange.chunkBytes),
      );
      expect(sink.closed, isTrue);
      expect(sink.aborted, isFalse);
      expect(await file.readAsBytes(), payload);
    },
  );

  for (final kind in ['missing', 'directory', 'outside']) {
    test('rejected $kind export aborts without writing', () async {
      final source = switch (kind) {
        'directory' => File(root.path),
        'outside' => File(p.join(root.parent.path, 'outside-document.bin')),
        _ => File(p.join(root.path, 'missing.bin')),
      };
      final sink = _Sink();
      await expectLater(
        export(source, sink),
        throwsA(isA<LanDocumentTransferException>()),
      );
      expect(sink.aborted, isTrue);
      expect(sink.closed, isFalse);
      expect(sink.bytes, isEmpty);
    });
  }

  test(
    'a linked directory cannot expose a regular file outside sandbox',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'lan-document-outside-',
      );
      final link = Link(p.join(root.path, 'link'));
      try {
        final target = File(p.join(outside.path, 'outside.bin'));
        await target.writeAsBytes([1]);
        await link.create(outside.path);
        final sink = _Sink();
        await expectLater(
          export(File(p.join(link.path, 'outside.bin')), sink),
          throwsA(isA<LanDocumentTransferException>()),
        );
        expect(sink.aborted, isTrue);
        expect(sink.bytes, isEmpty);
      } finally {
        if (await link.exists()) await link.delete();
        await outside.delete(recursive: true);
      }
    },
  );

  test('cancelled export aborts before commit', () async {
    final file = await storage.getSandboxTargetFile('file.bin');
    await file.writeAsBytes(List<int>.filled(40000, 1));
    final sink = _Sink(
      onChunk: () {
        cancelled = true;
      },
    );
    await expectLater(
      export(file, sink),
      throwsA(
        isA<LanDocumentTransferException>().having(
          (error) => error.code,
          'code',
          NetworkErrorCode.cancelled,
        ),
      ),
    );
    expect(sink.aborted, isTrue);
    expect(sink.closed, isFalse);
  });

  for (final failAt in ['write', 'commit']) {
    test(
      'export $failAt failure aborts; abort failure does not hide the copy error',
      () async {
        final file = await storage.getSandboxTargetFile('file.bin');
        await file.writeAsBytes([1]);
        final sink = _Sink(
          failWrite: failAt == 'write',
          failCommit: failAt == 'commit',
          failAbort: true,
        );
        await expectLater(
          export(file, sink),
          throwsA(
            isA<LanDocumentTransferException>().having(
              (error) => error.code,
              'code',
              NetworkErrorCode.ioError,
            ),
          ),
        );
        expect(sink.aborted, isTrue);
      },
    );
  }
}

final class _Source implements LanDocumentSource {
  _Source(this.chunks, {this.sizeBytes, this.onRead, this.closeError});
  final List<Uint8List> chunks;
  final void Function(int index)? onRead;
  final Object? closeError;
  var reads = 0;
  var closed = false;
  @override
  String get displayName => 'document.bin';
  @override
  final int? sizeBytes;
  @override
  Future<Uint8List?> readChunk() async {
    onRead?.call(reads);
    return reads < chunks.length ? chunks[reads++] : null;
  }

  @override
  Future<void> close() async {
    closed = true;
    if (closeError != null) throw closeError!;
  }
}

final class _Sink implements LanDocumentSink {
  _Sink({
    this.onChunk,
    this.failWrite = false,
    this.failCommit = false,
    this.failAbort = false,
  });
  final void Function()? onChunk;
  final bool failWrite;
  final bool failCommit;
  final bool failAbort;
  final bytes = <int>[];
  var largestChunk = 0;
  var closed = false;
  var aborted = false;
  @override
  Future<void> addChunk(Uint8List chunk) async {
    if (failWrite) throw StateError('write failed');
    if (chunk.length > largestChunk) largestChunk = chunk.length;
    bytes.addAll(chunk);
    onChunk?.call();
  }

  @override
  Future<void> close() async {
    if (failCommit) throw StateError('commit failed');
    closed = true;
  }

  @override
  Future<void> abort() async {
    aborted = true;
    if (failAbort) throw StateError('abort failed');
  }
}
