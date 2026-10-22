// System Admin 页面主 Shell。
//
// 主页面组织七个管理 Tab 和按需激活逻辑；各 Tab 通过 part 文件保持
// 原有 UI 行为，同时统一读取 Package 内的 Port/Route ViewModel。

import 'dart:async';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:connection_core/connection_core.dart';

import 'package:app_ui/app_ui.dart';

import '../../domain/system_admin_monitoring.dart';
import '../../domain/system_admin_models.dart';
import '../../domain/system_admin_ports.dart';
import '../system_power_confirm_flow.dart';
import '../system_admin_server_selector.dart';
import '../viewmodels/system_admin_viewmodel.dart';

part 'system_admin_server_pane.dart';
part 'users_tab.dart';
part 'sessions_tab.dart';
part 'services_tab.dart';
part 'ports_tab.dart';
part 'power_tab.dart';
part 'monitor_models.dart';
part 'performance_charts.dart';
part 'health_disk_views.dart';
part 'details_views.dart';
part 'monitor_config.dart';
part 'monitor_tab.dart';
part 'applications_tab.dart';

// 这些别名只兼容同一 library 的迁移中 part 文件；它们不指向 App Service
// 实现，最终公共类型仍是 System Admin 自己的 Port 和 Domain 模型。
typedef AppLanguage = SystemAdminLanguage;
typedef AppSettings = SystemAdminSettingsPort;
typedef AppStrings = SystemAdminStrings;
typedef PerformanceMonitorViewModel = SystemAdminMonitoringPort;
typedef PerformanceMonitorService = SystemAdminMonitoringPort;
typedef ConnectionCatalog = SystemAdminConnectionCatalogPort;
typedef SftpService = SystemAdminFileBrowserPort;
typedef SftpEntry = SystemAdminFileEntry;

class SystemAdminScreen extends StatefulWidget {
  const SystemAdminScreen({super.key});

  @override
  State<SystemAdminScreen> createState() => _SystemAdminScreenState();
}

