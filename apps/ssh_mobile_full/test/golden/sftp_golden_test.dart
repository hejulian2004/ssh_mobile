import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:drift/native.dart';

import 'package:app_core/app_core.dart';
import 'package:app_ui/app_ui.dart';
import 'package:feature_sftp/feature_sftp.dart';
import 'package:ssh_core/ssh_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SftpModule module;
  late SftpViewModel viewModel;
  late _FakeSftpBackend backend;
  late _FakeSftpSettings settings;
  late _FakeSftpCatalog catalog;

  setUp(() async {
    backend = _FakeSftpBackend();
    module = SftpModule(
      databaseFactory: () => SftpDatabase.forTesting(NativeDatabase.memory()),
    );
    await module.register(
      ModuleContext.fromMap(<Type, Object>{
        SshSessionManager: _FakeSshSessionManager(),
        SftpBackend: backend,
      }),
    );
    await module.initialize();
    await module.activate();
    viewModel = SftpViewModel(module.service);
    settings = _FakeSftpSettings();
    catalog = _FakeSftpCatalog();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    viewModel.dispose();
    await module.dispose();
  });

  Future<void> pumpSftp(
    WidgetTester tester, {
    required Size size,
    required TargetPlatform platform,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SftpViewModel>.value(value: viewModel),
          ListenableProvider<SftpSettingsPort>.value(value: settings),
          ChangeNotifierProvider<_FakeSftpCatalog>.value(value: catalog),
          ListenableProvider<SftpConnectionCatalogPort>.value(value: catalog),
          Provider<SftpHostKeyConfirmationPort>.value(
            value: const _FakeSftpHostKeyConfirmation(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.lightThemeFor(),
          home: const Scaffold(body: SftpScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('SFTP workspace golden - Desktop', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpSftp(
        tester,
        size: const Size(1280, 720),
        platform: TargetPlatform.windows,
      );

      expect(find.byType(SftpScreen), findsOneWidget);
      expect(find.text('notes.md'), findsOneWidget);
      await expectLater(
        find.byType(SftpScreen),
        matchesGoldenFile('goldens/sftp_desktop.png'),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}

final class _FakeSftpBackend extends ChangeNotifier implements SftpBackend {
  @override
  String? get targetFingerprint => 'fingerprint';
  @override
  String? connectionId = 'server-1';

  @override
  String? connectionName = 'Production';

  @override
  String currentPath = '/srv';

  @override
  SftpConnectionState state = SftpConnectionState.connected;

  @override
  String? errorMessage;

  @override
  int entriesRevision = 0;

  @override
  List<SftpEntry> entries = const [
    SftpEntry(
      connectionId: 'server-1',
      targetFingerprint: 'target-1',
      name: 'notes.md',
      path: '/srv/notes.md',
      lowerName: 'notes.md',
      isDirectory: false,
      isLink: false,
      size: 2048,
      sizeLabel: '2 KB',
    ),
  ];

  @override
  bool isConnected = true;

  @override
  bool isBusy = false;

  @override
  SftpTransferState? activeTransfer;

  @override
  bool get hasActiveTransfer => activeTransfer != null;

  @override
  bool isConnectionBusy(String id) => false;

  @override
  bool isConnectionOpen(String id) => id == connectionId;

  @override
  Future<void> connect(
    String id, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> uploadFile({
    required String localPath,
    required String filename,
  }) async {}

  @override
  Future<void> deleteEntry(
    SftpEntry entry, {
    required String confirmedName,
  }) async {}

  @override
  Future<List<SftpEntry>> listDirectoryForConnection(
    String id,
    String path,
  ) async => entries;

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = SftpService.maxTextPreviewBytes,
  }) async => '';

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = SftpService.maxDownloadBytes,
  }) async => Uint8List(0);

  @override
  Future<void> downloadFile(
    SftpEntry entry, {
    required String localPath,
    int maxBytes = SftpService.maxDownloadBytes,
  }) async {}

  @override
  Future<SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  }) async => SftpPathInfo(
    path: path,
    isDirectory: false,
    isLink: false,
    size: 0,
    sizeLabel: '0 B',
    modifiedAt: null,
  );

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = SftpService.maxTextEditBytes,
  }) async {}

  @override
  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = SftpService.maxUploadBytes,
  }) async {}

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) async {}

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) async {}

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) async {}

  @override
  Future<void> openPath(String path) async {}

  @override
  Future<void> openParent() async {}

  @override
  Future<void> disconnect({bool notify = true}) async {}

  @override
  Future<void> disconnectConnection(
    String id, {
    bool notify = true,
    forgetPath = false,
  }) async {}

  @override
  Future<void> disconnectAll({bool notify = true}) async {}

  @override
  void cancelActiveTransfer() {}

  @override
  Future<Uint8List> downloadBytes(
    SftpEntry entry, {
    int maxBytes = SftpService.maxDownloadBytes,
    bool updateState = false,
    bool bypassCache = false,
  }) async => Uint8List(0);

  @override
  Future<String> readTextFile(
    SftpEntry entry, {
    int maxBytes = SftpService.maxTextPreviewBytes,
  }) async => '';

  @override
  Future<void> saveTextFile(
    SftpEntry entry,
    String text, {
    int maxBytes = SftpService.maxTextEditBytes,
  }) async {}
}

final class _FakeSftpSettings extends ChangeNotifier
    implements SftpSettingsPort {
  @override
  SftpLanguage language = SftpLanguage.english;

  @override
  int sftpDownloadLimitBytes = 64 * 1024 * 1024;

  @override
  int sftpTextPreviewLimitBytes = 4 * 1024 * 1024;

  @override
  int sftpRichPreviewLimitBytes = 16 * 1024 * 1024;

  @override
  int sftpTextEditLimitBytes = 4 * 1024 * 1024;

  @override
  Future<void> setSftpDownloadLimitBytes(int bytes) async {
    sftpDownloadLimitBytes = bytes;
  }

  @override
  Future<void> setSftpTextPreviewLimitBytes(int bytes) async {
    sftpTextPreviewLimitBytes = bytes;
  }

  @override
  Future<void> setSftpRichPreviewLimitBytes(int bytes) async {
    sftpRichPreviewLimitBytes = bytes;
  }

  @override
  Future<void> setSftpTextEditLimitBytes(int bytes) async {
    sftpTextEditLimitBytes = bytes;
  }
}

final class _FakeSftpCatalog extends ChangeNotifier
    implements SftpConnectionCatalogPort {
  @override
  bool isLoading = false;

  @override
  List<SftpConnectionInfo> connections = const [
    SftpConnectionInfo(
      id: 'server-1',
      name: 'Production',
      host: 'prod.example.com',
      port: 2222,
      username: 'deployment-user',
    ),
  ];

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {}
}

final class _FakeSshSessionManager extends Fake implements SshSessionManager {
  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<void> close() async {}
}

final class _FakeSftpHostKeyConfirmation
    implements SftpHostKeyConfirmationPort {
  const _FakeSftpHostKeyConfirmation();

  @override
  Future<bool> confirm(SshHostKeyPromptRequest request) async => true;
}
