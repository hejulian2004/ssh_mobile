import 'dart:async';
import 'dart:io';

import 'package:feature_sftp/feature_sftp.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/android_system_documents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AndroidSystemDocuments documents;
  late List<MethodCall> calls;
  Future<Object?> Function(MethodCall)? override;
  const channel = MethodChannel('ssh_mobile/document_access');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('document-cache-');
    documents = AndroidSystemDocuments(channel: channel);
    calls = [];
    override = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final replacement = override;
          if (replacement != null) return replacement(call);
          switch (call.method) {
            case 'pick':
              return {
                'uri': 'content://documents/item',
                'mode': (call.arguments as Map)['mode'],
                'displayName': 'file.bin',
              };
            case 'copyToCache':
              final file = File('${temp.path}/read.bin');
              await file.writeAsBytes([1, 2]);
              return {'path': file.path, 'size': 2};
            case 'reserveStaging':
              final file = File('${temp.path}/write.bin');
              await file.create();
              return {'path': file.path};
            case 'copyFromCache':
            case 'release':
              return true;
          }
          throw MissingPluginException();
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temp.delete(recursive: true);
  });

  test('a closed source cannot reopen its revoked document', () async {
    final source = (await documents.sftp.openForRead(maxBytes: 10))!;
    await source.close();
    await expectLater(
      source.readChunk(),
      throwsA(isA<SftpDocumentIoException>()),
    );
    expect(calls.map((call) => call.method), ['pick', 'release']);
  });

  test('a truncated cache is an error instead of successful EOF', () async {
    final source = (await documents.sftp.openForRead(maxBytes: 10))!;
    expect(await source.readChunk(), [1, 2]);
    await File('${temp.path}/read.bin').writeAsBytes([]);
    // A fresh bridge response falsely reporting more bytes must also fail.
    await source.close();
    await File('${temp.path}/read.bin').writeAsBytes([]);
    override = (call) async {
      if (call.method == 'pick') {
        return {'uri': 'content://documents/item', 'mode': 'read'};
      }
      if (call.method == 'copyToCache') {
        return {'path': '${temp.path}/read.bin', 'size': 3};
      }
      return true;
    };
    final truncated = (await documents.sftp.openForRead(maxBytes: 10))!;
    await expectLater(
      truncated.readChunk(),
      throwsA(isA<SftpDocumentIoException>()),
    );
    await truncated.close();
    expect(await File('${temp.path}/read.bin').exists(), isFalse);
  });

  test('closing during cache preparation discards the late file', () async {
    final source = (await documents.sftp.openForRead(maxBytes: 10))!;
    final ready = Completer<void>();
    final resume = Completer<void>();
    override = (call) async {
      if (call.method == 'copyToCache') {
        ready.complete();
        await resume.future;
        final file = File('${temp.path}/late.bin');
        await file.writeAsBytes([1]);
        return {'path': file.path, 'size': 1};
      }
      return true;
    };
    final read = source.readChunk();
    final failed = expectLater(read, throwsA(isA<SftpDocumentIoException>()));
    await ready.future;
    final closed = source.close();
    resume.complete();
    await closed;
    await failed;
    expect(await File('${temp.path}/late.bin').exists(), isFalse);
    expect(calls.where((call) => call.method == 'release'), hasLength(1));
  });

  test('a failed commit remains failed on repeated close', () async {
    final sink = (await documents.sftp.createForWrite(suggestedName: 'file'))!;
    await sink.addChunk(Uint8List.fromList([1]));
    override = (call) async {
      if (call.method == 'copyFromCache') {
        throw PlatformException(code: 'DOCUMENT_IO');
      }
      return true;
    };
    await expectLater(sink.close(), throwsA(isA<SftpDocumentIoException>()));
    await expectLater(sink.close(), throwsA(isA<SftpDocumentIoException>()));
    expect(await File('${temp.path}/write.bin').exists(), isFalse);
    expect(calls.where((call) => call.method == 'copyFromCache'), hasLength(1));
    expect(calls.where((call) => call.method == 'release'), hasLength(1));
  });

  test('aborted targets cannot report a successful commit', () async {
    final sink = (await documents.sftp.createForWrite(suggestedName: 'file'))!;
    await sink.abort();
    await expectLater(sink.close(), throwsA(isA<SftpDocumentIoException>()));
    await expectLater(
      sink.addChunk(Uint8List(1)),
      throwsA(isA<SftpDocumentIoException>()),
    );
    expect(calls.map((call) => call.method), ['pick', 'release']);
  });

  test('unavailable plugin errors stay inside the document contract', () async {
    override = (_) async =>
        throw MissingPluginException('private-native-detail');
    await expectLater(
      documents.sftp.openForRead(maxBytes: 10),
      throwsA(isA<SftpDocumentIoException>()),
    );
  });

  test(
    'pick validates the returned mode and releases a mismatched grant',
    () async {
      override = (call) async {
        if (call.method == 'pick') {
          return {'uri': 'content://documents/item', 'mode': 'write'};
        }
        return true;
      };
      await expectLater(
        documents.sftp.openForRead(maxBytes: 10),
        throwsA(isA<SftpDocumentMissingException>()),
      );
      expect(calls.map((call) => call.method), ['pick', 'release']);
    },
  );

  test('abort while staging is reserved removes the late file', () async {
    final sink = (await documents.sftp.createForWrite(suggestedName: 'file'))!;
    final ready = Completer<void>();
    final resume = Completer<void>();
    override = (call) async {
      if (call.method == 'reserveStaging') {
        ready.complete();
        await resume.future;
        final file = await File('${temp.path}/late-write.bin').create();
        return {'path': file.path};
      }
      return true;
    };
    final writing = sink.addChunk(Uint8List(1));
    final failed = expectLater(
      writing,
      throwsA(isA<SftpDocumentIoException>()),
    );
    await ready.future;
    final aborting = sink.abort();
    var secondFinished = false;
    final secondAbort = sink.abort().then((_) => secondFinished = true);
    await Future<void>.delayed(Duration.zero);
    final finishedBeforeCleanup = secondFinished;
    resume.complete();
    await aborting;
    await secondAbort;
    await failed;
    expect(finishedBeforeCleanup, isFalse);
    expect(await File('${temp.path}/late-write.bin').exists(), isFalse);
  });

  test('empty documents commit once and reject subsequent writes', () async {
    final sink = (await documents.sftp.createForWrite(suggestedName: '..'))!;
    expect((calls.single.arguments as Map)['suggestedName'], 'download');
    await sink.addChunk(Uint8List(0));
    await sink.close();
    await sink.close();
    await expectLater(
      sink.addChunk(Uint8List(1)),
      throwsA(isA<SftpDocumentIoException>()),
    );
    await sink.abort();
    expect(calls.where((call) => call.method == 'copyFromCache'), hasLength(1));
    expect(calls.where((call) => call.method == 'release'), hasLength(1));
  });

  test(
    'closing a pending import cancels that native copy before draining',
    () async {
      final source = (await documents.sftp.openForRead(maxBytes: 10))!;
      final started = Completer<void>();
      final complete = Completer<void>();
      override = (call) async {
        if (call.method == 'copyToCache') {
          started.complete();
          await complete.future;
          throw PlatformException(code: 'DOCUMENT_CANCELLED');
        }
        return true;
      };
      final reading = source.readChunk();
      final checked = expectLater(
        reading,
        throwsA(isA<SftpTransferCancelledException>()),
      );
      await started.future;
      final closing = source.close();
      try {
        await Future<void>.delayed(Duration.zero);
        final operation =
            (calls.firstWhere((c) => c.method == 'copyToCache').arguments
                as Map)['operationId'];
        expect(operation, isA<String>());
        final cancel = calls.where((c) => c.method == 'cancelCopy').single;
        expect((cancel.arguments as Map)['operationId'], operation);
      } finally {
        complete.complete();
        await closing;
        await checked;
      }
    },
  );

  test(
    'file and native errors use typed results without private detail',
    () async {
      for (final code in [
        'DOCUMENT_IO',
        'DOCUMENT_MISSING',
        'DOCUMENT_DENIED',
        'UNEXPECTED',
      ]) {
        override = (_) async =>
            throw PlatformException(code: code, message: 'private-data');
        await expectLater(
          documents.sftp.createForWrite(suggestedName: 'file'),
          throwsA(
            anyOf(
              isA<SftpDocumentIoException>(),
              isA<SftpDocumentMissingException>(),
            ),
          ),
        );
        await expectLater(
          documents.lan.createForWrite(suggestedName: 'file', mimeType: '*/*'),
          throwsA(isA<LanDocumentTransferException>()),
        );
      }
      override = (_) async => false;
      await expectLater(
        documents.sftp.openForRead(maxBytes: 10),
        throwsA(isA<SftpDocumentMissingException>()),
      );
    },
  );

  test('size limit errors report the actual caller limit', () async {
    override = (call) async {
      if (call.method == 'pick') {
        return {'uri': 'content://documents/item', 'mode': 'read', 'size': 100};
      }
      return true;
    };
    final source = (await documents.sftp.openForRead(maxBytes: 10))!;
    await expectLater(
      source.readChunk(),
      throwsA(
        isA<SftpFileSizeLimitException>()
            .having((e) => e.maxBytes, 'limit', 10)
            .having((e) => e.observedBytes, 'observed', 100),
      ),
    );
    await source.close();
  });

  test(
    'cache metadata cannot disguise an oversized or malformed file',
    () async {
      for (final raw in [
        null,
        {'path': '', 'size': -1},
        {'path': '${temp.path}/unknown', 'size': 100},
      ]) {
        override = (call) async {
          if (call.method == 'pick') {
            return {
              'uri': 'content://documents/item',
              'mode': 'read',
              'displayName': '../\u0000note',
            };
          }
          if (call.method == 'copyToCache') return raw;
          return true;
        };
        final source = (await documents.sftp.openForRead(maxBytes: 10))!;
        expect(source.displayName, '_note');
        await expectLater(
          source.readChunk(),
          throwsA(
            anyOf(
              isA<SftpDocumentMissingException>(),
              isA<SftpDocumentIoException>(),
              isA<SftpFileSizeLimitException>(),
            ),
          ),
        );
        await source.close();
      }
    },
  );

  test('LAN sources and SFTP sinks both preserve chunked contents', () async {
    final source = (await documents.lan.openForRead(
      mimeType: 'text/*',
      maxBytes: 10,
    ))!;
    expect(source.displayName, 'file.bin');
    expect(source.sizeBytes, isNull);
    expect(await source.readChunk(), [1, 2]);
    expect(await source.readChunk(), isNull);
    await source.close();
    await source.close();
    final sink = (await documents.sftp.createForWrite(suggestedName: 'file'))!;
    await sink.addChunk(Uint8List.fromList([1, 2]));
    await sink.close();
  });

  test('LAN unknown length oversize and sink errors are typed', () async {
    final source = (await documents.lan.openForRead(
      mimeType: '*/*',
      maxBytes: 1,
    ))!;
    await expectLater(
      source.readChunk(),
      throwsA(isA<LanDocumentTransferException>()),
    );
    await source.close();
    final sink = (await documents.lan.createForWrite(
      suggestedName: 'file',
      mimeType: '*/*',
    ))!;
    override = (call) async {
      if (call.method == 'reserveStaging') return {'path': ''};
      return true;
    };
    await expectLater(
      sink.addChunk(Uint8List(1)),
      throwsA(isA<LanDocumentTransferException>()),
    );
    await sink.abort();
    override = (_) async => null;
    final empty = (await documents.sftp.createForWrite(suggestedName: 'file'));
    expect(empty, isNull);
  });

  test(
    'aborting native export cancels that attempt and retains its failure',
    () async {
      final sink = (await documents.lan.createForWrite(
        suggestedName: 'file',
        mimeType: '*/*',
      ))!;
      await sink.addChunk(Uint8List.fromList([1, 2]));
      final started = Completer<void>();
      final stopped = Completer<void>();
      override = (call) async {
        if (call.method == 'copyFromCache') {
          started.complete();
          await stopped.future;
          throw PlatformException(code: 'DOCUMENT_CANCELLED');
        }
        if (call.method == 'cancelCopy') stopped.complete();
        return true;
      };
      final committing = sink.close();
      final checked = expectLater(
        committing,
        throwsA(isA<LanDocumentTransferException>()),
      );
      await started.future;
      await sink.abort();
      await checked;
      final copy = calls.firstWhere((c) => c.method == 'copyFromCache');
      final cancel = calls.firstWhere((c) => c.method == 'cancelCopy');
      expect(
        (cancel.arguments as Map)['operationId'],
        (copy.arguments as Map)['operationId'],
      );
      expect(await File('${temp.path}/write.bin').exists(), isFalse);
      expect(calls.where((c) => c.method == 'release'), hasLength(1));
    },
  );

  test('a late native success cannot override a requested abort', () async {
    final sink = (await documents.sftp.createForWrite(suggestedName: 'file'))!;
    final started = Completer<void>();
    final resume = Completer<void>();
    override = (call) async {
      if (call.method == 'reserveStaging') {
        final file = await File('${temp.path}/race.bin').create();
        return {'path': file.path};
      }
      if (call.method == 'copyFromCache') {
        started.complete();
        await resume.future;
      }
      if (call.method == 'cancelCopy') resume.complete();
      return true;
    };
    final committing = sink.close();
    final checked = expectLater(
      committing,
      throwsA(isA<SftpTransferCancelledException>()),
    );
    await started.future;
    await sink.abort();
    await checked;
    expect(await File('${temp.path}/race.bin').exists(), isFalse);
  });
}
