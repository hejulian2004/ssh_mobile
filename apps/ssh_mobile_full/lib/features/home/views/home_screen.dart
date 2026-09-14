import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:feature_connection/feature_connection.dart';
import 'package:feature_ai/feature_ai.dart' as feature_ai;
import 'package:app_core/app_core.dart' as app_core;
import 'package:feature_developer/feature_developer.dart' as feature_developer;
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_sftp/feature_sftp.dart' as feature_sftp;
import 'package:feature_system_admin/feature_system_admin.dart'
    as feature_system_admin;
import 'package:feature_webview/feature_webview.dart';
import 'package:ssh_mobile/features/settings/viewmodels/settings_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:app_ui/app_ui.dart';
import 'package:ssh_mobile/app/sftp_feature_adapters.dart';
import 'package:ssh_mobile/app/system_admin_feature_adapters.dart';
import 'package:ssh_mobile/app/connection_route_scope.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:ssh_mobile/features/home/views/widgets/home_navigation_semantics.dart';

part 'widgets/settings_panel.dart';
part 'widgets/settings_sections.dart';
part 'widgets/server_list_pane.dart';
part 'widgets/server_connection_widgets.dart';

class HomeScreen extends StatefulWidget {
  final int initialIndex;

  // Servers stays first in navigation. App launch lands on Servers.
  const HomeScreen({super.key, this.initialIndex = 0});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _serverPage = 0;
  static const int _sftpPage = 1;
  static const int _aiPage = 2;
  static const int _adminPage = 3;
  static const int _logPage = 4;
  static const int _firstPage = _serverPage;
  static const int _lastPage = _logPage;

