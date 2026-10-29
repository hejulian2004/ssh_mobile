import 'dart:io';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:feature_sftp/feature_sftp.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/android_system_documents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late List<MethodCall> calls;
  late AndroidSystemDocuments documents;
  var failCopy = false;
  var cancelPick = false;
  var unsafeUri = false;
  int? stagedBytes;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('android-documents-');
    calls = [];
    failCopy = false;
    cancelPick = false;
    unsafeUri = false;
    stagedBytes = null;
    const channel = MethodChannel('ssh_mobile/document_access');
    documents = AndroidSystemDocuments(channel: channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'pick':
              if (cancelPick) return null;
              final args = call.arguments as Map<Object?, Object?>;
              final mode = args['mode'];
              if (unsafeUri) return {'uri': 'file:///secret', 'mode': mode};
              if (mode == 'write') {
                return {
                  'uri': 'content://saved/out',
                  'mode': 'write',
                  'displayName': 'out.bin',
                };
              }
              return {
                'uri': 'content://picked/readme',
                'mode': 'read',
                'displayName': r'nested\readme.txt',
                'size': 20 * 1024 + 30,
              };
            case 'copyToCache':
              if (failCopy) {
                throw PlatformException(code: 'DOCUMENT_MISSING');
              }
              final payload = Uint8List.fromList(
                List<int>.generate(20 * 1024 + 30, (index) => index % 251),
              );
              final file = File(
                '${temp.path}${Platform.pathSeparator}cached.bin',
              );
              await file.writeAsBytes(payload, flush: true);
              return {'path': file.path, 'size': payload.length};
            case 'reserveStaging':
              final file = File(
                '${temp.path}${Platform.pathSeparator}stage.bin',
              );
              await file.create();
              return {'path': file.path};
            case 'copyFromCache':
              final path = (call.arguments as Map)['path'] as String;
              stagedBytes = await File(path).length();
              return {'path': path, 'size': stagedBytes};
            case 'release':
              return true;
            default:
              throw PlatformException(code: 'DOCUMENT_IO');
          }
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('ssh_mobile/document_access'),
          null,
        );
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('uses the system picker only on Android', () {
    expect(documents.usesSystemDocuments, Platform.isAndroid);
  });

  test('cancel returns no source and does not copy', () async {
    cancelPick = true;
    final source = await documents.sftp.openForRead(maxBytes: 100);
    expect(source, isNull);
    expect(calls.map((call) => call.method), ['pick']);
  });

  test('a non-content uri fails closed before any copy', () async {
    unsafeUri = true;
    await expectLater(
      documents.sftp.openForRead(maxBytes: 100),
      throwsA(isA<SftpDocumentMissingException>()),
    );
    expect(calls.map((call) => call.method), ['pick']);
  });

  test('known oversize does not copy and release drops the grant', () async {
    final source = await documents.sftp.openForRead(maxBytes: 10);
    expect(source, isNotNull);
    await expectLater(
      source!.readChunk(),
      throwsA(isA<SftpFileSizeLimitException>()),
    );
    expect(calls.map((call) => call.method), isNot(contains('copyToCache')));
    await source.close();
    expect(calls.last.method, 'release');
    expect((calls.last.arguments as Map)['mode'], 'read');
    expect((calls.last.arguments as Map)['uri'], 'content://picked/readme');
  });

  test('read returns bounded chunks and close removes the cache', () async {
    final source = await documents.sftp.openForRead(maxBytes: 1024 * 1024);
    final chunks = <Uint8List>[];
    while (true) {
      final chunk = await source!.readChunk();
      if (chunk == null) break;
      expect(
        chunk.length,
        lessThanOrEqualTo(AndroidSystemDocuments.chunkBytes),
      );
      chunks.add(Uint8List.fromList(chunk));
    }
    expect(chunks.length, greaterThan(1));
    final bytes = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      bytes.add(chunk);
    }
    expect(bytes.takeBytes().length, 20 * 1024 + 30);
    expect(source.displayName, 'readme.txt');
    final cached = File('${temp.path}${Platform.pathSeparator}cached.bin');
    expect(await cached.exists(), isTrue);
    await source.close();
    expect(await cached.exists(), isFalse);
    expect(
      calls.map((call) => call.method),
      containsAll(['copyToCache', 'release']),
    );
  });

  test('a missing document does not yield bytes', () async {
    failCopy = true;
    final source = await documents.lan.openForRead(
      mimeType: 'image/*',
      maxBytes: 1024 * 1024,
    );
    expect((calls.single.arguments as Map)['mimeType'], 'image/*');
    await expectLater(
      source!.readChunk(),
      throwsA(isA<LanDocumentTransferException>()),
    );
    expect(calls.map((call) => call.method), isNot(contains('copyFromCache')));
    await source.close();
    expect(calls.last.method, 'release');
  });

  test('abort releases the write grant without copying', () async {
    final sink = await documents.sftp.createForWrite(suggestedName: r'a/b.txt');
    expect((calls.single.arguments as Map)['suggestedName'], 'b.txt');
    expect((calls.single.arguments as Map)['mode'], 'write');
    await sink!.abort();
    expect(calls.map((call) => call.method), ['pick', 'release']);
    expect((calls.last.arguments as Map)['mode'], 'write');
  });

  test('close copies every staged chunk and then releases', () async {
    final sink = await documents.lan.createForWrite(
      suggestedName: 'clip.mp4',
      mimeType: 'video/*',
    );
    final first = Uint8List.fromList(List<int>.filled(100, 4));
    final second = Uint8List.fromList(List<int>.filled(80, 5));
    await sink!.addChunk(first);
    await sink.addChunk(second);
    await sink.close();
    final methods = calls.map((call) => call.method).toList();
    expect(methods, contains('copyFromCache'));
    expect(methods.last, 'release');
    expect(
      methods.indexOf('copyFromCache'),
      lessThan(methods.indexOf('release')),
    );
    expect(stagedBytes, 180);
    final copied = calls.where((call) => call.method == 'copyFromCache').single;
    expect((copied.arguments as Map)['uri'], 'content://saved/out');
    final staged = File((copied.arguments as Map)['path'] as String);
    expect(await staged.exists(), isFalse);
  });
}
