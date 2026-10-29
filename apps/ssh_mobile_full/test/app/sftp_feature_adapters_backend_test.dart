// SFTP Feature Backend 适配器与 Module Scope 测试。

import 'dart:typed_data';

import 'package:feature_sftp/feature_sftp.dart' as feature_sftp;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/sftp_feature_adapters.dart';
import 'package:ssh_mobile/services/sftp_service.dart' as legacy_sftp;

import 'support/feature_adapter_test_fakes.dart';

void main() {
  test('backend exposes legacy state and maps entries and transfers', () {
    final service = FakeSftpService(
      state: legacy_sftp.SftpConnectionState.loading,
    );
    service.entries = <legacy_sftp.SftpEntry>[_legacyEntry('file.txt')];
    service.activeTransfer = legacy_sftp.SftpTransferState(
      id: 't1',
      name: 'up.bin',
      totalBytes: 100,
      isUpload: true,
      bytesTransferred: 40,
      isError: true,
      errorMessage: 'boom',
    );
    service.hasActiveTransfer = true;
    service.busyResult = true;
    service.isBusy = true;
    service.openResult = false;

    final adapter = AppSftpBackendAdapter(service);

    expect(adapter.connectionId, 'conn-1');
    expect(adapter.targetFingerprint, 'fingerprint');
    expect(adapter.connectionName, 'Server A');
    expect(adapter.currentPath, '/home/user');
    expect(adapter.state, feature_sftp.SftpConnectionState.loading);
    expect(adapter.errorMessage, 'recent error');
    expect(adapter.entriesRevision, 7);
    expect(adapter.isConnected, isTrue);
    expect(adapter.isBusy, isTrue);
    expect(adapter.isConnectionBusy('x'), isTrue);
    expect(adapter.isConnectionOpen('x'), isFalse);

    final entry = adapter.entries.single;
    expect(entry.connectionId, 'conn-1');
    expect(entry.targetFingerprint, 'fp-1');
    expect(entry.name, 'file.txt');
    expect(entry.path, '/file.txt');
    expect(entry.lowerName, 'file.txt');
    expect(entry.isDirectory, isFalse);
    expect(entry.isLink, isTrue);
    expect(entry.size, 12);
    expect(entry.sizeLabel, '12 B');
    expect(entry.modifiedAt, isNotNull);
    expect(entry.modifiedLabel, 'now');

    final transfer = adapter.activeTransfer!;
    expect(transfer.id, 't1');
    expect(transfer.name, 'up.bin');
    expect(transfer.totalBytes, 100);
    expect(transfer.isUpload, isTrue);
    expect(transfer.bytesTransferred, 40);
    expect(transfer.isCancelled, isFalse);
    expect(transfer.isError, isTrue);
    expect(transfer.errorMessage, 'boom');
    expect(adapter.hasActiveTransfer, isTrue);
  });

  test(
    'backend reports no active transfer when the legacy service has none',
    () {
      final adapter = AppSftpBackendAdapter(FakeSftpService());

      expect(adapter.activeTransfer, isNull);
      expect(adapter.hasActiveTransfer, isFalse);
    },
  );

  test('backend forwards listener add/remove to the legacy service', () {
    final service = FakeSftpService();
    final adapter = AppSftpBackendAdapter(service);
    void listener() {}

    adapter.addListener(listener);
    expect(service.listenerCount, 1);
    adapter.removeListener(listener);
    expect(service.listenerCount, 0);
  });

  test('backend connect forwards a converted host key callback', () async {
    final service = FakeSftpService()..invokeHostKeyCallback = true;
    final adapter = AppSftpBackendAdapter(service);
    ssh_core.SshHostKeyPromptRequest? seenRequest;

    await adapter.connect(
      'conn-1',
      onUnknownHostKey: (request) async {
        seenRequest = request;
        return request.fingerprint == 'SHA256:hostkey';
      },
    );

    expect(seenRequest, isA<ssh_core.SshHostKeyPromptRequest>());
    expect(seenRequest!.connectionId, 'conn-1');
    expect(seenRequest!.connectionName, 'Server A');
    expect(seenRequest!.host, '10.0.0.1');
    expect(seenRequest!.port, 22);
    expect(seenRequest!.username, 'root');
    expect(seenRequest!.algorithm, 'ssh-ed25519');
    expect(seenRequest!.fingerprint, 'SHA256:hostkey');
    expect(service.hostKeyCallbackResult, isTrue);
    expect(service.lastConnectConnectionId, 'conn-1');
  });

  test('backend connect passes no host key callback when omitted', () async {
    final service = FakeSftpService();
    final adapter = AppSftpBackendAdapter(service);

    await adapter.connect('conn-2', onUnknownHostKey: null);

    expect(service.lastConnectConnectionId, 'conn-2');
    expect(service.lastHostKeyCallback, isNull);
  });

  test(
    'backend forwards directory, content, and lifecycle operations',
    () async {
      final service = FakeSftpService();
      service.listResult = <legacy_sftp.SftpEntry>[_legacyEntry('a.txt')];
      final adapter = AppSftpBackendAdapter(service);
      final entry = _featureEntry('a.txt');
      final bytes = Uint8List.fromList(<int>[9, 8]);

      await adapter.refresh();
      await adapter.uploadBytes(filename: 'u.bin', bytes: bytes);
      await adapter.uploadFile(localPath: '/tmp/a', filename: 'a.txt');
      await adapter.deleteEntry(entry, confirmedName: 'a.txt');

      final listed = await adapter.listDirectoryForConnection('c1', '/tmp');
      expect(listed.single.name, 'a.txt');

      final text = await adapter.readTextPathForConnection(
        connectionId: 'c1',
        path: '/a.txt',
        maxBytes: 10,
      );
      expect(text, 'text');

      final downloaded = await adapter.downloadPathForConnection(
        connectionId: 'c1',
        path: '/a.bin',
        maxBytes: 20,
      );
      expect(downloaded, hasLength(3));

      await adapter.downloadFile(entry, localPath: '/tmp/a', maxBytes: 30);

      final info = await adapter.statPathForConnection(
        connectionId: 'c1',
        path: '/dir',
      );
      expect(info.path, '/dir');
      expect(info.isDirectory, isTrue);
      expect(info.isLink, isFalse);
      expect(info.size, 42);
      expect(info.sizeLabel, '42 B');
      expect(info.modifiedAt, isNotNull);

      await adapter.writeTextPathForConnection(
        connectionId: 'c1',
        path: '/a.txt',
        text: 'hi',
        maxBytes: 40,
      );
      await adapter.uploadBytesPathForConnection(
        connectionId: 'c1',
        path: '/u.bin',
        bytes: bytes,
        maxBytes: 50,
      );
      await adapter.createDirectoryPathForConnection(
        connectionId: 'c1',
        path: '/new',
      );
      await adapter.renamePathForConnection(
        connectionId: 'c1',
        path: '/a',
        newPath: '/b',
      );
      await adapter.deletePathForConnection(connectionId: 'c1', path: '/a');
      await adapter.openPath('/open');
      await adapter.openParent();
      await adapter.disconnect(notify: false);
      await adapter.disconnectConnection('c1', notify: false, forgetPath: true);
      await adapter.disconnectAll(notify: false);
      adapter.cancelActiveTransfer();
      final memBytes = await adapter.downloadBytes(
        entry,
        maxBytes: 60,
        updateState: true,
        bypassCache: true,
      );
      expect(memBytes, hasLength(3));
      final fileText = await adapter.readTextFile(entry, maxBytes: 70);
      expect(fileText, 'text');
      await adapter.saveTextFile(entry, 'saved', maxBytes: 80);

      expect(service.refreshCalls, 1);
      expect(service.uploadedFilenames, <String>['u.bin']);
      expect(service.uploadedLocalPaths, <String>['/tmp/a']);
      expect(service.deletedEntries.single.name, 'a.txt');
      expect(service.confirmedDeleteNames.single, 'a.txt');
      expect(service.listedDirectories.single.path, '/tmp');
      expect(service.reads.single.maxBytes, 10);
      expect(service.downloads.single.maxBytes, 20);
      expect(service.fileDownloads.single.maxBytes, 30);
      expect(service.stats.single.path, '/dir');
      expect(service.writeTexts.single.text, 'hi');
      expect(service.byteUploads.single.maxBytes, 50);
      expect(service.createdDirectories.single.path, '/new');
      expect(service.renames.single.newPath, '/b');
      expect(service.deletedPaths.single.path, '/a');
      expect(service.openedPaths.single, '/open');
      expect(service.openParentCalls, 1);
      expect(service.disconnectNotifies.single, isFalse);
      expect(service.connectionDisconnects.single.forgetPath, isTrue);
      expect(service.disconnectAllCalls, 1);
      expect(service.cancelActiveTransferCalls, 1);
      expect(service.readTextFiles.single.maxBytes, 70);
      expect(service.savedTextFiles.single.text, 'saved');
    },
  );

  test('backend translates legacy SFTP exceptions', () async {
    final service = FakeSftpService();
    final adapter = AppSftpBackendAdapter(service);

    service.nextError = legacy_sftp.SftpTransferCancelledException('bye');
    await expectLater(
      adapter.refresh(),
      throwsA(
        isA<feature_sftp.SftpTransferCancelledException>().having(
          (e) => e.message,
          'message',
          'bye',
        ),
      ),
    );

    service.nextError = legacy_sftp.SftpTextSizeLimitException(
      actualBytes: 11,
      maxBytes: 10,
    );
    await expectLater(
      adapter.refresh(),
      throwsA(
        isA<feature_sftp.SftpTextSizeLimitException>()
            .having((e) => e.actualBytes, 'actualBytes', 11)
            .having((e) => e.maxBytes, 'maxBytes', 10),
      ),
    );

    service.nextError = legacy_sftp.SftpFileSizeLimitException(
      observedBytes: 101,
      maxBytes: 100,
    );
    await expectLater(
      adapter.refresh(),
      throwsA(
        isA<feature_sftp.SftpFileSizeLimitException>()
            .having((e) => e.observedBytes, 'observedBytes', 101)
            .having((e) => e.maxBytes, 'maxBytes', 100),
      ),
    );

    service.nextError = legacy_sftp.SftpTargetChangedException();
    await expectLater(
      adapter.refresh(),
      throwsA(isA<feature_sftp.SftpTargetChangedException>()),
    );
  });

  test('backend rethrows untranslated legacy errors unchanged', () async {
    final service = FakeSftpService();
    final adapter = AppSftpBackendAdapter(service);
    final failure = StateError('plain');

    service.nextError = failure;
    await expectLater(adapter.refresh(), throwsA(same(failure)));
  });
}

legacy_sftp.SftpEntry _legacyEntry(String name) {
  return legacy_sftp.SftpEntry(
    connectionId: 'conn-1',
    targetFingerprint: 'fp-1',
    name: name,
    path: '/$name',
    lowerName: name,
    isDirectory: false,
    isLink: true,
    size: 12,
    sizeLabel: '12 B',
    modifiedAt: DateTime.fromMillisecondsSinceEpoch(2),
    modifiedLabel: 'now',
  );
}

feature_sftp.SftpEntry _featureEntry(String name) {
  return feature_sftp.SftpEntry(
    connectionId: 'conn-1',
    targetFingerprint: 'fp-1',
    name: name,
    path: '/$name',
    lowerName: name,
    isDirectory: false,
    isLink: true,
    size: 12,
    sizeLabel: '12 B',
    modifiedAt: DateTime.fromMillisecondsSinceEpoch(2),
    modifiedLabel: 'now',
  );
}
