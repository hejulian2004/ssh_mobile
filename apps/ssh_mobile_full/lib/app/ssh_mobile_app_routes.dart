part of 'ssh_mobile_app.dart';

/// Owns route-scoped providers and MaterialApp route aggregation.
extension _SshMobileAppRoutes on _SshMobileAppState {
  /// Creates the Connection Feature route scope. ViewModel 不进入 App 根 Provider。
  Widget _createConnectionRouteScopeForState(
    Widget child, {
    feature_connection.ConnectionViewModel? viewModel,
  }) {
    return AppConnectionRouteScope(
      connectionRepository: _connectionRepositoryAdapter!,
      credentialRepository: _connectionCredentialAdapter!,
      hostKeyRepository: _connectionHostKeyAdapter!,
      runtimePort: _connectionRuntimeAdapter!,
      verificationPort: _connectionVerificationAdapter!,
      viewModel: viewModel,
      child: child,
    );
  }

  /// Creates the product Home Shell route scope and owns settings state.
  Widget _createHomeRouteScopeForState(Widget child) {
    final runtime = _runtime;
    return _createConnectionRouteScopeForState(
      ChangeNotifierProvider<SettingsViewModel>(
        create: (_) => SettingsViewModel(
          appSettings: runtime.appSettings,
          aiStorage: runtime.aiStorageAdapter,
        ),
        child: child,
      ),
    );
  }

