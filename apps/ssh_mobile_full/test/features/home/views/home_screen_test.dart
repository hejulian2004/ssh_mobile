import 'package:connection_core/connection_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:feature_ai/feature_ai.dart' as feature_ai;
import 'package:feature_connection/feature_connection.dart'
    as feature_connection;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app_ui/app_ui.dart';
import 'package:ssh_mobile/app/connection_route_scope.dart';
import 'package:ssh_mobile/app/connection_runtime_adapters.dart';
import 'package:ssh_mobile/features/home/views/home_screen.dart';
import 'package:ssh_mobile/features/settings/viewmodels/settings_viewmodel.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

import '../../../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storage;
  late AppSettings appSettings;
  late SettingsViewModel settingsViewModel;
  late SshService sshService;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = TestStorageAdapter();
    await storage.init();
    appSettings = AppSettings();
    await appSettings.init();
    await appSettings.toggleLanguage();
    settingsViewModel = SettingsViewModel(
      appSettings: appSettings,
      aiStorage: storage.aiStorage,
    );
    sshService = createTestSshService(storage, appSettings: appSettings);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    settingsViewModel.dispose();
    sshService.dispose();
    await storage.shutdown();
    storage.dispose();
    appSettings.dispose();
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    int initialIndex = 0,
    Duration? settle,
    SettingsViewModel? settings,
    bool pumpAdditionalFrame = true,
    void Function(RouteSettings settings)? onRouteGenerated,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(value: appSettings),
          ChangeNotifierProvider<SettingsViewModel>.value(
            value: settings ?? settingsViewModel,
          ),
          ChangeNotifierProvider<SshService>.value(value: sshService),
        ],
        child: MaterialApp(
          theme: AppTheme.lightThemeFor(),
          onGenerateRoute: (settings) {
            onRouteGenerated?.call(settings);
            return MaterialPageRoute<void>(
              builder: (_) => Text('route ${settings.name}'),
            );
          },
          home: AppConnectionRouteScope(
            connectionRepository: storage.connectionRepository,
            credentialRepository: storage.credentialRepository,
            hostKeyRepository: storage.hostKeyRepository,
            runtimePort: AppConnectionRuntimeAdapter(
              sshServiceFactory: () => sshService,
            ),
            verificationPort: AppConnectionVerificationAdapter(
              credentialRepository: storage.credentialRepository,
              hostKeyRepository: storage.hostKeyRepository,
              logger: AppLogService.instance,
            ),
            child: HomeScreen(initialIndex: initialIndex),
          ),
        ),
      ),
    );
    if (pumpAdditionalFrame) await tester.pump();
    if (settle != null) await tester.pump(settle);
    expect(tester.takeException(), isNull);
  }

  Future<void> disposeHome(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugPrint = debugPrintSynchronously;
    debugDefaultTargetPlatformOverride = null;
  }

  ScaffoldState drawerScaffold(WidgetTester tester) {
    final scaffolds = find.byType(Scaffold);
    for (var index = 0; index < scaffolds.evaluate().length; index++) {
      final state = tester.state<ScaffoldState>(scaffolds.at(index));
      if (state.hasDrawer) return state;
    }
    throw StateError('Home scaffold with a drawer was not found');
  }

  testWidgets('activates only the selected home slot in the first frame', (
    tester,
  ) async {
    await pumpHome(tester, pumpAdditionalFrame: false);

    final stackFinder = find.byType(IndexedStack);
    expect(stackFinder, findsOneWidget);
    final stack = tester.widget<IndexedStack>(stackFinder);
    expect(stack.index, 0);
    expect(stack.children, hasLength(5));
    expect(find.byType(PageView), findsNothing);
    expect(find.byType(ServerListPane), findsOneWidget);
    expect(find.byType(feature_ai.LlmChatScreen), findsNothing);

    await disposeHome(tester);
  });

  testWidgets('empty-state add actions reuse the Home connection ViewModel', (
    tester,
  ) async {
    RouteSettings? generatedRoute;
    await pumpHome(
      tester,
      onRouteGenerated: (settings) => generatedRoute = settings,
    );
    await tester.pump(const Duration(milliseconds: 100));

    final homeViewModel = tester
        .element(find.byType(HomeScreen))
        .read<feature_connection.ConnectionViewModel>();
    final strings = AppStrings(appSettings.language);

    Future<void> expectEmptyStateAddReusesHomeViewModel(IconData icon) async {
      final rail = find.byType(NavigationRail);
      await tester.tap(find.descendant(of: rail, matching: find.byIcon(icon)));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(strings.addConnection), findsOneWidget);
      await tester.tap(find.text(strings.addConnection));
      await tester.pump();

      expect(generatedRoute?.name, '/add');
      expect(generatedRoute?.arguments, same(homeViewModel));

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
    }

    await expectEmptyStateAddReusesHomeViewModel(Icons.folder_open_outlined);
    await expectEmptyStateAddReusesHomeViewModel(Icons.monitor_heart_outlined);

    await disposeHome(tester);
  });

  testWidgets('desktop rail renders and follows the selected page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await pumpHome(tester, settle: const Duration(milliseconds: 100));
    final strings = AppStrings(appSettings.language);
    final rail = find.byType(NavigationRail);
    expect(rail, findsOneWidget);
    expect(find.text('SSH Mobile'), findsOneWidget);
    expect(
      find.descendant(of: rail, matching: find.text(strings.servers)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rail, matching: find.text(strings.sftp)),
      findsOneWidget,
    );
    expect(find.byType(BottomNavigationBar), findsNothing);

    final contentContext = tester.element(find.byType(IndexedStack));
    const OpenSettingsNotification().dispatch(contentContext);
    await tester.pump(const Duration(milliseconds: 100));
    expect(drawerScaffold(tester).isDrawerOpen, isTrue);
    drawerScaffold(tester).closeDrawer();
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // The rail settings action uses the same drawer entry point as the
    // notification path above; exercise the visible callback as well.
    await tester.tap(find.byTooltip(strings.settings));
    await tester.pump(const Duration(milliseconds: 100));
    expect(drawerScaffold(tester).isDrawerOpen, isTrue);
    drawerScaffold(tester).closeDrawer();
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Use the destination icon so the tap targets the rail rather than the
    // identically labelled feature-setting rows in the closed drawer.
    await tester.tap(
      find.descendant(
        of: rail,
        matching: find.byIcon(Icons.folder_open_outlined),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.byIcon(Icons.dns_rounded),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);

    // Height below the compact breakpoint uses the short rail variant.
    tester.view.physicalSize = const Size(1000, 400);
    await tester.pump();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('SSH Mobile'), findsNothing);

    // A keyboard inset on the short desktop viewport reserves the rail slot
    // without painting a full NavigationRail over the input area.
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    await tester.pump();
    expect(find.byType(NavigationRail), findsNothing);

    // Crossing the desktop breakpoint must not require page-controller
    // alignment; the selected index remains the single source of truth.
    tester.view.resetViewInsets();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump();

    await disposeHome(tester);
  });

  testWidgets('mobile server page exposes the add connection action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    await storage.connectionRepository.addConnection(
      ConnectionConfig(
        id: 'home-fab',
        name: 'Home FAB',
        host: 'home-fab.example.test',
        username: 'tester',
      ),
    );
    await pumpHome(tester, settle: const Duration(milliseconds: 100));
    final strings = AppStrings(appSettings.language);
    final fab = find.byTooltip(strings.addConnection);
    expect(fab, findsOneWidget);
    await tester.tap(fab);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);

    await disposeHome(tester);
  });

  testWidgets('busy settings overlay is painted above the page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final busyViewModel = _BusySettingsViewModel(
      appSettings: appSettings,
      aiStorage: storage.aiStorage,
    );
    addTearDown(busyViewModel.dispose);
    await pumpHome(
      tester,
      settle: const Duration(milliseconds: 100),
      settings: busyViewModel,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await disposeHome(tester);
  });

  testWidgets('mobile shell exposes semantic bottom navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpHome(tester, settle: const Duration(milliseconds: 100));

    expect(find.byType(NavigationRail), findsNothing);
    for (var index = 0; index < 5; index++) {
      expect(find.byKey(ValueKey('home-nav-$index')), findsOneWidget);
    }

    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.index, 0);
    expect(tester.takeException(), isNull);

    await disposeHome(tester);
  });

  testWidgets(
    'mobile bottom navigation background wraps safe area to prevent color layering',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await pumpHome(tester, settle: const Duration(milliseconds: 100));

      final navItemFinder = find.byKey(const ValueKey('home-nav-0'));
      expect(navItemFinder, findsOneWidget);

      final safeAreaFinder = find.ancestor(
        of: navItemFinder,
        matching: find.byType(SafeArea),
      );
      expect(safeAreaFinder, findsOneWidget);

      // The background Container with decoration must be an ancestor of SafeArea
      // so the surface background color fills the bottom inset without stratification.
      final containerAncestor = find.ancestor(
        of: safeAreaFinder,
        matching: find.byType(Container),
      );
      expect(containerAncestor, findsWidgets);

      final materialAncestor = find.ancestor(
        of: safeAreaFinder,
        matching: find.byType(Material),
      );
      expect(materialAncestor, findsWidgets);

      await disposeHome(tester);
    },
  );

  group('Shell Behavior Matrix', () {
    for (final size in [
      const Size(600, 800),
      const Size(800, 700),
      const Size(1024, 768),
    ]) {
      testWidgets(
        'Windows ${size.width.toInt()}px uses desktop navigation shell and no bottom bar',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          await pumpHome(tester, settle: const Duration(milliseconds: 100));

          expect(find.byType(NavigationRail), findsOneWidget);
          for (var index = 0; index < 5; index++) {
            expect(find.byKey(ValueKey('home-nav-$index')), findsNothing);
          }

          await disposeHome(tester);
        },
      );
    }

    for (final size in [
      const Size(390, 844),
      const Size(600, 900),
      const Size(800, 600),
    ]) {
      testWidgets(
        'Android ${size.width.toInt()}px uses mobile bottom navigation and no rail',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          await pumpHome(tester, settle: const Duration(milliseconds: 100));

          expect(find.byType(NavigationRail), findsNothing);
          expect(find.byKey(const ValueKey('home-nav-0')), findsOneWidget);

          await disposeHome(tester);
        },
      );
    }

    testWidgets(
      'Android 1000px tablet uses navigation rail and no mobile bottom bar',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await pumpHome(tester, settle: const Duration(milliseconds: 100));

        expect(find.byType(NavigationRail), findsOneWidget);
        for (var index = 0; index < 5; index++) {
          expect(find.byKey(ValueKey('home-nav-$index')), findsNothing);
        }

        await disposeHome(tester);
      },
    );

    testWidgets(
      'Mobile navigation items maintain minimum 44 logical px touch hit area',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await pumpHome(tester, settle: const Duration(milliseconds: 100));

        for (var index = 0; index < 5; index++) {
          final navItemFinder = find.byKey(ValueKey('home-nav-$index'));
          expect(navItemFinder, findsOneWidget);
          final size = tester.getSize(navItemFinder);
          expect(size.height, greaterThanOrEqualTo(44.0));
          expect(size.width, greaterThanOrEqualTo(44.0));
        }

        await disposeHome(tester);
      },
    );

    testWidgets(
      'Shell with textScale 1.3 renders cleanly without RenderFlex overflows',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await pumpHome(tester, settle: const Duration(milliseconds: 100));

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('home-nav-0')), findsOneWidget);

        await disposeHome(tester);
      },
    );
  });

  testWidgets('initial index is clamped while compact keyboard content loads', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 360);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await pumpHome(tester, initialIndex: -99);
    expect(find.byType(NavigationRail), findsNothing);

    await disposeHome(tester);
  });

  testWidgets('settings drawer invokes backup callbacks', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final backupViewModel = _HomeBackupSettingsViewModel(
      appSettings: appSettings,
      aiStorage: storage.aiStorage,
    );
    addTearDown(backupViewModel.dispose);
    await pumpHome(
      tester,
      settle: const Duration(milliseconds: 100),
      settings: backupViewModel,
    );
    final strings = AppStrings(appSettings.language);
    final homeScaffold = drawerScaffold(tester);
    homeScaffold.openDrawer();
    expect(homeScaffold.isDrawerOpen, isTrue);
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(Drawer), findsOneWidget);
    final drawerList = find.descendant(
      of: find.byType(Drawer),
      matching: find.byType(ListView),
    );
    await tester.drag(drawerList, const Offset(0, -700));
    await tester.pump(const Duration(milliseconds: 200));

    final previousPicker = FilePickerPlatform.instance;
    final fakePicker = _HomeFilePicker();
    FilePickerPlatform.instance = fakePicker;
    addTearDown(() => FilePickerPlatform.instance = previousPicker);

    final exportButton = find.text(strings.exportAppData);
    expect(exportButton, findsOneWidget);
    await tester.ensureVisible(exportButton);
    await tester.tap(exportButton);
    await tester.pump();
    expect(backupViewModel.exportCalls, 1);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(fakePicker.saveCalls, 1);
    expect(backupViewModel.exportCalls, 1);
    expect(find.text(strings.exportComplete), findsOneWidget);

    backupViewModel.throwOnExport = true;
    await tester.ensureVisible(exportButton);
    await tester.tap(exportButton);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SnackBar), findsOneWidget);

    final importButton = find.text(strings.importAppData);
    expect(importButton, findsOneWidget);
    await tester.ensureVisible(importButton);
    await tester.tap(importButton);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(strings.importAppData), findsWidgets);
    await tester.tap(find.text(strings.cancel).last);
    await tester.pump(const Duration(milliseconds: 200));
    expect(backupViewModel.importCalls, 0);

    fakePicker.throwOnPick = false;
    await tester.ensureVisible(importButton);
    await tester.tap(importButton);
    await tester.pump(const Duration(milliseconds: 200));
    final action = find.text(strings.importAction).last;
    await tester.tap(action);
    await tester.pump(const Duration(milliseconds: 200));
    expect(backupViewModel.importCalls, 1);
    expect(find.byType(SnackBar), findsOneWidget);

    fakePicker.throwOnPick = true;
    await tester.ensureVisible(importButton);
    await tester.tap(importButton);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text(strings.importAction).last);
    await tester.pump(const Duration(milliseconds: 200));
    expect(backupViewModel.importCalls, 2);
    expect(find.byType(SnackBar), findsOneWidget);

    await disposeHome(tester);
  });

  testWidgets('handles settings notification and state updates', (
    tester,
  ) async {
    await pumpHome(tester, settle: const Duration(milliseconds: 100));
    expect(find.byType(HomeScreen), findsOneWidget);

    final innerContext = tester.element(find.byType(ServerListPane));
    const OpenSettingsNotification().dispatch(innerContext);
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);

    // Close drawer
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    final dynamic state = tester.state(find.byType(HomeScreen));
    state.updateState(() {});
    expect(state.settingsLabelAi(innerContext), 'AI');

    await disposeHome(tester);
  });
}

