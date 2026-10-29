import 'dart:io';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:provider/provider.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  for (final selection in <(IconData, String)>[
    (Icons.photo_library_rounded, 'image/*'),
    (Icons.video_library_rounded, 'video/*'),
    (Icons.insert_drive_file_rounded, '*/*'),
  ]) {
    testWidgets(
      'system picker forwards ${selection.$2} and the selected peer',
      (tester) async {
        final harness = _Harness();
        addTearDown(harness.dispose);
        await harness.pump(tester);
        await harness.choose(tester, selection.$1);
        expect(harness.documents.requests.single, (
          selection.$2,
          LanDocumentLimits.maxSendBytes,
        ));
        expect(harness.viewModel.documentPeer, 'peer-a');
        expect(harness.viewModel.discoveryPeer, 'peer-a');
        expect(harness.documents.source.closed, isTrue);
        expect(harness.viewModel.pathSent, isNull);
      },
    );
  }

  testWidgets('system picker cancellation submits nothing', (tester) async {
    final harness = _Harness()..documents.cancelled = true;
    addTearDown(harness.dispose);
    await harness.pump(tester);
    await harness.choose(tester, Icons.insert_drive_file_rounded);
    expect(harness.viewModel.documentPeer, isNull);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('picker exceptions use a bounded error without private details', (
    tester,
  ) async {
    final harness = _Harness()
      ..documents.error = StateError('private URI must not escape');
    addTearDown(harness.dispose);
    await harness.pump(tester);
    await harness.choose(tester, Icons.insert_drive_file_rounded);
    expect(find.text('Failed to send file'), findsOneWidget);
    expect(find.textContaining('private URI'), findsNothing);
  });

  for (final english in [true, false]) {
    for (final detail in ['No route', '']) {
      testWidgets(
        'attachment failures explain the action in locale $english with detail "$detail"',
        (tester) async {
          final harness = _Harness(english: english)
            ..viewModel.error = NetworkError(
              code: NetworkErrorCode.noRoute,
              message: detail,
              operation: NetworkOperation.sendFile,
            );
          addTearDown(harness.dispose);
          await harness.pump(tester);
          await harness.choose(tester, Icons.video_library_rounded);
          final prefix = english ? 'Failed to send video' : '发送视频失败';
          final suffix = detail.isEmpty ? '' : '${english ? ': ' : '：'}$detail';
          expect(find.text('$prefix$suffix'), findsOneWidget);
        },
      );
    }
  }

  testWidgets(
    'authentication failure uses the existing E2E rejection message',
    (tester) async {
      final harness = _Harness()
        ..viewModel.error = const NetworkError(
          code: NetworkErrorCode.authenticationFailed,
          message: 'Denied',
          operation: NetworkOperation.sendFile,
        );
      addTearDown(harness.dispose);
      await harness.pump(tester);
      await harness.choose(tester, Icons.photo_library_rounded);
      expect(find.text('对方不支持端对端加密，已拒绝发送'), findsOneWidget);
    },
  );

  for (final selection in <(IconData, FileType)>[
    (Icons.photo_library_rounded, FileType.image),
    (Icons.video_library_rounded, FileType.video),
    (Icons.insert_drive_file_rounded, FileType.any),
  ]) {
    testWidgets('path picker remains available for ${selection.$2.name}', (
      tester,
    ) async {
      final picker = _PathPicker();
      final original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = original);
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.pump(tester, includeDocuments: false);
      await harness.choose(tester, selection.$1);
      expect(picker.type, selection.$2);
      expect(harness.viewModel.pathSent, '/fixture/picked.bin');
      expect(harness.viewModel.documentPeer, isNull);
    });
  }

  testWidgets(
    'a disabled document port and cancelled path picker submit nothing',
    (tester) async {
      final picker = _PathPicker()..cancelled = true;
      final original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = original);
      final harness = _Harness()..documents.enabled = false;
      addTearDown(harness.dispose);
      await harness.pump(tester);
      await harness.choose(tester, Icons.insert_drive_file_rounded);
      expect(harness.viewModel.pathSent, isNull);
      expect(harness.documents.requests, isEmpty);
    },
  );

  testWidgets('path send failure uses the same bounded failure presentation', (
    tester,
  ) async {
    final picker = _PathPicker();
    final original = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);
    final harness = _Harness()
      ..viewModel.error = const NetworkError(
        code: NetworkErrorCode.noRoute,
        message: 'No route',
        operation: NetworkOperation.sendFile,
      );
    addTearDown(harness.dispose);
    await harness.pump(tester, includeDocuments: false);
    await harness.choose(tester, Icons.insert_drive_file_rounded);
    expect(find.text('Failed to send file: No route'), findsOneWidget);
  });

  for (final text in ['clipboard fixture', '']) {
    testWidgets('clipboard selection uses only nonempty text: "$text"', (
      tester,
    ) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') return {'text': text};
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.pump(tester);
      await harness.choose(tester, Icons.content_paste_rounded);
      expect(harness.viewModel.clipboardText, text.isEmpty ? null : text);
    });
  }

  testWidgets('clipboard authentication failures keep the E2E guard', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') return {'text': 'fixture'};
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final harness = _Harness()
      ..viewModel.error = const NetworkError(
        code: NetworkErrorCode.authenticationFailed,
        message: 'Denied',
        operation: NetworkOperation.sendFile,
      );
    addTearDown(harness.dispose);
    await harness.pump(tester);
    await harness.choose(tester, Icons.content_paste_rounded);
    expect(find.text('对方不支持端对端加密，已拒绝发送'), findsOneWidget);
  });
}