  late int _selectedIndex;
  bool _aiHistoryVisible = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex.clamp(_firstPage, _lastPage);
  }

  void updateState(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final windowClass = WindowSizeClass.of(context);
    final isDesktop = isDesktopTargetPlatform();
    final useRailNavigation = isDesktop || windowClass.isExpandedOrLarger;
    final useMobileBottomNavigation = !useRailNavigation;

    final mediaQuery = MediaQuery.of(context);
    final compactKeyboardLayout =
        useRailNavigation &&
        usesCompactKeyboardLayoutFor(
          viewportHeight: mediaQuery.size.height,
          keyboardInset: mediaQuery.viewInsets.bottom,
        );
    final isBusy = context.select<SettingsViewModel, bool>(
      (vm) => vm.isImporting || vm.isExporting,
    );
    final hasConnections = context.select<ConnectionViewModel, bool>(
      (vm) => vm.connections.isNotEmpty,
    );
    final isLoadingConnections = context.select<ConnectionViewModel, bool>(
      (vm) => vm.isLoading,
    );

    final content = NotificationListener<OpenSettingsNotification>(
      onNotification: (notification) {
        _openSettings(context);
        return true;
      },
      child:
          NotificationListener<
            feature_playbook.PlaybookAiNavigationNotification
          >(
            onNotification: (notification) {
              _switchPage(_aiPage);
              return true;
            },
            child: IndexedStack(
              index: _selectedIndex,
              children: [
                for (var index = _firstPage; index <= _lastPage; index++)
                  _buildPage(
                    index,
                    strings: strings,
                    hasConnections: hasConnections,
                    isLoadingConnections: isLoadingConnections,
                  ),
              ],
            ),
          ),
    );

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: AppPageSurface(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          key: _scaffoldKey,
          extendBody: useMobileBottomNavigation,
          drawer: _buildSettingsDrawer(context, strings),
          drawerEnableOpenDragGesture: _selectedIndex == _serverPage,
          body: SafeArea(
            bottom: false,
            child: Stack(
              children: [
                _buildAdaptiveShell(
                  context,
                  content,
                  strings,
                  useRailNavigation: useRailNavigation,
                  isDesktopPlatform: isDesktop,
                  compactKeyboardLayout: compactKeyboardLayout,
                ),
                if (isBusy)
                  ColoredBox(
                    color: Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: 0.72),
                    child: _buildLoadingState(),
                  ),
              ],
            ),
          ),
          floatingActionButton:
              _selectedIndex == _serverPage &&
                  useMobileBottomNavigation &&
                  hasConnections
              ? FloatingActionButton(
                  onPressed: () => Navigator.pushNamed(
                    context,
                    '/add',
                    arguments: context.read<ConnectionViewModel>(),
                  ),
                  tooltip: strings.addConnection,
                  child: const Icon(Icons.add),
                )
              : null,
          bottomNavigationBar:
              !useMobileBottomNavigation ||
                  (_selectedIndex == _aiPage && _aiHistoryVisible)
              ? null
              : _buildBottomNavigation(context, strings),
        ),
      ),
    );
  }

  Widget _buildAdaptiveShell(
    BuildContext context,
    Widget content,
    AppStrings strings, {
    required bool useRailNavigation,
    required bool isDesktopPlatform,
    required bool compactKeyboardLayout,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = size.width;
    final extended = isDesktopPlatform && width >= AppBreakpoints.wideDesktop;
    final compactHeight = usesCompactRailForHeight(size.height);
    final isNarrowDesktop = isDesktopPlatform && width < AppBreakpoints.desktop;

    final settingsButton = IconButton(
      tooltip: strings.settings,
      icon: const Icon(Icons.settings_outlined, size: 20),
      style: IconButton.styleFrom(
        minimumSize: Size.square(isDesktopPlatform ? 40 : 48),
        foregroundColor: colorScheme.onSurfaceVariant,
        hoverColor: colorScheme.surfaceContainerHighest,
      ),
      onPressed: () => _openSettings(context),
    );

    return Row(
      children: [
        if (!useRailNavigation)
          const SizedBox.shrink()
        else if (compactKeyboardLayout)
          const SizedBox(width: 60)
        else
          Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                right: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.8),
                  width: 1,
                ),
              ),
            ),
            child: NavigationRail(
              backgroundColor: Colors.transparent,
              extended: extended,
              minWidth: isDesktopPlatform ? 60 : 72,
              minExtendedWidth: 200,
              labelType: extended
                  ? null
                  : (compactHeight || isNarrowDesktop)
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
              selectedIndex: _selectedIndex,
              onDestinationSelected: _switchNavigationPage,
              leading: (compactHeight || isNarrowDesktop)
                  ? const SizedBox(height: 4)
                  : _buildRailBrand(context, extended),
              trailing: (compactHeight || isNarrowDesktop)
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: settingsButton,
                    )
                  : Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: settingsButton,
                        ),
                      ),
                    ),
              destinations: [
                NavigationRailDestination(
                  icon: const Icon(Icons.dns_outlined, size: 20),
                  selectedIcon: const Icon(Icons.dns_rounded, size: 20),
                  label: Text(strings.servers),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.folder_open_outlined, size: 20),
                  selectedIcon: const Icon(Icons.folder_open_rounded, size: 20),
                  label: Text(strings.sftp),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.psychology_outlined, size: 20),
                  selectedIcon: const Icon(Icons.psychology_rounded, size: 20),
                  label: _buildAiLabel(context, _selectedIndex == _aiPage),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.monitor_heart_outlined, size: 20),
                  selectedIcon: const Icon(
                    Icons.monitor_heart_rounded,
                    size: 20,
                  ),
                  label: Text(strings.admin),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.radar_outlined, size: 20),
                  selectedIcon: const Icon(Icons.radar_rounded, size: 20),
                  label: Text(strings.lanShare),
                ),
              ],
            ),
          ),
        Expanded(
          child: KeyedSubtree(
            key: const ValueKey<String>('home-navigation-content'),
            child: content,
          ),
        ),
      ],
    );
  }

  Widget _buildRailBrand(BuildContext context, bool extended) {
    final colors = Theme.of(context).colorScheme;
    final mark = Icon(Icons.terminal_rounded, color: colors.primary, size: 22);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      child: extended
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                mark,
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'SSH Mobile',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
                ),
              ],
            )
          : mark,
    );
  }

  Widget _buildBottomNavigation(BuildContext context, AppStrings strings) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mobileMetrics = mobileUiMetricsOf(context);

    return Material(
      color: colorScheme.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.8),
              width: 1,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: mobileMetrics.navigationHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  _buildNavItem(
                    context: context,
                    mobileMetrics: mobileMetrics,
                    icon: const Icon(Icons.dns_outlined, size: 20),
                    selectedIcon: const Icon(Icons.dns_rounded, size: 20),
                    label: strings.servers,
                    index: _serverPage,
                  ),
                  _buildNavItem(
                    context: context,
                    mobileMetrics: mobileMetrics,
                    icon: const Icon(Icons.folder_open_outlined, size: 20),
                    selectedIcon: const Icon(
                      Icons.folder_open_rounded,
                      size: 20,
                    ),
                    label: strings.sftp,
                    index: _sftpPage,
                  ),
                  _buildNavItem(
                    context: context,
                    mobileMetrics: mobileMetrics,
                    icon: const Icon(Icons.psychology_outlined, size: 20),
                    selectedIcon: const Icon(
                      Icons.psychology_rounded,
                      size: 20,
                    ),
                    label: 'AI',
                    index: _aiPage,
                  ),
                  _buildNavItem(
                    context: context,
                    mobileMetrics: mobileMetrics,
                    icon: const Icon(Icons.monitor_heart_outlined, size: 20),
                    selectedIcon: const Icon(
                      Icons.monitor_heart_rounded,
                      size: 20,
                    ),
                    label: strings.admin,
                    index: _adminPage,
                  ),
                  _buildNavItem(
                    context: context,
                    mobileMetrics: mobileMetrics,
                    icon: const Icon(Icons.radar_outlined, size: 20),
                    selectedIcon: const Icon(Icons.radar_rounded, size: 20),
                    label: strings.lanShare,
                    index: _logPage,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required BuildContext context,
    required MobileUiMetrics mobileMetrics,
    required Widget icon,
    required Widget selectedIcon,
    required String label,
    required int index,
  }) {
    final isSelected = _selectedIndex == index;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Expanded(
      child: HomeNavigationSemantics(
        semanticsKey: ValueKey<String>('home-nav-$index'),
        label: label,
        selected: isSelected,
        onTap: () => _switchNavigationPage(index),
        child: TactileFeedback(
          onTap: () => _switchNavigationPage(index),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconTheme(
                data: IconThemeData(
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  size: mobileMetrics.navigationIconSize,
                ),
                child: isSelected ? selectedIcon : icon,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  fontSize: mobileMetrics.navigationLabelSize,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAiLabel(BuildContext context, bool isSelected) {
    return const Text('AI');
  }

  void _switchNavigationPage(int index) {
    _switchPage(index);
  }

  void _switchPage(int index) {
    if (_selectedIndex == index) return;
    setState(() => _selectedIndex = index);
    _onPageActive(index);
  }

  void _onPageActive(int index) {
    // 各 Feature 自主管理连线与活跃状态，避免在切页时跨模块读取其他 ViewModels
  }

  String settingsLabelAi(BuildContext context) {
    return 'AI';
  }

  void _openSettings(BuildContext context) {
    _scaffoldKey.currentState?.openDrawer();
  }

  Widget _buildSettingsDrawer(BuildContext context, AppStrings strings) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final desktop =
        isDesktopTargetPlatform() ||
        WindowSizeClass.of(context).isExpandedOrLarger;
    final width = settingsDrawerWidthFor(
      viewportWidth: viewportWidth,
      desktop: desktop,
    );
    return SizedBox(
      width: width,
      child: Drawer(
        child: _SettingsPage(
          onExport: () => _exportAppData(context, strings),
          onImport: () => _importAppData(context, strings),
        ),
      ),
    );
  }

  Widget _buildPage(
    int index, {
    required AppStrings strings,
    required bool hasConnections,
    required bool isLoadingConnections,
  }) {
    final active = _selectedIndex == index;
    return _RetainedNavPage(
      key: ValueKey<String>('home-nav-slot-$index'),
      active: active,
      builder: (context) => _pageShell(
        _buildFeaturePage(
          context,
          index,
          strings: strings,
          hasConnections: hasConnections,
          isLoadingConnections: isLoadingConnections,
        ),
      ),
    );
  }

  Widget _buildFeaturePage(
    BuildContext context,
    int index, {
    required AppStrings strings,
    required bool hasConnections,
    required bool isLoadingConnections,
  }) {
    if (!hasConnections && (index == _sftpPage || index == _adminPage)) {
      return isLoadingConnections
          ? _buildConnectionCatalogLoadingState()
          : _buildNoConnectionsState(context, index, strings);
    }

    switch (index) {
      case _aiPage:
        return feature_ai.LlmChatScreen(
          key: const PageStorageKey<String>('ai-chat-page'),
          active: _selectedIndex == index,
          viewModelFactory: (context) => feature_ai.AiChatViewModel(
            storageService: context.read<feature_ai.AiStoragePort>(),
            sshService: context.read<feature_ai.AiSshPort>(),
            sftpService: context.read<feature_ai.AiSftpPort>(),
            performanceMonitorService: context
                .read<feature_ai.AiMonitoringPort>(),
            playbookService: context
                .read<feature_playbook.PlaybookAutomationPort>(),
            ragService: context.read<app_core.RagCapability>(),
            appSettings: context.read<feature_ai.AiSettingsPort>(),
            runtimeFactory: context.read<feature_ai.AiChatRuntimeFactory>(),
            clientHealthAdvisor: context.read<feature_ai.AiHealthPort>(),
          ),
          webViewScreenBuilder: (context, chatId) =>
              ClientWebViewScreen(chatId: chatId),
          onHistoryVisibilityChanged: (visible) {
            if (_aiHistoryVisible == visible) return;
            setState(() => _aiHistoryVisible = visible);
          },
        );
      case _serverPage:
        return const ServerListPane();
      case _sftpPage:
        return const AppSftpModuleScope(child: feature_sftp.SftpScreen());
      case _adminPage:
        return const AppSystemAdminModuleScope(
          child: feature_system_admin.SystemAdminScreen(),
        );
      case _logPage:
      default:
        return const feature_lan_share.LanShareFeatureScope(
          child: feature_lan_share.LanShareScreen(),
        );
    }
  }

  Widget _pageShell(Widget child) {
    return RepaintBoundary(child: AppPageSurface(child: child));
  }

  Widget _buildConnectionCatalogLoadingState() {
    return const Center(child: AppLoadingIndicator(size: 24, strokeWidth: 2));
  }

  Widget _buildNoConnectionsState(
    BuildContext context,
    int index,
    AppStrings strings,
  ) {
    final isSftp = index == _sftpPage;
    return AppEmptyState(
      icon: isSftp ? Icons.folder_open_rounded : Icons.monitor_heart_outlined,
      title: isSftp ? strings.sftpEmptyTitle : strings.systemOmAdmin,
      message: isSftp ? strings.sftpEmptyHint : strings.selectServerToManage,
      action: FilledButton.icon(
        onPressed: () => Navigator.pushNamed(context, '/add'),
        icon: const Icon(Icons.add_rounded),
        label: Text(strings.addConnection),
      ),
    );
  }

  Future<void> _exportAppData(BuildContext context, AppStrings strings) async {
    final messenger = ScaffoldMessenger.of(context);
    final settingsVm = context.read<SettingsViewModel>();
    try {
      final success = await settingsVm.exportAppData((fileName, bytes) async {
        return await FilePicker.saveFile(
          dialogTitle: strings.exportAppData,
          fileName: fileName,
          bytes: Uint8List.fromList(bytes),
        );
      });
      if (!context.mounted) return;
      if (success) {
        messenger.showSnackBar(SnackBar(content: Text(strings.exportComplete)));
      }
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(strings.exportFailed(e))));
    }
  }

  Future<void> _importAppData(BuildContext context, AppStrings strings) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await AppConfirmDialog.show(
      context,
      title: strings.importAppData,
      content: strings.importAppDataWarning,
      cancelLabel: strings.cancel,
      confirmLabel: strings.importAction,
      isDestructive: false,
    );
    if (!confirmed || !context.mounted) return;
    final settingsVm = context.read<SettingsViewModel>();
    try {
      final success = await settingsVm.importAppData(() async {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: const ['json'],
        );
        return file?.readAsBytes();
      });
      if (!context.mounted) return;
      if (success) {
        messenger.showSnackBar(SnackBar(content: Text(strings.importComplete)));
        _switchPage(_serverPage);
      }
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(strings.importFailed(e))));
    }
  }

  Widget _buildLoadingState() {
    return const AppLoadingIndicator(size: 24, strokeWidth: 2);
  }
}

class _RetainedNavPage extends StatefulWidget {
  final bool active;
  final WidgetBuilder builder;

  const _RetainedNavPage({
    super.key,
    required this.active,
    required this.builder,
  });

  @override
  State<_RetainedNavPage> createState() => _RetainedNavPageState();
}

class _RetainedNavPageState extends State<_RetainedNavPage> {
  late bool _hasBeenActivated;

  @override
  void initState() {
    super.initState();
    _hasBeenActivated = widget.active;
  }

  @override
  void didUpdateWidget(covariant _RetainedNavPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active) _hasBeenActivated = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasBeenActivated) return const SizedBox.expand();
    return TickerMode(enabled: widget.active, child: widget.builder(context));
  }
}