final class _HomeFilePicker extends FilePickerPlatform {
  int saveCalls = 0;
  int pickCalls = 0;
  bool throwOnPick = true;

  @override
  Future<FilePickerResult?> pickFiles({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    String? dialogTitle,
    String? initialDirectory,
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
    pickCalls++;
    if (throwOnPick) {
      throw PlatformException(code: 'cancelled', message: 'test picker');
    }
    final bytes = Uint8List.fromList(const [123, 125]);
    return FilePickerResult([
      PlatformFile(name: 'backup.json', size: bytes.length, bytes: bytes),
    ]);
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    required String fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    required Uint8List bytes,
    Function(FilePickerStatus)? onFileLoading,
    bool lockParentWindow = false,
  }) async {
    saveCalls++;
    return '/tmp/ssh-mobile-backup.json';
  }
}

final class _HomeBackupSettingsViewModel extends SettingsViewModel {
  _HomeBackupSettingsViewModel({
    required super.appSettings,
    required super.aiStorage,
  });

  int exportCalls = 0;
  int importCalls = 0;
  bool throwOnExport = false;
  bool throwOnImport = false;

  @override
  Future<bool> exportAppData(
    Future<String?> Function(String fileName, List<int> bytes) saveFileCallback,
  ) async {
    exportCalls++;
    if (throwOnExport) throw StateError('export failed');
    return (await saveFileCallback('home-test.json', const [1])) != null;
  }

  @override
  Future<bool> importAppData(
    Future<List<int>?> Function() pickFileCallback,
  ) async {
    importCalls++;
    if (throwOnImport) throw StateError('import failed');
    final bytes = await pickFileCallback();
    return bytes != null;
  }
}

final class _BusySettingsViewModel extends SettingsViewModel {
  _BusySettingsViewModel({
    required super.appSettings,
    required super.aiStorage,
  });

  @override
  bool get isExporting => true;
}