final class _Harness {
  _Harness({bool english = true}) : settings = _Settings(english) {
    viewModel = _ViewModel(
      discoveryService: FakeLanDiscoveryService(),
      securityService: _PairedSecurity(),
      storageService: _Storage(),
      transferService: FakeLanTransferService(),
      historyDao: FakeLanHistoryDao(),
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
    );
  }
  final _Settings settings;
  final documents = _Documents();
  late final _ViewModel viewModel;

  Future<void> pump(WidgetTester tester, {bool includeDocuments = true}) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
          ChangeNotifierProvider<LanShareViewModel>.value(value: viewModel),
          if (includeDocuments)
            Provider<LanDocumentAccessPort>.value(value: documents),
        ],
        child: const MaterialApp(
          home: LanChatScreen(
            targetDeviceId: 'peer-a',
            initialAlias: 'Device A',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> choose(WidgetTester tester, IconData icon) async {
    await tester.tap(find.byIcon(Icons.add_circle_outline_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(icon));
    await tester.pumpAndSettle();
  }

  void dispose() {
    viewModel.dispose();
    settings.dispose();
  }
}

final class _Settings extends ChangeNotifier implements LanShareSettingsPort {
  _Settings(this.isEnglish) : strings = FakeLanShareStrings(english: isEnglish);
  @override
  final bool isEnglish;
  @override
  final LanShareStrings strings;
  @override
  String get lanDeviceId => 'test-device';
  @override
  String get lanDeviceAlias => 'Test Device';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

final class _ViewModel extends LanShareViewModel {
  _ViewModel({
    required super.discoveryService,
    required super.securityService,
    required super.storageService,
    required super.transferService,
    required super.historyDao,
    required super.appSettings,
    required super.dataProtection,
    required super.logger,
  }) : super(ownsRuntime: false);
  String? documentPeer;
  String? discoveryPeer;
  String? pathSent;
  String? clipboardText;
  NetworkError? error;
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
  @override
  Future<NetworkResult<TransferSession>> sendFile({
    required String peerId,
    required String filePath,
    LanDiscoveredPeer? discovery,
  }) async {
    if (filePath == '/fixture/document.bin') {
      documentPeer = peerId;
      discoveryPeer = discovery?.deviceId;
    } else {
      pathSent = filePath;
    }
    return _result(filePath);
  }

  NetworkResult<TransferSession> _result(String path) => error != null
      ? NetworkFailure(error!)
      : NetworkSuccess(
          TransferSession(
            transferId: 'transfer-1',
            peerId: 'peer-a',
            filePath: path,
            routeType: NetworkRouteType.lan,
          ),
        );
  @override
  Future<NetworkResult<void>> sendClipboard(
    LanDiscoveredPeer peer,
    String text,
  ) async {
    clipboardText = text;
    return error != null ? NetworkFailure(error!) : const NetworkSuccess(null);
  }
}

final class _Storage extends LanStorageService {
  @override
  Future<bool> hasSufficientSpace(int requiredBytes) async => true;
  @override
  Future<File> getSandboxTargetFile(String fileName) async => _StagedFile();
  @override
  Future<bool> deleteSandboxFile(String localPath) async => true;
}

final class _StagedFile extends Fake implements File {
  @override
  String get path => '/fixture/document.bin';
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _StagedHandle();
}

final class _StagedHandle extends Fake implements RandomAccessFile {
  @override
  Future<RandomAccessFile> flush() async => this;
  @override
  Future<void> close() async {}
}

final class _Documents implements LanDocumentAccessPort {
  var enabled = true;
  var cancelled = false;
  Object? error;
  final source = _Source();
  final requests = <(String, int)>[];
  @override
  bool get usesSystemDocuments => enabled;
  @override
  Future<LanDocumentSource?> openForRead({
    required String mimeType,
    required int maxBytes,
  }) async {
    requests.add((mimeType, maxBytes));
    if (error != null) throw error!;
    return cancelled ? null : source;
  }

  @override
  Future<LanDocumentSink?> createForWrite({
    required String suggestedName,
    required String mimeType,
  }) async => null;
}

final class _Source implements LanDocumentSource {
  var closed = false;
  @override
  String get displayName => 'document.bin';
  @override
  int? get sizeBytes => 0;
  @override
  Future<Uint8List?> readChunk() async => null;
  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _PathPicker extends FilePickerPlatform {
  FileType? type;
  bool cancelled = false;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
    AndroidSAFOptions? androidSafOptions,
  }) async {
    this.type = type;
    return cancelled
        ? null
        : FilePickerResult([
            PlatformFile(
              name: 'picked.bin',
              size: 1,
              path: '/fixture/picked.bin',
            ),
          ]);
  }
}
