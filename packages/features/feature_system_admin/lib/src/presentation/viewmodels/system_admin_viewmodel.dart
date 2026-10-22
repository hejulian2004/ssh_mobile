// System Admin Route ViewModel。
//
// ViewModel 负责当前服务器选择、管理数据加载和 Service 监听；不拥有
// App Scope 的连接目录、SSH 或 SFTP 资源。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:connection_core/connection_core.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart';

import '../../application/system_admin_service.dart';
import '../../domain/system_admin_models.dart';
import '../../domain/system_admin_ports.dart';
import '../system_power_confirm_flow.dart';

Future<bool> showSshHostKeyTrustDialog(
  BuildContext context,
  SshHostKeyPromptRequest request,
) {
  return context.read<SystemAdminHostKeyConfirmationPort>().confirm(request);
}

class SystemAdminViewModel extends ChangeNotifier {
  final SystemAdminService _adminService;
  final SystemAdminConnectionCatalogPort _connectionCatalog;

  // View state
  static const _serversCollapsedStorageKey = 'system_admin_servers_collapsed';
  bool _serversCollapsed = false;
  bool _restoredServersCollapsed = false;
  String? _selectedConnectionId;

  // Lists and Loadings
  List<LinuxUserAccount> _accounts = [];
  bool _loadingAccounts = false;
  String? _accountsLoadedFor;

  List<ActiveSession> _sessions = [];
  bool _loadingSessions = false;
  String? _sessionsLoadedFor;

  List<SystemdService> _services = [];
  bool _loadingServices = false;
  String? _servicesLoadedFor;

  List<ListeningPort> _ports = [];
  bool _loadingPorts = false;
  String? _portsLoadedFor;

  String? _lastConnectedId;
  String? _connectingConnectionId;

  SystemAdminViewModel({
    required this._adminService,
    required this._connectionCatalog,
  }) {
    _adminService.addListener(_onAdminServiceChanged);
    _connectionCatalog.addListener(_onStorageChanged);
    if (_adminService.isConnected) {
      _selectedConnectionId = _adminService.connectionId;
      _lastConnectedId = _adminService.connectionId;
    }
  }

  @override
  void dispose() {
    _adminService.removeListener(_onAdminServiceChanged);
    _connectionCatalog.removeListener(_onStorageChanged);
    super.dispose();
  }

  // Getters from service
  String? get managementConnectionId => _adminService.connectionId;
  String? get selectedConnectionId => _selectedConnectionId;
  String? get connectionId => _selectedConnectionId;
  bool get isConnecting => _adminService.isConnecting;
  bool get isConnected => _adminService.isConnected;
  String? get errorMessage => _adminService.errorMessage;
  bool get isRoot => _adminService.isRoot;

  SystemAdminSessionTarget? get activeManagementTarget {
    final target = _adminService.activeTarget;
    if (target == null || target.connectionId != _selectedConnectionId) {
      return null;
    }
    if (!target.binding.matches(connectionById(target.connectionId))) {
      return null;
    }
    return target;
  }

  String? get activeManagementConnectionId {
    return activeManagementTarget?.connectionId;
  }

  bool get canManageSelectedConnection {
    return activeManagementTarget != null && _adminService.isRoot;
  }

  bool get isConnectingSelectedConnection {
    return _adminService.connectionId == _selectedConnectionId &&
        _adminService.isConnecting;
  }

  bool get isConnectedSelectedConnection {
    return _adminService.connectionId == _selectedConnectionId &&
        _adminService.isConnected;
  }

  bool get hasManagementErrorForSelectedConnection {
    return _adminService.connectionId == _selectedConnectionId &&
        _adminService.errorMessage != null;
  }

  List<ConnectionConfig> get connections => _connectionCatalog.connections;
  bool get storageInitialized => _connectionCatalog.isInitialized;
  ConnectionConfig? get selectedConnection =>
      connectionById(_selectedConnectionId);
  bool get hasValidSelection {
    if (_selectedConnectionId == null) return false;
    return selectedConnection != null;
  }

  // Local state getters
  bool get serversCollapsed => _serversCollapsed && connections.isNotEmpty;
  List<LinuxUserAccount> get accounts => _accounts;
  bool get loadingAccounts => _loadingAccounts;

  List<ActiveSession> get sessions => _sessions;
  bool get loadingSessions => _loadingSessions;

