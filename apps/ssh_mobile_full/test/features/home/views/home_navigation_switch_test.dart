import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = TestStorageAdapter();
    await storage.init();
    appSettings = AppSettings();
    await appSettings.init();
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

  testWidgets('primary tabs use a retained stack instead of a page viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(value: appSettings),
          ChangeNotifierProvider<SettingsViewModel>.value(
            value: settingsViewModel,
          ),
          ChangeNotifierProvider<SshService>.value(value: sshService),
        ],
        child: MaterialApp(
          theme: AppTheme.lightThemeFor(),
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
            child: const HomeScreen(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(PageView), findsNothing);
    final homeStacks = tester
        .widgetList<IndexedStack>(
          find.descendant(
            of: find.byType(HomeScreen),
            matching: find.byType(IndexedStack),
          ),
        )
        .where((stack) => stack.children.length == 5)
        .toList();
    expect(homeStacks, hasLength(1));
    expect(homeStacks.single.index, 0);
  });
}