class _SystemAdminScreenState extends State<SystemAdminScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ValueNotifier<int> _activeTabIndex = ValueNotifier<int>(0);
  final GlobalKey<_PortsTabState> _portsTabKey = GlobalKey<_PortsTabState>();
  final GlobalKey<_ApplicationsTabState> _applicationsTabKey =
      GlobalKey<_ApplicationsTabState>();
  final GlobalKey<_ServicesTabState> _servicesTabKey =
      GlobalKey<_ServicesTabState>();
  int? _lastActivatedTabIndex;
  String? _lastActivatedConnectionId;
  String? _lastObservedSelectedConnectionId;
  List<ConnectionConfig>? _lastObservedConnections;
  bool _activationScheduled = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _tabController.addListener(_handleTabSelection);
  }

  void _handleTabSelection() {
    if (!mounted) return;
    final index = _tabController.index;
    if (_activeTabIndex.value != index) {
      _activeTabIndex.value = index;
      context.read<SystemAdminViewModel>().cancelActiveCommands();
    }
    _scheduleCurrentTabActivation();
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabSelection);
    _tabController.dispose();
    _activeTabIndex.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.read<SystemAdminViewModel>().restoreServersCollapsed(context);
    _scheduleCurrentTabActivation();
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.select<SystemAdminSettingsPort, SystemAdminStrings>(
      (settings) => settings.strings,
    );

    return Selector<SystemAdminViewModel, _SystemAdminShellSnapshot>(
      selector: (_, vm) => _SystemAdminShellSnapshot.from(vm),
      builder: (context, snapshot, _) {
        final viewModelRead = context.read<SystemAdminViewModel>();
        _maybeScheduleActivationForSelectionChange(viewModelRead);

        if (!snapshot.storageReady) {
          return Center(
            child: AppSkeletonizer.zone(
              enabled: true,
              semanticsLabel: strings.connectingEllipsis,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Bone(
                      width: double.infinity,
                      height: 48,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    const SizedBox(height: 12),
                    Bone(
                      width: double.infinity,
                      height: 48,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        if (snapshot.connections.isEmpty) {
          return AppEmptyState(
            icon: Icons.monitor_heart_outlined,
            title: strings.systemOmAdmin,
            message: strings.selectServerToManage,
            action: FilledButton.icon(
              onPressed: () => Navigator.pushNamed(context, '/add'),
              icon: const Icon(Icons.add_rounded),
              label: Text(strings.addConnection),
            ),
          );
        }

        final isTwoColumn =
            isDesktopTargetPlatform() ||
            WindowSizeClass.of(context).isExpandedOrLarger;
        final colorScheme = Theme.of(context).colorScheme;

        final bodyContent = _buildMainContent(
          strings,
          colorScheme,
          _activeTabIndex,
          reserveTopRightRefreshSpace: isTwoColumn,
        );

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: AppPageSurface(
            child: ValueListenableBuilder<int>(
              valueListenable: _activeTabIndex,
              builder: (context, activeIndex, _) {
                final isMonitorTab = activeIndex == 0;
                final textScale = MediaQuery.textScalerOf(
                  context,
                ).scale(1).clamp(1.0, 2.0).toDouble();
                final expandedMobileServerHeight =
                    72.0 + (textScale - 1.0) * 38.0;
                final collapsedMobileServerHeight =
                    48.0 + (textScale - 1.0) * 22.0;
                return isTwoColumn
                    ? Row(
                        children: [
                          AnimatedSize(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.centerLeft,
                            clipBehavior: Clip.hardEdge,
                            child: SizedBox(
                              width: snapshot.serversCollapsed ? 64 : 320,
                              child: snapshot.serversCollapsed
                                  ? _AdminCollapsedDesktopServerRail(
                                      key: const ValueKey(
                                        'admin-server-rail-collapsed',
                                      ),
                                      strings: strings,
                                      isMonitorTab: isMonitorTab,
                                      onExpand: () => context
                                          .read<SystemAdminViewModel>()
                                          .setServersCollapsed(context, false),
                                    )
                                  : _AdminServerPane(
                                      strings: strings,
                                      isMonitorTab: isMonitorTab,
                                      onCollapse: () => context
                                          .read<SystemAdminViewModel>()
                                          .setServersCollapsed(context, true),
                                    ),
                            ),
                          ),
                          VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          Expanded(
                            child: ValueListenableBuilder<int>(
                              valueListenable: _activeTabIndex,
                              builder: (context, activeIndex, _) => Stack(
                                children: [
                                  Positioned.fill(child: bodyContent),
                                  if (_tabSupportsRefresh(activeIndex))
                                    Positioned(
                                      top: 4,
                                      right: 4,
                                      child: _buildTabRefreshButton(strings),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            height: snapshot.serversCollapsed
                                ? collapsedMobileServerHeight
                                : expandedMobileServerHeight,
                            child: Row(
                              children: [
                                Expanded(
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 180),
                                    switchInCurve: Curves.easeOutCubic,
                                    switchOutCurve: Curves.easeInCubic,
                                    layoutBuilder: (currentChild, _) =>
                                        currentChild ?? const SizedBox.shrink(),
                                    child: snapshot.serversCollapsed
                                        ? _AdminCollapsedMobileServerBar(
                                            key: const ValueKey(
                                              'admin-server-collapsed',
                                            ),
                                            strings: strings,
                                            isMonitorTab: isMonitorTab,
                                            onExpand: () => context
                                                .read<SystemAdminViewModel>()
                                                .setServersCollapsed(
                                                  context,
                                                  false,
                                                ),
                                          )
                                        : _AdminMobileServerStrip(
                                            key: const ValueKey(
                                              'admin-server-expanded',
                                            ),
                                            strings: strings,
                                            isMonitorTab: isMonitorTab,
                                            onCollapse: () => context
                                                .read<SystemAdminViewModel>()
                                                .setServersCollapsed(
                                                  context,
                                                  true,
                                                ),
                                          ),
                                  ),
                                ),
                                if (_tabSupportsRefresh(activeIndex))
                                  Material(
                                    color: colorScheme.surface,
                                    child: SizedBox(
                                      width: 56,
                                      height: double.infinity,
                                      child: Center(
                                        child: _buildTabRefreshButton(strings),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          Expanded(child: bodyContent),
                        ],
                      );
              },
            ),
          ),
        );
      },
    );
  }

  void _maybeScheduleActivationForSelectionChange(
    SystemAdminViewModel viewModel,
  ) {
    final currentSelectedId = viewModel.selectedConnectionId;
    final currentConnections = viewModel.connections;

    final selectedIdChanged =
        _lastObservedSelectedConnectionId != currentSelectedId;
    final connectionsChanged = !identical(
      _lastObservedConnections,
      currentConnections,
    );

    if (!selectedIdChanged && !connectionsChanged) return;

    _lastObservedSelectedConnectionId = currentSelectedId;
    _lastObservedConnections = currentConnections;
    _lastActivatedConnectionId = null;

    _scheduleCurrentTabActivation(viewModel);
  }

  void _scheduleCurrentTabActivation([SystemAdminViewModel? viewModel]) {
    if (_activationScheduled) return;
    _activationScheduled = true;

    final activeViewModel =
        viewModel ?? (mounted ? context.read<SystemAdminViewModel>() : null);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activationScheduled = false;
      if (!mounted || activeViewModel == null) return;

      activeViewModel.validateSelectedConnection();

      final selectedId = activeViewModel.selectedConnectionId;
      if (selectedId == null) return;

      final index = _tabController.index;
      final activationKeyChanged =
          _lastActivatedTabIndex != index ||
          _lastActivatedConnectionId != selectedId;

      if (!activationKeyChanged) return;

      _lastActivatedTabIndex = index;
      _lastActivatedConnectionId = selectedId;

      unawaited(_activateTab(index, activeViewModel));
    });
  }

  Future<void> _activateTab(int index, SystemAdminViewModel viewModel) async {
    final selectedId = viewModel.selectedConnectionId;
    if (selectedId == null) return;

    final config = viewModel.connectionById(selectedId);
    if (config == null) {
      viewModel.clearInvalidSelection();
      return;
    }

    final isLinux = config.serverPlatform == ServerPlatform.linux;

    switch (index) {
      case 0:
      case 1:
      case 2:
      case 3:
        return;
      case 4:
        if (!isLinux) return;
        await viewModel.connectIfNeeded(
          selectedId,
          onUnknownHostKey: (request) => context
              .read<SystemAdminHostKeyConfirmationPort>()
              .confirm(request),
        );
        if (!mounted) return;
        if (viewModel.canManageSelectedConnection) {
          await viewModel.fetchAccounts(selectedId);
        }
        return;
      case 5:
        if (!isLinux) return;
        await viewModel.connectIfNeeded(
          selectedId,
          onUnknownHostKey: (request) => context
              .read<SystemAdminHostKeyConfirmationPort>()
              .confirm(request),
        );
        if (!mounted) return;
        if (viewModel.canManageSelectedConnection) {
          await viewModel.fetchSessions(selectedId);
        }
        return;
      case 6:
        if (!isLinux) return;
        await viewModel.connectIfNeeded(
          selectedId,
          onUnknownHostKey: (request) => context
              .read<SystemAdminHostKeyConfirmationPort>()
              .confirm(request),
        );
        return;
    }
  }

  Widget _buildMainContent(
    SystemAdminStrings strings,
    ColorScheme colorScheme,
    ValueNotifier<int> activeTabIndex, {
    required bool reserveTopRightRefreshSpace,
  }) {
    // TabController organizes all Admin tabs
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surface.withValues(alpha: 0.74),
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: ValueListenableBuilder<int>(
            valueListenable: activeTabIndex,
            builder: (context, activeIndex, _) => Padding(
              padding: EdgeInsets.only(
                right:
                    reserveTopRightRefreshSpace &&
                        _tabSupportsRefresh(activeIndex)
                    ? 56
                    : 0,
              ),
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) => true,
                child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                  tabs: [
                    Tab(
                      text: strings.monitor,
                      icon: const Icon(Icons.monitor_heart_outlined),
                    ),
                    Tab(
                      text: strings.listeningPorts,
                      icon: const Icon(Icons.lan),
                    ),
                    Tab(
                      text: strings.applications,
                      icon: const Icon(Icons.apps_rounded),
                    ),
                    Tab(
                      text: strings.systemServices,
                      icon: const Icon(Icons.settings_suggest),
                    ),
                    Tab(
                      text: strings.userAccounts,
                      icon: const Icon(Icons.people),
                    ),
                    Tab(
                      text: strings.activeSessions,
                      icon: const Icon(Icons.co_present),
                    ),
                    Tab(
                      text: strings.systemPower,
                      icon: const Icon(Icons.power_settings_new),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              // Tab 0: Monitor
              _MonitorTab(
                strings: strings,
                tabController: _tabController,
                onStartMonitoring: () async {
                  final monitorVm = context.read<SystemAdminMonitoringPort>();
                  await monitorVm.startMonitoring(
                    onUnknownHostKey: (request) => context
                        .read<SystemAdminHostKeyConfirmationPort>()
                        .confirm(request),
                  );
                  if (mounted && monitorVm.isRunning) {
                    context.read<SystemAdminViewModel>().setServersCollapsed(
                      context,
                      true,
                    );
                  }
                },
              ),
              // Tab 1: Ports (Manage/Snapshot)
              _PortsTab(
                key: _portsTabKey,
                strings: strings,
                colorScheme: colorScheme,
                viewModel: context.read<SystemAdminViewModel>(),
                activeTabIndex: activeTabIndex,
              ),
              // Tab 2: Applications (Snapshot only)
              _ApplicationsTab(
                key: _applicationsTabKey,
                strings: strings,
                colorScheme: colorScheme,
                viewModel: context.read<SystemAdminViewModel>(),
                monitorViewModel: context.read<SystemAdminMonitoringPort>(),
                activeTabIndex: activeTabIndex,
              ),
              // Tab 3: Services (Manage/Snapshot)
              _ServicesTab(
                key: _servicesTabKey,
                strings: strings,
                colorScheme: colorScheme,
                viewModel: context.read<SystemAdminViewModel>(),
                activeTabIndex: activeTabIndex,
              ),
              // Tab 4: Users (Requires root connection)
              _RootRequiredTabWrapper(
                onConnected: (connectionId) => context
                    .read<SystemAdminViewModel>()
                    .fetchAccounts(connectionId, force: true),
                child: _UsersTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: context.read<SystemAdminViewModel>(),
                ),
              ),
              // Tab 5: Sessions (Requires root connection)
              _RootRequiredTabWrapper(
                onConnected: (connectionId) => context
                    .read<SystemAdminViewModel>()
                    .fetchSessions(connectionId, force: true),
                child: _SessionsTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: context.read<SystemAdminViewModel>(),
                ),
              ),
              // Tab 6: Power (Requires root connection)
              _RootRequiredTabWrapper(
                child: _PowerTab(
                  strings: strings,
                  colorScheme: colorScheme,
                  viewModel: context.read<SystemAdminViewModel>(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  bool _tabSupportsRefresh(int index) => index >= 1 && index <= 5;

  Widget _buildTabRefreshButton(SystemAdminStrings strings) {
    return IconButton(
      key: const ValueKey('system-admin-tab-refresh'),
      tooltip: strings.refresh,
      onPressed: _refreshActiveTab,
      icon: const Icon(Icons.refresh_rounded),
    );
  }

  void _refreshActiveTab() {
    final viewModel = context.read<SystemAdminViewModel>();
    final connectionId = viewModel.selectedConnectionId;
    if (connectionId == null) return;

    switch (_activeTabIndex.value) {
      case 1:
        _portsTabKey.currentState?.refresh();
      case 2:
        _applicationsTabKey.currentState?.refresh();
      case 3:
        _servicesTabKey.currentState?.refresh();
      case 4:
        unawaited(viewModel.fetchAccounts(connectionId, force: true));
      case 5:
        unawaited(viewModel.fetchSessions(connectionId, force: true));
    }
  }
}

class _RootRequiredTabWrapper extends StatelessWidget {
  final Widget child;
  final Future<void> Function(String connectionId)? onConnected;

  const _RootRequiredTabWrapper({required this.child, this.onConnected});

  @override
  Widget build(BuildContext context) {
    final strings = context.select<SystemAdminSettingsPort, SystemAdminStrings>(
      (settings) => settings.strings,
    );
    final selectedConnectionId = context.select<SystemAdminViewModel, String?>(
      (vm) => vm.selectedConnectionId,
    );

    if (selectedConnectionId == null) {
      return _AdminEmptyState(strings: strings);
    }

    final selectedConnection = context
        .select<SystemAdminViewModel, ConnectionConfig?>(
          (vm) => vm.connectionById(selectedConnectionId),
        );
    if (selectedConnection == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.read<SystemAdminViewModel>().clearInvalidSelection();
      });
      return _AdminEmptyState(strings: strings);
    }

    if (selectedConnection.serverPlatform != ServerPlatform.linux) {
      return AppEmptyState(
        icon: Icons.desktop_windows_outlined,
        title: strings.nonLinuxMsg,
        message: strings.adminLinuxManagementHint,
      );
    }

    final isConnecting = context.select<SystemAdminViewModel, bool>(
      (vm) => vm.isConnectingSelectedConnection,
    );
    final isConnected = context.select<SystemAdminViewModel, bool>(
      (vm) => vm.isConnectedSelectedConnection,
    );
    final hasError = context.select<SystemAdminViewModel, bool>(
      (vm) => vm.hasManagementErrorForSelectedConnection,
    );
    final errorMessage = hasError
        ? context.select<SystemAdminViewModel, String?>((vm) => vm.errorMessage)
        : null;
    final isRoot =
        isConnected &&
        context.select<SystemAdminViewModel, bool>((vm) => vm.isRoot);

    if (isConnecting) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: AppSectionCard(
            title: strings.adminRootAccess,
            subtitle: strings.verifyingPrivilege,
            icon: Icons.admin_panel_settings_outlined,
            padding: const EdgeInsets.all(22),
            child: AppSkeletonizer.zone(
              enabled: true,
              semanticsLabel: strings.verifyingPrivilege,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const AppIconBadge(
                      icon: Icons.security_rounded,
                      size: 36,
                      iconSize: 18,
                    ),
                    title: const Text('Verifying root & sudo privileges'),
                    subtitle: const Text(
                      'Checking execution permissions on remote host...',
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: FilledButton.tonal(
                      onPressed: null,
                      child: Text(strings.verifyingPrivilege),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (!isConnected || !isRoot || errorMessage != null) {
      return _RootRequiredView(
        strings: strings,
        errorMessage: errorMessage,
        onConnect: () =>
            unawaited(_connectAndLoad(context, selectedConnectionId)),
      );
    }

    return child;
  }

  Future<void> _connectAndLoad(
    BuildContext context,
    String connectionId,
  ) async {
    final viewModel = context.read<SystemAdminViewModel>();
    await viewModel.connectIfNeeded(
      connectionId,
      onUnknownHostKey: (request) =>
          context.read<SystemAdminHostKeyConfirmationPort>().confirm(request),
    );
    if (!context.mounted || !viewModel.canManageSelectedConnection) return;
    await onConnected?.call(connectionId);
  }
}

class _RootRequiredView extends StatelessWidget {
  final SystemAdminStrings strings;
  final String? errorMessage;
  final VoidCallback? onConnect;

  const _RootRequiredView({
    required this.strings,
    this.errorMessage,
    this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    final isPrivilegeError =
        errorMessage != null &&
        (errorMessage!.toLowerCase().contains('privilege') ||
            errorMessage!.toLowerCase().contains('root required') ||
            errorMessage!.toLowerCase().contains('insufficient'));

    return AppEmptyState(
      icon: isPrivilegeError || errorMessage == null
          ? Icons.gpp_bad_outlined
          : Icons.error_outline_rounded,
      title: isPrivilegeError || errorMessage == null
          ? strings.adminRootAccess
          : strings.adminConnectionFailed,
      message: errorMessage == null
          ? '${strings.rootRequiredMsg}\n${strings.reconnectAsRootMsg}'
          : '$errorMessage\n${strings.reconnectAsRootMsg}',
      action: onConnect == null
          ? null
          : FilledButton.icon(
              key: const ValueKey('system-admin-connect-root'),
              icon: const Icon(Icons.admin_panel_settings_rounded),
              label: Text(strings.adminConnectAsRoot),
              onPressed: onConnect,
            ),
    );
  }
}

class _AdminEmptyState extends StatelessWidget {
  final SystemAdminStrings strings;

  const _AdminEmptyState({required this.strings});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => AppEmptyState(
        icon: Icons.monitor_heart_outlined,
        title: strings.systemOmAdmin,
        message: strings.selectServerToManage,
        compact: constraints.maxWidth < 420,
      ),
    );
  }
}

class _MonitorResponsiveEmptyState extends StatelessWidget {
  final SystemAdminStrings strings;
  final String? message;

  const _MonitorResponsiveEmptyState({required this.strings, this.message});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxHeight < 220 || constraints.maxWidth < 420;
        return AppEmptyState(
          icon: Icons.monitor_heart_outlined,
          title: _monitorText(
            strings,
            'Select servers to monitor',
            '选择要监控的服务器',
          ),
          message:
              message ??
              _monitorText(
                strings,
                'Select one or more servers, then start monitoring. Sampling stays silent until started.',
                '可多选服务器，点击开始监控后才采样；未开始前保持静默。',
              ),
          compact: compact,
        );
      },
    );
  }
}

// Helpers
String _serverSummary(
  SystemAdminStrings strings,
  List<ConnectionConfig> connections,
) {
  if (connections.isEmpty) {
    return _monitorText(strings, 'Monitor servers', '监控服务器');
  }
  if (connections.length == 1) {
    final connection = connections.first;
    return '${connection.name}  ${connection.username}@${connection.host}';
  }
  return _monitorText(
    strings,
    '${connections.length} selected',
    '已选择 ${connections.length} 台',
  );
}

String _monitorText(SystemAdminStrings strings, String en, String zh) {
  return strings.language == SystemAdminLanguage.en ? en : zh;
}

String _selectServerHint(
  BuildContext context,
  SystemAdminLanguage language, {
  required String targetEn,
  required String targetZh,
}) {
  final isDesktopPlatform = isDesktopTargetPlatform();
  final desktop =
      isDesktopPlatform || WindowSizeClass.of(context).isExpandedOrLarger;
  final isEnglish = language == SystemAdminLanguage.en;

  if (isEnglish) {
    return desktop
        ? 'Please select a server on the left to view $targetEn.'
        : 'Please select a server above to view $targetEn.';
  }

  return desktop ? '请先在左侧选择要查看的$targetZh。' : '请先在上方选择要查看的$targetZh。';
}

/// 统一的系统管理列表容器，提供一致的 1px 微边框与表面底色。
class _AdminListSurface extends StatelessWidget {
  final Widget child;

  const _AdminListSurface({required this.child});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.8),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

String _durationLabel(Duration duration) {
  if (duration.inMinutes >= 1 && duration.inSeconds % 60 == 0) {
    return '${duration.inMinutes}m';
  }
  return '${duration.inSeconds}s';
}

String _runDurationLabel(DateTime? startedAt) {
  if (startedAt == null) return '0s';
  final duration = DateTime.now().difference(startedAt);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m ${seconds}s';
  return '${seconds}s';
}

Color _healthColor(BuildContext context, ServerHealthLevel level) {
  final status = AppStatusColors.of(context);
  return switch (level) {
    ServerHealthLevel.healthy => status.success,
    ServerHealthLevel.warning => status.warning,
    ServerHealthLevel.critical => status.error,
    ServerHealthLevel.unknown => status.neutral,
  };
}

IconData _healthIcon(ServerHealthLevel level) {
  return switch (level) {
    ServerHealthLevel.healthy => Icons.verified_rounded,
    ServerHealthLevel.warning => Icons.warning_amber_rounded,
    ServerHealthLevel.critical => Icons.error_rounded,
    ServerHealthLevel.unknown => Icons.help_outline_rounded,
  };
}

String _healthLabel(SystemAdminStrings strings, ServerHealthLevel level) {
  final en = strings.language == SystemAdminLanguage.en;
  return switch (level) {
    ServerHealthLevel.healthy => en ? 'Healthy' : '正常',
    ServerHealthLevel.warning => en ? 'Warning' : '警告',
    ServerHealthLevel.critical => en ? 'Critical' : '危险',
    ServerHealthLevel.unknown => en ? 'No samples' : '暂无采样',
  };
}

Color _monitorSeriesColor(int index) {
  const palette = [
    Colors.blue,
    Colors.teal,
    Colors.deepOrange,
    Colors.indigo,
    Colors.pink,
    Colors.green,
    Colors.cyan,
    Colors.brown,
  ];
  return palette[index % palette.length];
}

class _SystemAdminShellSnapshot {
  final bool storageReady;
  final bool serversCollapsed;
  final String? selectedConnectionId;
  final List<ConnectionConfig> connections;

  const _SystemAdminShellSnapshot({
    required this.storageReady,
    required this.serversCollapsed,
    required this.selectedConnectionId,
    required this.connections,
  });

  factory _SystemAdminShellSnapshot.from(SystemAdminViewModel vm) {
    return _SystemAdminShellSnapshot(
      storageReady: vm.storageInitialized,
      serversCollapsed: vm.serversCollapsed,
      selectedConnectionId: vm.selectedConnectionId,
      connections: List.unmodifiable(vm.connections),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _SystemAdminShellSnapshot &&
        other.storageReady == storageReady &&
        other.serversCollapsed == serversCollapsed &&
        other.selectedConnectionId == selectedConnectionId &&
        listEquals(other.connections, connections);
  }

  @override
  int get hashCode => Object.hash(
    storageReady,
    serversCollapsed,
    selectedConnectionId,
    Object.hashAll(connections),
  );
}
