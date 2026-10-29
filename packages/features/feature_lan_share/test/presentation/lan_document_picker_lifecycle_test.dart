import 'dart:async';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  testWidgets(
    'a picked document is released when its chat closes during picker',
    (tester) async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.pump(
        tester,
        const LanChatScreen(targetDeviceId: 'peer-a', initialAlias: 'Device A'),
      );
      await tester.tap(find.byIcon(Icons.add_circle_outline_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.insert_drive_file_rounded));
      await tester.pumpAndSettle();
      expect(harness.documents.readRequests, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      harness.documents.read.complete(harness.source);
      await tester.pump();
      await tester.pump();
      expect(harness.source.closed, isTrue);
      expect(harness.source.reads, 0);
    },
  );

  testWidgets('a save document is aborted when preview closes during picker', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.pump(
      tester,
      LanPreviewViewerScreen(
        message: LanMessage(
          id: 'message-1',
          senderId: 'peer-a',
          receiverId: 'test-device',
          senderAlias: 'Device A',
          payloadType: LanPayloadType.file,
          fileName: 'file.bin',
          localPath: 'sandbox-fixture.bin',
          status: LanTransferStatus.completed,
          createdAt: DateTime.utc(2026),
          isIncoming: true,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pump();
    expect(harness.documents.writeRequests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    harness.documents.write.complete(harness.sink);
    await tester.pump();
    await tester.pump();
    expect(harness.sink.aborted, isTrue);
    expect(harness.sink.closed, isFalse);
  });
}

final class _Harness {
  _Harness() {
    viewModel = _OnlineViewModel(
      discoveryService: FakeLanDiscoveryService(),
      securityService: _PairedSecurity(),
      storageService: FakeLanStorageService(),
      transferService: _IdleTransfer(),
      historyDao: FakeLanHistoryDao(),
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
    );
  }

  final settings = FakeLanShareSettings(english: true);
  final documents = _Documents();
  final source = _Source();
  final sink = _Sink();
  late final LanShareViewModel viewModel;

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
          ChangeNotifierProvider<LanShareViewModel>.value(value: viewModel),
          Provider<LanDocumentAccessPort>.value(value: documents),
        ],
        child: MaterialApp(home: page),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  void dispose() {
    viewModel.dispose();
    settings.dispose();
  }
}

final class _PairedSecurity extends Fake implements LanSecurityService {
  @override
  Future<bool> isDevicePaired(
    String deviceId, {
    String? ip,
    int? port,
    String? localDeviceId,
  }) async => true;
}

final class _OnlineViewModel extends LanShareViewModel {
  _OnlineViewModel({
    required super.discoveryService,
    required super.securityService,
    required super.storageService,
    required super.transferService,
    required super.historyDao,
    required super.appSettings,
    required super.dataProtection,
    required super.logger,
  }) : super(ownsRuntime: false);

  @override
  LanPeerViewState? peerStateFor(String deviceId) => LanPeerViewState(
    discovery: LanDiscoveredPeer(
      deviceId: deviceId,
      alias: 'Device A',
      ip: '192.0.2.1',
      controlPort: 7443,
      os: 'Android',
      lastSeen: DateTime.utc(2026),
    ),
  );
}

final class _IdleTransfer extends Fake implements LanTransferService {
  @override
  bool isWebSocketConnected(String deviceId) => false;
}

final class _Documents implements LanDocumentAccessPort {
  final read = Completer<LanDocumentSource?>();
  final write = Completer<LanDocumentSink?>();
  var readRequests = 0;
  var writeRequests = 0;
  @override
  bool get usesSystemDocuments => true;
  @override
  Future<LanDocumentSource?> openForRead({
    required String mimeType,
    required int maxBytes,
  }) {
    readRequests++;
    return read.future;
  }

  @override
  Future<LanDocumentSink?> createForWrite({
    required String suggestedName,
    required String mimeType,
  }) {
    writeRequests++;
    return write.future;
  }
}

final class _Source implements LanDocumentSource {
  var closed = false;
  var reads = 0;
  @override
  String get displayName => 'document.bin';
  @override
  int? get sizeBytes => 0;
  @override
  Future<Uint8List?> readChunk() async {
    reads++;
    return null;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _Sink implements LanDocumentSink {
  var closed = false;
  var aborted = false;
  @override
  Future<void> addChunk(Uint8List bytes) async {}
  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> abort() async {
    aborted = true;
  }
}