  /// Builds the Material/Shad shell from the AppRuntime providers.
  Widget _buildAppWithRoutes(BuildContext context) {
    final visualSettings = context
        .select<AppSettings, AppVisualSettingsSnapshot>(
          (settings) => settings.visualSettings,
        );
    final darkMode = visualSettings.themeMode == ThemeMode.dark;
    final palette = visualSettings.colorPalette;

    return ScrollConfiguration(
      behavior: const ShadScrollBehavior(),
      child: ShadTheme(
        data: darkMode
            ? _SshMobileAppThemes.shadDarkThemes[palette]!
            : _SshMobileAppThemes.shadLightThemes[palette]!,
        child: ShadMouseAreaSurface(
          child: ShadMouseCursorProvider(
            child: Builder(
              builder: (context) {
                return MaterialApp(
                  navigatorKey: _navigatorKey,
                  title: 'SSH Mobile',
                  debugShowCheckedModeBanner: false,
                  theme: _SshMobileAppThemes.lightThemes[palette],
                  darkTheme: visualSettings.oledDark
                      ? _SshMobileAppThemes.oledDarkThemes[palette]
                      : _SshMobileAppThemes.darkThemes[palette],
                  themeMode: visualSettings.themeMode,
                  themeAnimationDuration: Duration.zero,
                  builder: (context, child) {
                    final mediaQuery = MediaQuery.of(context);
                    final adaptedMediaQuery = adaptMobileMediaQuery(mediaQuery);
                    final visualDensity = mobileVisualDensityFor(mediaQuery);
                    final effectiveChild = child ?? const SizedBox.shrink();
                    final screenShareAdapter = _lanScreenShareAdapter!;
                    final shadChild = AppScreenShareIncomingRequestHost(
                      runtime: _runtime,
                      navigatorKey: _navigatorKey,
                      screenSharePort: screenShareAdapter,
                      arbitration: screenShareAdapter.arbitration,
                      child: feature_developer.DeveloperPanelFloatingHost(
                        child: feature_lan_share.NetworkIncomingTransferHost(
                          child: feature_lan_share.LanPairingNavigationHost(
                            navigatorKey: _navigatorKey,
                            child: ShadAppBuilder(child: effectiveChild),
                          ),
                        ),
                      ),
                    );

                    final currentTheme = Theme.of(context);
                    if (identical(adaptedMediaQuery, mediaQuery) &&
                        visualDensity == currentTheme.visualDensity) {
                      return shadChild;
                    }

                    return MediaQuery(
                      data: adaptedMediaQuery,
                      child: currentTheme.visualDensity == visualDensity
                          ? shadChild
                          : Theme(
                              data: currentTheme.copyWith(
                                visualDensity: visualDensity,
                              ),
                              child: shadChild,
                            ),
                    );
                  },
                  initialRoute: AppShellRouteNames.root,
                  onGenerateRoute: (settings) {
                    final routeName = settings.name;
                    if (routeName != null &&
                        routeName != AppShellRouteNames.root &&
                        routeName != AppShellRouteNames.performance &&
                        routeName != AppShellRouteNames.screenShare &&
                        !AppRouteContributionCatalog.contains(routeName)) {
                      throw StateError(
                        'Feature route is missing a public contribution: '
                        '$routeName',
                      );
                    }
                    switch (settings.name) {
                      case AppShellRouteNames.root:
                        return MaterialPageRoute(
                          builder: (_) => _createHomeRouteScopeForState(
                            ChangeNotifierProvider(
                              create: (context) => StartupViewModel(
                                appSettings: context.read<AppSettings>(),
                              ),
                              child: const StartupScreen(),
                            ),
                          ),
                        );
                      case TerminalRouteNames.terminal:
                        final config =
                            settings.arguments as Map<String, dynamic>;
                        return MaterialPageRoute(
                          builder: (_) => AppTerminalModuleScope(
                            child: TerminalScreen(
                              connectionId: config['id'] as String,
                              sessionId: config['sessionId'] as String,
                            ),
                          ),
                        );
                      case TerminalRouteNames.history:
                        return MaterialPageRoute(
                          builder: (_) => const AppTerminalModuleScope(
                            child: TerminalHistoryScreen(),
                          ),
                        );
                      case TerminalRouteNames.windows:
                        final args = settings.arguments;
                        String? connectionId;

                        if (args is String) {
                          connectionId = args;
                        } else if (args is Map<String, dynamic>) {
                          final value = args['connectionId'];
                          if (value is String) {
                            connectionId = value;
                          }
                        }

                        return MaterialPageRoute(
                          builder: (_) => AppTerminalModuleScope(
                            child: TerminalWindowsScreen(
                              connectionId: connectionId,
                            ),
                          ),
                        );
                      case feature_sftp.SftpRouteNames.browser:
                        return MaterialPageRoute(
                          builder: (_) => _createConnectionRouteScopeForState(
                            const AppSftpModuleScope(
                              child: feature_sftp.SftpScreen(),
                            ),
                          ),
                        );
                      case AppShellRouteNames.performance:
                        return MaterialPageRoute(
                          builder: (_) => _createHomeRouteScopeForState(
                            const HomeScreen(initialIndex: 3),
                          ),
                        );
                      case AppShellRouteNames.screenShare:
                        final arguments = settings.arguments;
                        if (arguments is! AppScreenShareRouteArguments) {
                          throw ArgumentError(
                            'Screen-share route requires typed arguments.',
                          );
                        }
                        return MaterialPageRoute(
                          builder: (_) => AppScreenShareRouteScope(
                            arguments: arguments,
                            resources: _runtime.realtimeMediaResources,
                          ),
                        );
                      case feature_ai.AiRouteNames.skills:
                        return MaterialPageRoute(
                          builder: (_) => ChangeNotifierProvider(
                            create: (context) => feature_ai.AiSkillsViewModel(
                              storageService: context
                                  .read<feature_ai.AiStoragePort>(),
                              appSettings: context
                                  .read<feature_ai.AiSettingsPort>(),
                            ),
                            child: const feature_ai.AiSkillsScreen(),
                          ),
                        );
                      case feature_ai.AiRouteNames.skillEdit:
                        final args = settings.arguments as Map<String, dynamic>;
                        final viewModel =
                            args['viewModel'] as feature_ai.AiSkillsViewModel;
                        return MaterialPageRoute(
                          builder: (_) => ChangeNotifierProvider.value(
                            value: viewModel,
                            child: const feature_ai.AiSkillEditScreen(),
                          ),
                        );
                      case feature_playbook.PlaybookRouteNames.list:
                        return MaterialPageRoute(
                          builder: (context) =>
                              feature_playbook.PlaybookFeatureScope(
                                module: _runtime.playbookModule,
                                settings: context
                                    .read<
                                      feature_playbook.PlaybookSettingsPort
                                    >(),
                                connectionCatalog: context
                                    .read<
                                      feature_playbook.PlaybookConnectionCatalogPort
                                    >(),
                                child: const feature_playbook.PlaybookScreen(),
                              ),
                        );
                      case feature_connection.ConnectionRouteNames.add:
                        final viewModel =
                            settings.arguments
                                is feature_connection.ConnectionViewModel
                            ? settings.arguments
                                  as feature_connection.ConnectionViewModel
                            : null;
                        return MaterialPageRoute(
                          builder: (_) => _createConnectionRouteScopeForState(
                            const feature_connection.AddEditScreen(),
                            viewModel: viewModel,
                          ),
                        );
                      case feature_connection.ConnectionRouteNames.edit:
                        final args = settings.arguments;
                        final String id;
                        final feature_connection.ConnectionViewModel? viewModel;
                        if (args is String) {
                          id = args;
                          viewModel = null;
                        } else if (args is AppConnectionEditRouteArguments) {
                          id = args.connectionId;
                          viewModel = args.viewModel;
                        } else {
                          throw ArgumentError.value(
                            args,
                            'settings.arguments',
                            'Edit route requires a connection ID.',
                          );
                        }
                        return MaterialPageRoute(
                          builder: (_) => _createConnectionRouteScopeForState(
                            feature_connection.AddEditScreen(editId: id),
                            viewModel: viewModel,
                          ),
                        );
                      case feature_rag.RagRouteNames.knowledge:
                        return MaterialPageRoute(
                          builder: (_) => feature_rag.RagFeatureScope(
                            module: _runtime.ragModule,
                            child: const feature_rag.RagKnowledgeScreen(),
                          ),
                        );
                      case feature_mcp.McpRouteNames.console:
                        return MaterialPageRoute(
                          builder: (_) => feature_mcp.McpFeatureScope(
                            module: _runtime.mcpModule,
                            child: const feature_mcp.McpConsoleScreen(),
                          ),
                        );
                      case feature_mcp.McpRouteNames.settings:
                        return MaterialPageRoute(
                          builder: (context) => ChangeNotifierProvider(
                            create: (_) => feature_mcp.McpSettingsViewModel(
                              settingsPort: context
                                  .read<feature_mcp.McpSettingsPort>(),
                              controller: context
                                  .read<feature_mcp.McpServerController>(),
                            ),
                            child: const feature_mcp.McpSettingsScreen(),
                          ),
                        );
                      default:
                        return MaterialPageRoute(
                          builder: (_) =>
                              _createHomeRouteScopeForState(const HomeScreen()),
                        );
                    }
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
