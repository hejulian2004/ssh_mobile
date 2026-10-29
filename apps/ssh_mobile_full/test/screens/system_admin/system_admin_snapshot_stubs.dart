part of 'system_admin_snapshot_tabs_test.dart';

class StubSystemAdminViewModel extends ChangeNotifier
    implements SystemAdminViewModel {
  @override
  String? selectedConnectionId;

  @override
  String? managementConnectionId;

  @override
  bool isConnected = false;

  @override
  bool isConnecting = false;

  @override
  bool isRoot = false;

  @override
  String? errorMessage;

  @override
  bool storageInitialized = true;

  @override
  bool serversCollapsed = false;

  @override
  List<LinuxUserAccount> accounts = [];

  @override
  bool loadingAccounts = false;

  @override
  List<ActiveSession> sessions = [];

  @override
  bool loadingSessions = false;

  @override
  List<SystemdService> services = [];

  @override
  bool loadingServices = false;

  @override
  List<ListeningPort> ports = [];

  @override
  bool loadingPorts = false;

  @override
  List<ConnectionConfig> connections = [];

  int connectIfNeededCalls = 0;
  final List<String> fetchAccountsCalls = [];
  final List<String> fetchSessionsCalls = [];
  final List<String> fetchServicesCalls = [];
  final List<String> fetchPortsCalls = [];
  bool populateServicesOnFetch = false;
  bool populateAccountsOnFetch = false;
  bool populateSessionsOnFetch = false;
  bool connectOnDemand = true;

  @override
  String? get connectionId => selectedConnectionId;

  @override
  String? get activeManagementConnectionId {
    final id = managementConnectionId;
    if (id == null || id != selectedConnectionId) return null;
    return id;
  }

  @override
  admin.SystemAdminSessionTarget? get activeManagementTarget {
    final id = activeManagementConnectionId;
    final config = connectionById(id);
    if (id == null || config == null || !isConnected || !isRoot) return null;
    return admin.SystemAdminSessionTarget(
      binding: ssh_core.SshTargetBinding.fromConfig(config),
      generation: 1,
    );
  }

  @override
  bool get canManageSelectedConnection {
    return activeManagementConnectionId != null && isConnected && isRoot;
  }

  @override
  bool get isConnectingSelectedConnection {
    return managementConnectionId == selectedConnectionId && isConnecting;
  }

  @override
  bool get isConnectedSelectedConnection {
    return managementConnectionId == selectedConnectionId && isConnected;
  }

  @override
  bool get hasManagementErrorForSelectedConnection {
    return managementConnectionId == selectedConnectionId &&
        errorMessage != null;
  }

  @override
  ConnectionConfig? get selectedConnection =>
      connectionById(selectedConnectionId);

  @override
  bool get hasValidSelection =>
      selectedConnectionId != null && selectedConnection != null;

  @override
  void cancelActiveCommands() {}

  @override
  Duration debounceDuration = Duration.zero;

  @override
  ConnectionConfig? connectionById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final connection in connections) {
      if (connection.id == id) return connection;
    }
    return null;
  }

  @override
  bool isConnectingConnection(String id) {
    return managementConnectionId == id && isConnecting;
  }

  @override
  void selectConnection(String id) {
    selectedConnectionId = id;
    accounts = [];
    sessions = [];
    services = [];
    ports = [];
    notifyListeners();
  }

  @override
  Future<void> connect(
    String id, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    managementConnectionId = id;
    isConnected = true;
    isRoot = true;
    notifyListeners();
  }

  @override
  Future<void> connectIfNeeded(
    String id, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    if (selectedConnectionId != id) return;
    if (canManageSelectedConnection) return;
    connectIfNeededCalls++;
    if (!connectOnDemand) return;
    await connect(id, onUnknownHostKey: onUnknownHostKey);
  }

  @override
  Future<void> disconnect() async {
    managementConnectionId = null;
    isConnected = false;
    isRoot = false;
    notifyListeners();
  }

  @override
  Future<void> disconnectTarget(admin.SystemAdminSessionTarget target) async {
    if (activeManagementTarget?.matches(target) ?? false) await disconnect();
  }

  @override
  void restoreServersCollapsed(BuildContext context) {}

  @override
  void setServersCollapsed(BuildContext context, bool collapsed) {
    serversCollapsed = collapsed;
    notifyListeners();
  }

  @override
  void clearInvalidSelection() {
    final id = selectedConnectionId;
    if (id == null) return;
    selectedConnectionId = null;
    accounts = [];
    sessions = [];
    services = [];
    ports = [];
    if (managementConnectionId == id) {
      disconnect();
      return;
    }
    notifyListeners();
  }

  @override
  void validateSelectedConnection() {
    if (selectedConnectionId != null &&
        connectionById(selectedConnectionId) == null) {
      clearInvalidSelection();
    }
  }

  @override
  Future<void> refreshAllData() async {}

  @override
  Future<void> fetchAccounts(String connId, {bool force = false}) async {
    fetchAccountsCalls.add(connId);
    if (populateAccountsOnFetch) {
      accounts = const [
        LinuxUserAccount(
          username: 'root',
          uid: 0,
          gid: 0,
          homeDir: '/root',
          shell: '/bin/bash',
          status: 'P',
        ),
      ];
      notifyListeners();
    }
  }

  @override
  Future<void> fetchSessions(String connId, {bool force = false}) async {
    fetchSessionsCalls.add(connId);
    if (populateSessionsOnFetch) {
      sessions = const [
        ActiveSession(
          username: 'root',
          tty: 'pts/0',
          loginTime: '2026-07-15 10:30',
          ipAddress: '192.168.1.10',
        ),
      ];
      notifyListeners();
    }
  }

  @override
  Future<void> fetchServices(String connId, {bool force = false}) async {
    fetchServicesCalls.add(connId);
    if (populateServicesOnFetch) {
      services = [
        SystemdService(
          name: 'nginx.service',
          loadState: 'loaded',
          activeState: 'active',
          subState: 'running',
          description: 'Nginx Service',
        ),
        SystemdService(
          name: 'ssh.service',
          loadState: 'loaded',
          activeState: 'inactive',
          subState: 'dead',
          description: 'OpenSSH Server',
        ),
      ];
      notifyListeners();
    }
  }

  @override
  Future<void> fetchPorts(String connId, {bool force = false}) async {
    fetchPortsCalls.add(connId);
  }

  @override
  Future<void> createUser(
    String username,
    String password, {
    String shell = '/bin/bash',
  }) async {}

  @override
  Future<bool> checkUserSudo(String username) async => false;

  @override
  Future<void> setUserSudo(String username, bool grant) async {}

  @override
  Future<void> lockUser(String username) async {}

  @override
  Future<void> unlockUser(String username) async {}

  @override
  Future<void> changePassword(String username, String newPassword) async {}

  @override
  Future<String> getUserHomeStorageUsage(String homeDir) async => 'N/A';

  @override
  Future<List<LinuxUserProcess>> getUserProcessesAndMemory(
    String username,
  ) async => [];

  @override
  Future<void> killActiveSession(String tty) async {}

  @override
  Future<void> manageSystemdService(String serviceName, String action) async {}

  @override
  Future<void> rebootServer(SystemPowerConfirmationToken token) async {}

  @override
  Future<void> shutdownServer(SystemPowerConfirmationToken token) async {}
}