  List<SystemdService> get services => _services;
  bool get loadingServices => _loadingServices;

  List<ListeningPort> get ports => _ports;
  bool get loadingPorts => _loadingPorts;

  ConnectionConfig? connectionById(String? id) {
    if (id == null || id.isEmpty) return null;
    return _connectionCatalog.connectionById(id);
  }

  bool isConnectingConnection(String id) {
    return _connectingConnectionId == id && _adminService.isConnecting;
  }

  void restoreServersCollapsed(BuildContext context) {
    if (_restoredServersCollapsed) return;
    _restoredServersCollapsed = true;
    final stored = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: _serversCollapsedStorageKey);
    if (stored is bool) {
      _serversCollapsed = stored;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        notifyListeners();
      });
    }
  }

  void setServersCollapsed(BuildContext context, bool collapsed) {
    if (_serversCollapsed == collapsed) return;
    _serversCollapsed = collapsed;
    PageStorage.maybeOf(
      context,
    )?.writeState(context, collapsed, identifier: _serversCollapsedStorageKey);
    notifyListeners();
  }

  void _onAdminServiceChanged() {
    if (_adminService.isConnected) {
      if (_lastConnectedId != _adminService.connectionId) {
        _lastConnectedId = _adminService.connectionId;

        _selectedConnectionId ??= _adminService.connectionId;

        notifyListeners();
      } else {
        notifyListeners();
      }
    } else {
      _lastConnectedId = null;
      _clearManagementData();
      notifyListeners();
    }
  }

  void _onStorageChanged() {
    if (_selectedConnectionId != null &&
        connectionById(_selectedConnectionId) == null) {
      clearInvalidSelection();
      return;
    }
    final activeTarget = _adminService.activeTarget;
    if (activeTarget != null &&
        !activeTarget.binding.matches(
          connectionById(activeTarget.connectionId),
        )) {
      _clearManagementData();
      unawaited(_adminService.disconnect());
      return;
    }
    notifyListeners();
  }

  void _clearManagementData() {
    _accounts.clear();
    _sessions.clear();
    _services.clear();
    _ports.clear();

    _loadingAccounts = false;
    _loadingSessions = false;
    _loadingServices = false;
    _loadingPorts = false;

    _accountsLoadedFor = null;
    _sessionsLoadedFor = null;
    _servicesLoadedFor = null;
    _portsLoadedFor = null;
  }

  void clearInvalidSelection() {
    final oldSelectedId = _selectedConnectionId;
    if (oldSelectedId == null) return;

    _selectedConnectionId = null;
    _clearManagementData();

    if (_adminService.connectionId == oldSelectedId) {
      unawaited(_adminService.disconnect());
    }

    notifyListeners();
  }

  void validateSelectedConnection() {
    if (_selectedConnectionId == null) return;
    if (connectionById(_selectedConnectionId) != null) return;
    clearInvalidSelection();
  }

  // Connect & Disconnect Actions
  void selectConnection(String id) {
    if (_selectedConnectionId == id) return;
    _selectedConnectionId = id;
    _clearManagementData();
    notifyListeners();
  }

  Future<void> connect(
    String id, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final config = connectionById(id);
    if (config == null) throw StateError('Connection config not found');
    await _adminService.connect(
      SshTargetBinding.fromConfig(config),
      onUnknownHostKey: onUnknownHostKey,
    );
  }

  Future<void> connectIfNeeded(
    String id, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    if (_selectedConnectionId != id) return;

    if (_connectingConnectionId == id && _adminService.isConnecting) return;

    final config = connectionById(id);
    if (config == null) return;
    final currentTarget = activeManagementTarget;
    if (currentTarget != null &&
        currentTarget.binding.matches(config) &&
        _adminService.isRoot) {
      return;
    }

    _connectingConnectionId = id;
    notifyListeners();

    try {
      await _adminService.connect(
        SshTargetBinding.fromConfig(config),
        onUnknownHostKey: onUnknownHostKey,
      );
    } finally {
      if (_connectingConnectionId == id) {
        _connectingConnectionId = null;
        notifyListeners();
      }
    }
  }

  Future<void> disconnect() => _adminService.disconnect();

  Future<void> disconnectTarget(SystemAdminSessionTarget target) async {
    if (_adminService.isActiveTarget(target)) await _adminService.disconnect();
  }

  // Data retrieval wrapper methods
  Future<void> refreshAllData() async {
    final id = activeManagementConnectionId;
    if (id == null) return;
    await fetchAccounts(id, force: true);
    await fetchSessions(id, force: true);
    await fetchServices(id, force: true);
    await fetchPorts(id, force: true);
  }

  Duration debounceDuration = const Duration(milliseconds: 300);
  int _commandEpoch = 0;

  /// Cancel all active management commands and reset loading states
  void cancelActiveCommands() {
    _commandEpoch++;

    _adminService.cancelActiveCommands();
    bool stateChanged = false;
    if (_loadingAccounts) {
      _loadingAccounts = false;
      stateChanged = true;
    }
    if (_loadingSessions) {
      _loadingSessions = false;
      stateChanged = true;
    }
    if (_loadingServices) {
      _loadingServices = false;
      stateChanged = true;
    }
    if (_loadingPorts) {
      _loadingPorts = false;
      stateChanged = true;
    }
    if (stateChanged) {
      notifyListeners();
    }
  }

  Future<void> fetchAccounts(String connId, {bool force = false}) async {
    if (!force && _accountsLoadedFor == connId) return;
    final target = activeManagementTarget;
    if (target == null || target.connectionId != connId) return;

    cancelActiveCommands();
    final commandEpoch = _commandEpoch;
    _loadingAccounts = true;
    notifyListeners();

    Future<void> performFetch() async {
      try {
        final data = await _adminService.getUserAccounts(target);
        if (_selectedConnectionId != connId ||
            commandEpoch != _commandEpoch ||
            !_adminService.isActiveTarget(target)) {
          return;
        }
        _accounts = data;
        _accountsLoadedFor = connId;
      } finally {
        if (_selectedConnectionId == connId && commandEpoch == _commandEpoch) {
          _loadingAccounts = false;
          notifyListeners();
        }
      }
    }

    if (force || debounceDuration == Duration.zero) {
      await performFetch();
    } else {
      await Future<void>.delayed(debounceDuration);
      if (commandEpoch != _commandEpoch) return;
      await performFetch();
    }
  }

  Future<void> fetchSessions(String connId, {bool force = false}) async {
    if (!force && _sessionsLoadedFor == connId) return;
    final target = activeManagementTarget;
    if (target == null || target.connectionId != connId) return;

    cancelActiveCommands();
    final commandEpoch = _commandEpoch;
    _loadingSessions = true;
    notifyListeners();

    Future<void> performFetch() async {
      try {
        final data = await _adminService.getActiveSessions(target);
        if (_selectedConnectionId != connId ||
            commandEpoch != _commandEpoch ||
            !_adminService.isActiveTarget(target)) {
          return;
        }
        _sessions = data;
        _sessionsLoadedFor = connId;
      } finally {
        if (_selectedConnectionId == connId && commandEpoch == _commandEpoch) {
          _loadingSessions = false;
          notifyListeners();
        }
      }
    }

    if (force || debounceDuration == Duration.zero) {
      await performFetch();
    } else {
      await Future<void>.delayed(debounceDuration);
      if (commandEpoch != _commandEpoch) return;
      await performFetch();
    }
  }

  Future<void> fetchServices(String connId, {bool force = false}) async {
    if (!force && _servicesLoadedFor == connId) return;
    final target = activeManagementTarget;
    if (target == null || target.connectionId != connId) return;

    cancelActiveCommands();
    final commandEpoch = _commandEpoch;
    _loadingServices = true;
    notifyListeners();

    Future<void> performFetch() async {
      try {
        final data = await _adminService.getSystemdServices(target);
        if (_selectedConnectionId != connId ||
            commandEpoch != _commandEpoch ||
            !_adminService.isActiveTarget(target)) {
          return;
        }
        _services = data;
        _servicesLoadedFor = connId;
      } finally {
        if (_selectedConnectionId == connId && commandEpoch == _commandEpoch) {
          _loadingServices = false;
          notifyListeners();
        }
      }
    }

    if (force || debounceDuration == Duration.zero) {
      await performFetch();
    } else {
      await Future<void>.delayed(debounceDuration);
      if (commandEpoch != _commandEpoch) return;
      await performFetch();
    }
  }

  Future<void> fetchPorts(String connId, {bool force = false}) async {
    if (!force && _portsLoadedFor == connId) return;
    final target = activeManagementTarget;
    if (target == null || target.connectionId != connId) return;

    cancelActiveCommands();
    final commandEpoch = _commandEpoch;
    _loadingPorts = true;
    notifyListeners();

    Future<void> performFetch() async {
      try {
        final data = await _adminService.getListeningPorts(target);
        if (_selectedConnectionId != connId ||
            commandEpoch != _commandEpoch ||
            !_adminService.isActiveTarget(target)) {
          return;
        }
        _ports = data;
        _portsLoadedFor = connId;
      } finally {
        if (_selectedConnectionId == connId && commandEpoch == _commandEpoch) {
          _loadingPorts = false;
          notifyListeners();
        }
      }
    }

    if (force || debounceDuration == Duration.zero) {
      await performFetch();
    } else {
      await Future<void>.delayed(debounceDuration);
      if (commandEpoch != _commandEpoch) return;
      await performFetch();
    }
  }

  // Administration actions
  Future<void> createUser(
    String username,
    String password, {
    String shell = '/bin/bash',
  }) async {
    final target = activeManagementTarget;
    if (target == null) return;
    await _adminService.createUser(
      target,
      username: username,
      password: password,
      shell: shell,
    );
    if (_adminService.isActiveTarget(target)) {
      await fetchAccounts(target.connectionId, force: true);
    }
  }

  Future<bool> checkUserSudo(String username) async {
    final target = activeManagementTarget;
    if (target == null) return false;
    return _adminService.checkUserSudo(target, username);
  }

  Future<void> setUserSudo(String username, bool grant) async {
    final target = activeManagementTarget;
    if (target == null) return;
    await _adminService.setUserSudo(target, username, grant);
    if (_adminService.isActiveTarget(target)) {
      await fetchAccounts(target.connectionId, force: true);
    }
  }

  Future<void> lockUser(String username) async {
    final target = activeManagementTarget;
    if (target == null) return;
    await _adminService.lockUser(target, username);
    if (_adminService.isActiveTarget(target)) {
      await fetchAccounts(target.connectionId, force: true);
    }
  }

  Future<void> unlockUser(String username) async {
    final target = activeManagementTarget;
    if (target == null) return;
    await _adminService.unlockUser(target, username);
    if (_adminService.isActiveTarget(target)) {
      await fetchAccounts(target.connectionId, force: true);
    }
  }

  Future<void> changePassword(String username, String newPassword) async {
    final target = activeManagementTarget;
    if (target == null) return;
    await _adminService.changePassword(target, username, newPassword);
    if (_adminService.isActiveTarget(target)) {
      await fetchAccounts(target.connectionId, force: true);
    }
  }

  Future<String> getUserHomeStorageUsage(String homeDir) async {
    final target = activeManagementTarget;
    if (target == null) return 'N/A';
    return _adminService.getUserHomeStorageUsage(target, homeDir);
  }

  Future<List<LinuxUserProcess>> getUserProcessesAndMemory(
    String username,
  ) async {
    final target = activeManagementTarget;
    if (target == null) return [];
    return _adminService.getUserProcessesAndMemory(target, username);
  }

  Future<void> killActiveSession(String tty) async {
    final target = activeManagementTarget;
    if (target == null) return;
    await _adminService.killActiveSession(target, tty);
    if (_adminService.isActiveTarget(target)) {
      await fetchSessions(target.connectionId, force: true);
    }
  }

  Future<void> manageSystemdService(String serviceName, String action) async {
    final target = activeManagementTarget;
    if (target == null) return;
    await _adminService.manageSystemdService(target, serviceName, action);
    if (_adminService.isActiveTarget(target)) {
      await fetchServices(target.connectionId, force: true);
    }
  }

  Future<void> rebootServer(SystemPowerConfirmationToken token) async {
    if (token.action != SystemPowerAction.reboot) {
      throw ArgumentError('Invalid token action for rebootServer');
    }
    if (!token.isFresh) {
      throw StateError('System power confirmation token expired');
    }
    await _adminService.rebootServer(token);
  }

  Future<void> shutdownServer(SystemPowerConfirmationToken token) async {
    if (token.action != SystemPowerAction.shutdown) {
      throw ArgumentError('Invalid token action for shutdownServer');
    }
    if (!token.isFresh) {
      throw StateError('System power confirmation token expired');
    }
    await _adminService.shutdownServer(token);
  }
}
