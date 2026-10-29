import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:app_ui/app_ui.dart';
import 'package:feature_system_admin/feature_system_admin.dart' as admin;
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/system_admin_feature_adapters.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:connection_core/connection_core.dart';

part 'system_admin_snapshot_stubs.dart';

typedef SystemAdminScreen = admin.SystemAdminScreen;
typedef SystemAdminViewModel = admin.SystemAdminViewModel;
typedef SystemAdminMonitoringPort = admin.SystemAdminMonitoringPort;
typedef PerformanceMonitorViewModel = admin.SystemAdminMonitoringPort;
typedef SshHostKeyConfirmation = ssh_core.SshHostKeyConfirmation;
typedef SystemPowerConfirmationToken = admin.SystemPowerConfirmationToken;
typedef SystemPowerAction = admin.SystemPowerAction;
typedef LinuxUserAccount = admin.LinuxUserAccount;
typedef ActiveSession = admin.ActiveSession;
typedef SystemdService = admin.SystemdService;
typedef ListeningPort = admin.ListeningPort;
typedef LinuxUserProcess = admin.LinuxUserProcess;
typedef MonitorAlert = admin.MonitorAlert;
typedef PerformanceSample = admin.PerformanceSample;
typedef DiskUsageSnapshot = admin.DiskUsageSnapshot;
typedef ServerHealthSnapshot = admin.ServerHealthSnapshot;
typedef ServerHealthLevel = admin.ServerHealthLevel;
typedef PortProcessSnapshot = admin.PortProcessSnapshot;
typedef ApplicationMemorySnapshot = admin.ApplicationMemorySnapshot;
typedef ServiceStatusSnapshot = admin.ServiceStatusSnapshot;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings appSettings;
  late AppSystemAdminSettingsAdapter settingsAdapter;
  late List<ConnectionConfig> fakeConnections;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    appSettings = AppSettings();
    await appSettings.init();
    settingsAdapter = AppSystemAdminSettingsAdapter(appSettings);

    fakeConnections = [
      ConnectionConfig(
        id: 'conn_123',
        name: 'Test Server',
        host: '127.0.0.1',
        username: 'root',
        serverPlatform: ServerPlatform.linux,
      ),
    ];
  });

  Widget buildTestableWidget({
    required SystemAdminViewModel adminVm,
    required PerformanceMonitorViewModel monitorVm,
    double textScale = 1,
    String? monitoringConnectionId,
  }) {
    return MultiProvider(
      providers: [
        ListenableProvider<admin.SystemAdminSettingsPort>.value(
          value: settingsAdapter,
        ),
        ChangeNotifierProvider<SystemAdminViewModel>.value(value: adminVm),
        ListenableProvider<admin.SystemAdminMonitoringPort>.value(
          value: monitorVm,
        ),
      ],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          splashFactory: InkRipple.splashFactory,
        ),
        builder: (context, child) {
          final mediaQuery = MediaQuery.of(context);
          return MediaQuery(
            data: mediaQuery.copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          );
        },
        home: SystemAdminScreen(monitoringConnectionId: monitoringConnectionId),
      ),
    );
  }

  testWidgets(
    'widget focus shows only its server without changing sampling or connecting',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = [
        ...fakeConnections,
        ConnectionConfig(
          id: 'conn_456',
          name: 'Second Server',
          host: 'example.invalid',
          username: 'fixture-user',
        ),
      ];
      monitorVm.isRunning = true;
      monitorVm.selectedConnectionIds = {'conn_123', 'conn_456'};
      monitorVm.monitoringConnectionIds = {'conn_123', 'conn_456'};
      for (final id in monitorVm.monitoringConnectionIds) {
        monitorVm.sampleOverrides[id] = [
          PerformanceSample(
            connectionId: id,
            time: DateTime.utc(2026, 10, 29),
            cpuPercent: 42,
            memoryPercent: 63,
            diskBytesPerSecond: 2048,
            networkBytesPerSecond: 1024,
          ),
        ];
      }
      await tester.pumpWidget(
        buildTestableWidget(
          adminVm: adminVm,
          monitorVm: monitorVm,
          monitoringConnectionId: 'conn_123',
        ),
      );
      // The running monitor deliberately animates its live indicator forever.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Test Server 42'), findsWidgets);
      expect(find.textContaining('Second Server '), findsNothing);
      expect(monitorVm.selectedConnectionIds, {'conn_123', 'conn_456'});
      expect(monitorVm.monitoringConnectionIds, {'conn_123', 'conn_456'});
      expect(adminVm.connectIfNeededCalls, 0);
      expect(monitorVm.fetchPortsCalls, isEmpty);
    },
  );

  testWidgets(
    'SystemAdminScreen displays empty state when no server selected',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );

      expect(find.text('选择要监控的服务器'), findsOneWidget);
    },
  );

  testWidgets(
    'Monitor displays 4 metric charts skeleton when running before first sample arrives',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;
      adminVm.selectedConnectionId = 'conn_123';
      monitorVm.isRunning = true;
      monitorVm.monitoringConnectionIds = {'conn_123'};

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );
      await tester.pump();

      expect(find.byType(AppSkeletonizer), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        expect(
          find.byKey(ValueKey('monitor-skeleton-chart-$i')),
          findsOneWidget,
        );
      }
    },
  );

  testWidgets('Monitor supports multi-select and collapses only after start', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = [
      ...fakeConnections,
      ConnectionConfig(
        id: 'conn_456',
        name: 'Second Server',
        host: '127.0.0.2',
        username: 'operator',
        serverPlatform: ServerPlatform.linux,
      ),
    ];

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-server-collapse-mobile')),
        matching: find.byIcon(Icons.keyboard_double_arrow_up_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('admin-server-tile-conn_123')));
    await tester.ensureVisible(
      find.byKey(const ValueKey('admin-server-tile-conn_456')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-server-tile-conn_456')));
    await tester.pumpAndSettle();

    expect(monitorVm.selectedConnectionIds, {'conn_123', 'conn_456'});
    expect(adminVm.serversCollapsed, isFalse);

    await tester.tap(find.byKey(const ValueKey('monitor-start')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(monitorVm.monitoringConnectionIds, {'conn_123', 'conn_456'});
    expect(adminVm.serversCollapsed, isTrue);
    expect(
      find.byKey(const ValueKey('admin-server-collapsed')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-server-expand-mobile')),
        matching: find.byIcon(Icons.keyboard_double_arrow_down_rounded),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'SystemAdminScreen displays Ports snapshot when server is selected',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;

      adminVm.selectConnection('conn_123');

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );

      await tester.pumpAndSettle();

      // Verify TabBar is present
      expect(find.byType(TabBar), findsOneWidget);

      // Switch to Tab 1 (listeningPorts)
      await tester.tap(find.text('监听端口'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('system-admin-workspace-header')),
        findsNothing,
      );
      // Snapshot mode is the default and does not root-connect automatically.
      expect(find.text('快照模式'), findsOneWidget);
      expect(find.text('nginx'), findsWidgets);
      expect(find.byKey(const ValueKey('header-conn_123')), findsNothing);
      final portsModeCenter = tester.getCenter(
        find.byType(SegmentedButton<bool>),
      );
      final portsRefreshCenter = tester.getCenter(
        find.byKey(const ValueKey('system-admin-tab-refresh')),
      );
      expect(portsRefreshCenter.dx, greaterThan(portsModeCenter.dx));
      expect(portsRefreshCenter.dy, lessThan(portsModeCenter.dy));
      expect(find.text('连接 Root'), findsNothing);
      expect(adminVm.connectIfNeededCalls, 0);
      expect(monitorVm.fetchPortsCalls, ['conn_123']);

      await tester.tap(find.byKey(const ValueKey('system-admin-tab-refresh')));
      await tester.pumpAndSettle();
      expect(monitorVm.fetchPortsCalls, ['conn_123', 'conn_123']);

      await tester.tap(
        find.byKey(const ValueKey('admin-server-tile-conn_123')),
      );
      await tester.pumpAndSettle();
      expect(adminVm.serversCollapsed, isTrue);
    },
  );

  testWidgets(
    'SystemAdminScreen displays Applications snapshot when server is selected',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;

      adminVm.selectConnection('conn_123');

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );

      await tester.pumpAndSettle();

      // Switch to Tab 2 (applications)
      await tester.tap(find.text('应用/进程'));
      await tester.pumpAndSettle();

      // Verify snapshot shows process 'nginx' and 'PID 101'
      expect(find.text('nginx'), findsWidgets);
      expect(find.textContaining('PID 101'), findsOneWidget);
      expect(find.byKey(const ValueKey('header-conn_123')), findsNothing);
      expect(
        find.byKey(const ValueKey('system-admin-tab-refresh')),
        findsOneWidget,
      );
      // Applications does not display a manage mode or Connect Root warning
      expect(find.textContaining('管理模式'), findsNothing);
      expect(find.text('连接 Root'), findsNothing);
    },
  );

  testWidgets(
    'SystemAdminScreen displays Services snapshot when server is selected but not connected',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;

      adminVm.selectConnection('conn_123');

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );

      await tester.pumpAndSettle();

      // Switch to Tab 3 (systemServices)
      await tester.tap(find.text('系统服务'));
      await tester.pumpAndSettle();

      // Verify service card nginx.service exists
      expect(find.text('快照模式'), findsOneWidget);
      expect(find.text('nginx.service'), findsWidgets);
      expect(find.byKey(const ValueKey('header-conn_123')), findsNothing);
      final servicesModeCenter = tester.getCenter(
        find.byType(SegmentedButton<bool>),
      );
      final servicesRefreshCenter = tester.getCenter(
        find.byKey(const ValueKey('system-admin-tab-refresh')),
      );
      expect(servicesRefreshCenter.dx, greaterThan(servicesModeCenter.dx));
      expect(servicesRefreshCenter.dy, lessThan(servicesModeCenter.dy));
      expect(find.text('连接 Root'), findsNothing);
      expect(adminVm.connectIfNeededCalls, 0);
      expect(monitorVm.fetchServicesCalls, ['conn_123']);

      // Snapshot mode does not have the trailing actions PopMenuButton
      expect(find.byType(PopupMenuButton<String>), findsNothing);
    },
  );

  testWidgets(
    'SystemAdminScreen displays Services manage mode when root connected',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;

      // Simulate root connected
      adminVm.selectedConnectionId = 'conn_123';
      adminVm.managementConnectionId = 'conn_123';
      adminVm.isConnected = true;
      adminVm.isRoot = true;

      // Add some system services in viewModel
      adminVm.services = [
        SystemdService(
          name: 'nginx.service',
          loadState: 'loaded',
          activeState: 'active',
          subState: 'running',
          description: 'Nginx Service',
        ),
      ];

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );

      await tester.pumpAndSettle();

      // Switch to Tab 3 (systemServices)
      await tester.tap(find.text('系统服务'));
      await tester.pumpAndSettle();

      // Verify segmented button for Manage/Snapshot exists
      expect(find.text('管理模式'), findsOneWidget);
      expect(find.text('快照模式'), findsOneWidget);
      expect(find.byTooltip('刷新全部'), findsNothing);
      expect(
        find.byKey(const ValueKey('system-admin-tab-refresh')),
        findsOneWidget,
      );

      await tester.tap(find.text('管理模式'));
      await tester.pumpAndSettle();

      // Verify nginx.service exists
      expect(find.text('nginx.service'), findsWidgets);

      // Manage mode has trailing actions PopMenuButton
      expect(find.byType(PopupMenuButton<String>), findsWidgets);
    },
  );

  testWidgets('Services manage mode shows services after lazy fetch', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel()
      ..connections = fakeConnections
      ..populateServicesOnFetch = true;
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('系统服务'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('管理模式'));
    await tester.pumpAndSettle();

    expect(adminVm.connectIfNeededCalls, 1);
    expect(adminVm.fetchServicesCalls, ['conn_123']);
    expect(find.text('nginx.service'), findsOneWidget);
    expect(find.text('ssh.service'), findsOneWidget);
    expect(find.text('No services found.'), findsNothing);

    await tester.enterText(find.byType(TextField), 'nginx');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('nginx.service'), findsOneWidget);
    expect(find.text('ssh.service'), findsNothing);

    await tester.enterText(find.byType(TextField), 'missing-service');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('nginx.service'), findsNothing);
    expect(find.text('No services found.'), findsOneWidget);
  });

  testWidgets('SystemAdminScreen clears stale selected server safely', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    adminVm.connections = [];
    adminVm.notifyListeners();
    await tester.pumpAndSettle();

    expect(adminVm.selectedConnectionId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Users tab connects and fetches only accounts on activation', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.populateAccountsOnFetch = true;
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('用户账号'));
    await tester.tap(find.text('用户账号'));
    await tester.pumpAndSettle();

    expect(adminVm.connectIfNeededCalls, 1);
    expect(adminVm.fetchAccountsCalls, ['conn_123']);
    expect(adminVm.fetchSessionsCalls, isEmpty);
    expect(adminVm.fetchServicesCalls, isEmpty);
    expect(adminVm.fetchPortsCalls, isEmpty);
    expect(find.text('root'), findsWidgets);
  });

  testWidgets('Sessions tab rebuilds when session data arrives', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel()
      ..connections = fakeConnections
      ..populateSessionsOnFetch = true;
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('活动会话'));
    await tester.tap(find.text('活动会话'));
    await tester.pumpAndSettle();

    expect(adminVm.fetchSessionsCalls, ['conn_123']);
    expect(find.text('pts/0'), findsOneWidget);
    expect(find.textContaining('192.168.1.10'), findsOneWidget);
  });

  testWidgets('manual root retry loads the active Users tab', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel()
      ..connections = fakeConnections
      ..connectOnDemand = false
      ..populateAccountsOnFetch = true;
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('用户账号'));
    await tester.tap(find.text('用户账号'));
    await tester.pumpAndSettle();

    expect(find.text('以 Root 连接'), findsOneWidget);
    adminVm.connectOnDemand = true;
    await tester.tap(find.text('以 Root 连接'));
    await tester.pumpAndSettle();

    expect(adminVm.fetchAccountsCalls, ['conn_123']);
    expect(find.text('root'), findsWidgets);
  });

  testWidgets('Power tab connects without preloading management lists', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('系统电源'));
    await tester.tap(find.text('系统电源'));
    await tester.pumpAndSettle();

    expect(adminVm.connectIfNeededCalls, 1);
    expect(adminVm.fetchAccountsCalls, isEmpty);
    expect(adminVm.fetchSessionsCalls, isEmpty);
    expect(adminVm.fetchServicesCalls, isEmpty);
    expect(adminVm.fetchPortsCalls, isEmpty);
  });

  testWidgets('Applications snapshot loads only after tab activation', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    expect(monitorVm.fetchApplicationsCalls, isEmpty);

    await tester.tap(find.text('应用/进程'));
    await tester.pumpAndSettle();

    expect(monitorVm.fetchApplicationsCalls, ['conn_123']);
  });

  testWidgets(
    'Server selection hint uses left on desktop and above on mobile',
    (WidgetTester tester) async {
      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;

      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('监听端口'));
      await tester.pumpAndSettle();
      expect(find.textContaining('左侧'), findsOneWidget);

      await appSettings.toggleLanguage();
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();

      expect(find.textContaining('above'), findsOneWidget);
    },
  );

  testWidgets('System admin workspace stays usable at 320dp with 200% text', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm, textScale: 2),
    );
    await tester.pumpAndSettle();

    // The monitor tab begins directly with its live controls, avoiding a
    // duplicate workspace header on compact screens.
    expect(
      find.byKey(const ValueKey('system-admin-workspace-header')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('admin-server-collapse-mobile')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('admin-server-tile-conn_123')),
      findsOneWidget,
    );
    final configScroller = find.byKey(
      const ValueKey('monitor-config-horizontal-scroll'),
    );
    expect(configScroller, findsOneWidget);
    expect(
      tester.widget<SingleChildScrollView>(configScroller).scrollDirection,
      Axis.horizontal,
    );
    final controlsRow = tester.widget<Row>(
      find.byKey(const ValueKey('monitor-config-controls-row')),
    );
    expect(controlsRow.mainAxisAlignment, MainAxisAlignment.center);
    await tester.drag(configScroller, const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey('admin-server-collapse-mobile')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('admin-server-expand-mobile')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Root connection failures use the localized recovery state', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');
    adminVm.managementConnectionId = 'conn_123';
    adminVm.errorMessage = 'Host key verification failed';
    adminVm.connectOnDemand = false;

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('用户账号'));
    await tester.pumpAndSettle();

    expect(find.text('连接失败'), findsWidgets);
    expect(
      find.byKey(const ValueKey('system-admin-connect-root')),
      findsOneWidget,
    );
    expect(find.textContaining('Host key verification failed'), findsOneWidget);
  });

  testWidgets('Snapshot mode controls remain scrollable with 200% text', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm, textScale: 2),
    );
    await tester.pumpAndSettle();

    final portsTab = find.text('监听端口');
    await tester.ensureVisible(portsTab);
    await tester.tap(portsTab);
    await tester.pumpAndSettle();
    expect(find.text('快照模式'), findsOneWidget);
    final mobileSelector = find.byKey(const ValueKey('admin-server-expanded'));
    final refreshButton = find.byKey(
      const ValueKey('system-admin-tab-refresh'),
    );
    expect(refreshButton, findsOneWidget);
    expect(
      tester.getCenter(refreshButton).dx,
      greaterThan(tester.getTopRight(mobileSelector).dx),
    );
    final selectorList = find.descendant(
      of: mobileSelector,
      matching: find.byType(ListView),
    );
    expect(selectorList, findsOneWidget);
    expect(
      tester.widget<ListView>(selectorList).scrollDirection,
      Axis.horizontal,
    );
    expect(tester.takeException(), isNull);

    final servicesTab = find.text('系统服务');
    await tester.ensureVisible(servicesTab);
    await tester.tap(servicesTab);
    await tester.pumpAndSettle();
    expect(find.text('快照模式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