class StubPerformanceMonitorViewModel extends ChangeNotifier
    implements PerformanceMonitorViewModel {
  int activeTabIndex = 0;

  bool serversCollapsed = false;

  String? activeConnectionId;

  @override
  bool isRunning = false;

  @override
  bool isSampling = false;

  @override
  Set<String> selectedConnectionIds = {};

  @override
  Set<String> monitoringConnectionIds = {};

  @override
  Duration interval = const Duration(seconds: 5);

  @override
  Duration historyWindow = const Duration(minutes: 5);

  @override
  Duration effectiveInterval = const Duration(seconds: 5);

  @override
  DateTime? startedAt;

  @override
  List<MonitorAlert> alerts = [];

  final List<String> fetchPortsCalls = [];
  final List<String> fetchApplicationsCalls = [];
  final List<String> fetchServicesCalls = [];

  final Map<String, List<PerformanceSample>> sampleOverrides = {};
  List<PerformanceSample> getSamples(String connectionId) =>
      sampleOverrides[connectionId] ?? [];

  List<DiskUsageSnapshot> getDiskUsage(String connectionId) => [];

  ServerHealthSnapshot getHealth(String connectionId) => ServerHealthSnapshot(
    connectionId: connectionId,
    level: ServerHealthLevel.healthy,
    score: 100,
    summary: 'Healthy',
    details: const [],
    updatedAt: DateTime.now(),
  );

  void setTabIndex(int index) {
    activeTabIndex = index;
    notifyListeners();
  }

  void setServersCollapsed(bool collapsed) {
    serversCollapsed = collapsed;
    notifyListeners();
  }

  void setActiveConnection(String? connectionId) {
    activeConnectionId = connectionId;
    notifyListeners();
  }

  @override
  Future<void> startMonitoring({
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    isRunning = true;
    monitoringConnectionIds = Set<String>.of(selectedConnectionIds);
    notifyListeners();
  }

  @override
  void stopMonitoring() {
    isRunning = false;
    notifyListeners();
  }

  void forceRefresh({SshHostKeyConfirmation? onUnknownHostKey}) {}

  @override
  Future<void> sampleNow({SshHostKeyConfirmation? onUnknownHostKey}) async {}

  @override
  void setInterval(Duration val) {
    interval = val;
    notifyListeners();
  }

  @override
  void setHistoryWindow(Duration val) {
    historyWindow = val;
    notifyListeners();
  }

  @override
  void toggleSelection(String connectionId) {
    if (selectedConnectionIds.contains(connectionId)) {
      selectedConnectionIds.remove(connectionId);
    } else {
      selectedConnectionIds.add(connectionId);
    }
    notifyListeners();
  }

  @override
  Future<List<PortProcessSnapshot>> fetchPorts(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    fetchPortsCalls.add(connectionId);
    return [
      PortProcessSnapshot(
        port: 80,
        protocol: 'tcp',
        localAddress: '0.0.0.0',
        process: 'nginx',
        state: 'LISTEN',
      ),
    ];
  }

  @override
  Future<List<ApplicationMemorySnapshot>> fetchApplications(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    fetchApplicationsCalls.add(connectionId);
    return const [
      ApplicationMemorySnapshot(
        pid: 101,
        command: 'nginx',
        cpuPercent: 0.5,
        rssBytes: 1024 * 1024 * 5,
        memoryPercent: 0.5,
      ),
    ];
  }

  @override
  Future<List<ServiceStatusSnapshot>> fetchServices(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    fetchServicesCalls.add(connectionId);
    return [
      ServiceStatusSnapshot(
        name: 'nginx.service',
        displayName: 'Nginx Service',
        status: 'running',
        activeState: 'active',
        loadState: 'loaded',
      ),
    ];
  }

  @override
  List<PerformanceSample> visibleSamplesFor(String connectionId) =>
      getSamples(connectionId);

  @override
  List<DiskUsageSnapshot> diskUsageFor(String connectionId) => [];

  @override
  ServerHealthSnapshot healthFor(String connectionId) =>
      getHealth(connectionId);
}
