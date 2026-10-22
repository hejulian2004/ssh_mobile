import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import 'package:animations/animations.dart';

import 'package:app_ui/app_ui.dart';

import '../application/terminal_session_viewmodel.dart';
import '../domain/terminal_models.dart';
import '../domain/terminal_ports.dart';
import '../domain/terminal_strings.dart';
import 'terminal_app_bar.dart';
import 'terminal_connection_overlay.dart';
import 'terminal_copy_screen.dart';
import 'terminal_shortcut_panel.dart';
import 'terminal_view_area.dart';
import 'terminal_settings_screen.dart';

part 'terminal_settings_models.dart';
part 'terminal_windows_input.dart';
part 'terminal_dialogs.dart';

class TerminalScreen extends StatefulWidget {
  final String connectionId;
  final String sessionId;

  const TerminalScreen({
    super.key,
    required this.connectionId,
    required this.sessionId,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with WidgetsBindingObserver {
  static const double _minTerminalFontSize =
      TerminalSessionViewModel.minFontSize;
  static const double _maxTerminalFontSize =
      TerminalSessionViewModel.maxFontSize;

  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  Offset _lastLongPressPosition = Offset.zero;
  Timer? _longPressTimer;
  Timer? _resizeTimer;
  int _activePointers = 0;
  bool _terminalMenuOpen = false;
  TerminalTheme? _cachedTerminalTheme;
  bool? _cachedTerminalThemeIsDark;
  Color? _cachedTerminalThemeBackground;
  String? _cachedTerminalThemeId;

  String? _serverName;
  String? _serverEndpoint;

  bool get _isWindowsTerminalTarget {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  }

  bool get _useWindowsBottomShortcutPanel {
    return _isWindowsTerminalTarget;
  }

  TerminalStrings _strings(BuildContext context) {
    return TerminalStrings(context.read<TerminalSettingsPort>().language);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadServerInfo();
  }

  void _loadServerInfo() {
    final config = context.read<TerminalConnectionPort>().getConnection(
      widget.connectionId,
    );
    if (config != null) {
      _serverName = config.name;
      _serverEndpoint = '${config.username}@${config.host}:${config.port}';
    }
  }

  void _replaceWithTerminalSession(
    TerminalWindowSnapshot session, {
    bool animated = false,
  }) {
    Navigator.of(context).pushAndRemoveUntil(
      animated ? _fadeTerminalRoute(session) : _instantTerminalRoute(session),
      (route) => route.isFirst,
    );
  }

  Route<void> _instantTerminalRoute(TerminalWindowSnapshot session) {
    return PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => TerminalScreen(
        connectionId: session.connectionId,
        sessionId: session.id,
      ),
    );
  }

  Route<void> _fadeTerminalRoute(TerminalWindowSnapshot session) {
    return PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 300),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) =>
          SharedAxisTransition(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            transitionType: SharedAxisTransitionType.scaled,
            child: TerminalScreen(
              connectionId: session.connectionId,
              sessionId: session.id,
            ),
          ),
    );
  }

  Color _getThemeBackground(String themeId, bool isDark) {
    if (!isDark) return const Color(0xFFFAFAFA);
    switch (themeId) {
      case 'monokai':
        return const Color(0xFF272822);
      case 'nord':
        return const Color(0xFF2E3440);
      case 'gruvbox':
        return const Color(0xFF282828);
      case 'solarized':
        return const Color(0xFF002B36);
      case 'default':
      default:
        final oledDark = context.read<TerminalSettingsPort>().oledDark;
        return oledDark ? const Color(0xFF000000) : const Color(0xFF09090B);
    }
  }

  TerminalTheme _terminalTheme(bool isDark, Color background, String themeId) {
    final cached = _cachedTerminalTheme;
    if (cached != null &&
        _cachedTerminalThemeIsDark == isDark &&
        _cachedTerminalThemeBackground == background &&
        _cachedTerminalThemeId == themeId) {
      return cached;
    }

    TerminalTheme theme;
    if (!isDark) {
      theme = TerminalTheme(
        background: background,
        foreground: const Color(0xFF24292F),
        cursor: const Color(0xFF0969DA),
        selection: const Color(0xFF0969DA).withValues(alpha: 0.22),
        searchHitBackground: const Color(0xFFFFD33D),
        searchHitBackgroundCurrent: const Color(0xFFFFAB00),
        searchHitForeground: const Color(0xFF24292F),
        black: const Color(0xFF24292F),
        red: const Color(0xFFCF222E),
        green: const Color(0xFF116329),
        yellow: const Color(0xFF4D2D00),
        blue: const Color(0xFF0969DA),
        magenta: const Color(0xFF8250DF),
        cyan: const Color(0xFF1B7C83),
        white: const Color(0xFF6E7781),
        brightBlack: const Color(0xFF57606A),
        brightRed: const Color(0xFFA40E26),
        brightGreen: const Color(0xFF1A7F37),
        brightYellow: const Color(0xFF9A6700),
        brightBlue: const Color(0xFF218BFF),
        brightMagenta: const Color(0xFFA475F9),
        brightCyan: const Color(0xFF3192AA),
        brightWhite: const Color(0xFF24292F),
      );
    } else {
      switch (themeId) {
        case 'monokai':
          theme = TerminalTheme(
            background: background,
            foreground: const Color(0xFFF8F8F2),
            cursor: const Color(0xFFF8F8F0),
            selection: const Color(0xFF49483E),
            searchHitBackground: const Color(0xFFFFD33D),
            searchHitBackgroundCurrent: const Color(0xFFFFAB00),
            searchHitForeground: const Color(0xFF272822),
            black: const Color(0xFF272822),
            red: const Color(0xFFF92672),
            green: const Color(0xFFA6E22E),
            yellow: const Color(0xFFF4BF75),
            blue: const Color(0xFF66D9EF),
            magenta: const Color(0xFFAE81FF),
            cyan: const Color(0xFFA1EFE4),
            white: const Color(0xFFF8F8F2),
            brightBlack: const Color(0xFF75715E),
            brightRed: const Color(0xFFF92672),
            brightGreen: const Color(0xFFA6E22E),
            brightYellow: const Color(0xFFF4BF75),
            brightBlue: const Color(0xFF66D9EF),
            brightMagenta: const Color(0xFFAE81FF),
            brightCyan: const Color(0xFFA1EFE4),
            brightWhite: const Color(0xFFF9F8F5),
          );
          break;
        case 'nord':
          theme = TerminalTheme(
            background: background,
            foreground: const Color(0xFFD8DEE9),
            cursor: const Color(0xFFD8DEE9),
            selection: const Color(0xFF434C5E),
            searchHitBackground: const Color(0xFFEBCB8B),
            searchHitBackgroundCurrent: const Color(0xFFD08770),
            searchHitForeground: const Color(0xFF2E3440),
            black: const Color(0xFF3B4252),
            red: const Color(0xFFBF616A),
            green: const Color(0xFFA3BE8C),
            yellow: const Color(0xFFEBCB8B),
            blue: const Color(0xFF81A1C1),
            magenta: const Color(0xFFB48EAD),
            cyan: const Color(0xFF88C0D0),
            white: const Color(0xFFE5E9F0),
            brightBlack: const Color(0xFF4C566A),
            brightRed: const Color(0xFFBF616A),
            brightGreen: const Color(0xFFA3BE8C),
            brightYellow: const Color(0xFFEBCB8B),
            brightBlue: const Color(0xFF81A1C1),
            brightMagenta: const Color(0xFFB48EAD),
            brightCyan: const Color(0xFF8FBCBB),
            brightWhite: const Color(0xFFECEFF4),
          );
          break;
        case 'gruvbox':
          theme = TerminalTheme(
            background: background,
            foreground: const Color(0xFFEBDBB2),
            cursor: const Color(0xFFEBDBB2),
            selection: const Color(0xFF504945),
            searchHitBackground: const Color(0xFFFABD2F),
            searchHitBackgroundCurrent: const Color(0xFFFE8019),
            searchHitForeground: const Color(0xFF282828),
            black: const Color(0xFF282828),
            red: const Color(0xFFCC241D),
            green: const Color(0xFF98971A),
            yellow: const Color(0xFFD79921),
            blue: const Color(0xFF458588),
            magenta: const Color(0xFFB16286),
            cyan: const Color(0xFF689D6A),
            white: const Color(0xFFA89984),
            brightBlack: const Color(0xFF928374),
            brightRed: const Color(0xFFFB4934),
            brightGreen: const Color(0xFFB8BB26),
            brightYellow: const Color(0xFFFABD2F),
            brightBlue: const Color(0xFF83A598),
            brightMagenta: const Color(0xFFD3869B),
            brightCyan: const Color(0xFF8EC07C),
            brightWhite: const Color(0xFFFBF1C7),
          );
          break;
        case 'solarized':
          theme = TerminalTheme(
            background: background,
            foreground: const Color(0xFF839496),
            cursor: const Color(0xFF93A1A1),
            selection: const Color(0xFF073642),
            searchHitBackground: const Color(0xFFB58900),
            searchHitBackgroundCurrent: const Color(0xFFCB4B16),
            searchHitForeground: const Color(0xFF002B36),
            black: const Color(0xFF073642),
            red: const Color(0xFFDC322F),
            green: const Color(0xFF859900),
            yellow: const Color(0xFFB58900),
            blue: const Color(0xFF268BD2),
            magenta: const Color(0xFFD33682),
            cyan: const Color(0xFF2AA198),
            white: const Color(0xFFEEE8D5),
            brightBlack: const Color(0xFF002B36),
            brightRed: const Color(0xFFCB4B16),
            brightGreen: const Color(0xFF586E75),
            brightYellow: const Color(0xFF657B83),
            brightBlue: const Color(0xFF839496),
            brightMagenta: const Color(0xFF6C71C4),
            brightCyan: const Color(0xFF93A1A1),
            brightWhite: const Color(0xFFFDF6E3),
          );
          break;
        case 'default':
        default:
          theme = TerminalTheme(
            background: background,
            foreground: const Color(0xFFCCCCCC),
            cursor: const Color(0xFF58A6FF),
            selection: const Color(0xFF58A6FF).withValues(alpha: 0.24),
            searchHitBackground: const Color(0xFF725C00),
            searchHitBackgroundCurrent: const Color(0xFFA88400),
            searchHitForeground: const Color(0xFFFFFFFF),
            black: const Color(0xFF1A1A2E),
            red: const Color(0xFFFF6B6B),
            green: const Color(0xFF00FF41),
            yellow: const Color(0xFFFFD93D),
            blue: const Color(0xFF58A6FF),
            magenta: const Color(0xFFB388FF),
            cyan: const Color(0xFF00D4FF),
            white: const Color(0xFFCCCCCC),
            brightBlack: const Color(0xFF4A4A5E),
            brightRed: const Color(0xFFFF8E8E),
            brightGreen: const Color(0xFF6BFF6B),
            brightYellow: const Color(0xFFFFF176),
            brightBlue: const Color(0xFF8BC4FF),
            brightMagenta: const Color(0xFFD1BFFF),
            brightCyan: const Color(0xFF80EBFF),
            brightWhite: const Color(0xFFFFFFFF),
          );
          break;
      }
    }
    _cachedTerminalTheme = theme;
    _cachedTerminalThemeIsDark = isDark;
    _cachedTerminalThemeBackground = background;
    _cachedTerminalThemeId = themeId;
    return theme;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App cycle resumed handled by session init/attaching, no additional action needed here
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<TerminalSessionViewModel>(
      create: (context) => TerminalSessionViewModel.fromContext(
        context,
        sessionId: widget.sessionId,
        connectionId: widget.connectionId,
      ),
      child: Consumer<TerminalSessionViewModel>(
        builder: (context, viewModel, child) {
          final ctrlActive = viewModel.ctrlActive;
          final altActive = viewModel.altActive;
          final terminalFontSize = viewModel.fontSize;

          final appSettings = context
              .select<TerminalSettingsPort, _TerminalSettingsSnapshot>(
                _TerminalSettingsSnapshot.from,
              );
          final strings = TerminalStrings(appSettings.language);
          final isConnected = viewModel.isConnected;
          final connectionState = viewModel.connectionState;
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final terminalBackground = _getThemeBackground(
            appSettings.terminalThemeId,
            isDark,
          );
          final toolbarColor = terminalBackground;
          final useWideDesktopSideShortcutPanel =
              !_useWindowsBottomShortcutPanel &&
              MediaQuery.sizeOf(context).width >= AppBreakpoints.wideDesktop;

          final terminalView = TerminalViewArea(
            terminalViewKey: _terminalViewKey,
            terminal: viewModel.terminal,
            controller: viewModel.terminalController,
            focusNode: viewModel.terminalFocusNode,
            theme: _terminalTheme(
              isDark,
              terminalBackground,
              appSettings.terminalThemeId,
            ),
            fontSize: terminalFontSize,
            minFontSize: _minTerminalFontSize,
            maxFontSize: _maxTerminalFontSize,
            onFontSizeChanged: (size) => viewModel.setFontSize(size),
            onScaleEnd: () => _syncTerminalSize(viewModel),
            onPointerDown: (event) =>
                _handleTerminalPointerDown(event, viewModel),
            onPointerMove: _handleTerminalPointerMove,
            onPointerUp: _handleTerminalPointerUp,
            onPointerCancel: _handleTerminalPointerCancel,
            useWindowsCommandInput: _isWindowsTerminalTarget,
            onSecondaryTapUp: (details) {
              _lastLongPressPosition = details.globalPosition;
              _requestWindowsAwareTerminalFocus(viewModel);
              unawaited(_showTerminalEditMenu(viewModel));
            },
          );

          final complexInputController = _isWindowsTerminalTarget
              ? viewModel.commandInputController
              : viewModel.complexInputController;

          final shortcutPanel = TerminalShortcutPanel(
            strings: strings,
            toolbarColor: toolbarColor,
            complexInputController: complexInputController,
            onSendData: viewModel.sendData,
            onSendComplexInput: (text) {
              viewModel.submitCommandText(text);
              _requestWindowsAwareTerminalFocus(viewModel);
            },
            onTerminalStroke: viewModel.sendTerminalKeyboardStroke,
            terminalFocusNode: _isWindowsTerminalTarget
                ? viewModel.commandInputFocusNode
                : viewModel.terminalFocusNode,
            ctrlActive: ctrlActive,
            altActive: altActive,
            onToggleCtrl: () {
              viewModel.toggleCtrl();
              if (viewModel.ctrlActive) {
                viewModel.setAltActive(false);
              }
              _requestWindowsAwareTerminalFocus(viewModel);
            },
            onToggleAlt: () {
              viewModel.toggleAlt();
              if (viewModel.altActive) {
                viewModel.setCtrlActive(false);
              }
              _requestWindowsAwareTerminalFocus(viewModel);
            },
          );

          return Scaffold(
            appBar: TerminalScreenAppBar(
              strings: strings,
              displayName: viewModel.displayName,
              serverName: _serverName,
              serverEndpoint: _serverEndpoint,
              connectionState: connectionState,
              isDarkMode: appSettings.isDarkMode,
              reconnectInProgress: viewModel.reconnectInProgress,
              onReconnect: viewModel.reconnect,
              onToggleTheme: context.read<TerminalSettingsPort>().toggleTheme,
              onOpenSettings: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const TerminalSettingsScreen(),
                  ),
                );
              },
              onSwitchWindow: () => _showSessionSwitcher(context),
              onCloseWindow: () => _confirmDisconnect(context),
              onOpenSiblingSession: () => _openSiblingSession(context),
              onSmallerFont: () {
                viewModel.setFontSize(terminalFontSize - 1);
                _syncTerminalSize(viewModel);
              },
              onLargerFont: () {
                viewModel.setFontSize(terminalFontSize + 1);
                _syncTerminalSize(viewModel);
              },
            ),
            body: Stack(
              children: [
                Container(
                  color: terminalBackground,
                  child: useWideDesktopSideShortcutPanel
                      ? Row(
                          children: [
                            Expanded(child: terminalView),
                            SizedBox(
                              width: 360,
                              child: Align(
                                alignment: Alignment.topCenter,
                                child: shortcutPanel,
                              ),
                            ),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(child: terminalView),
                            if (_isWindowsTerminalTarget)
                              _buildWindowsCommandInput(
                                context,
                                viewModel,
                                toolbarColor,
                                strings,
                              ),
                            shortcutPanel,
                          ],
                        ),
                ),
                if (viewModel.loadingBufferedOutput && isConnected)
                  Positioned.fill(
                    child: AppTerminalSkeleton(
                      backgroundColor: terminalBackground,
                    ),
                  ),
                if (viewModel.loadingBufferedOutput && isConnected)
                  TerminalBufferedOutputIndicator(strings: strings),
                if (!isConnected || viewModel.reconnectInProgress)
                  TerminalConnectionOverlay(
                    strings: strings,
                    connectionState: connectionState,
                    reconnectInProgress: viewModel.reconnectInProgress,
                    terminalBackground: terminalBackground,
                    endpoint: _serverEndpoint ?? _serverName,
                    errorMessage: viewModel.connectionError,
                    onReconnect: viewModel.reconnect,
                    onSwitchWindow: () => _showSessionSwitcher(context),
                    onCloseWindow: () => _confirmDisconnect(context),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _syncTerminalSize(TerminalSessionViewModel viewModel) {
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      final width = viewModel.terminal.viewWidth;
      final height = viewModel.terminal.viewHeight;
      viewModel.syncTerminalSize(width, height);
      _requestWindowsAwareTerminalFocus(viewModel);
    });
  }

  void _handleTerminalPointerDown(
    PointerDownEvent event,
    TerminalSessionViewModel viewModel,
  ) {
    _activePointers += 1;
    _lastLongPressPosition = event.position;
    _requestWindowsAwareTerminalFocus(viewModel);

    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 550), () {
      if (!mounted || _activePointers != 1 || _terminalMenuOpen) return;
      viewModel.selectWordAtPosition(_lastLongPressPosition, _terminalViewKey);
      unawaited(_showTerminalEditMenu(viewModel));
    });
  }

  void _handleTerminalPointerMove(PointerMoveEvent event) {
    if ((event.position - _lastLongPressPosition).distance > 8) {
      _longPressTimer?.cancel();
    }
  }

  void _handleTerminalPointerUp(PointerUpEvent event) {
    _activePointers = (_activePointers - 1).clamp(0, 10);
    _longPressTimer?.cancel();
  }

  void _handleTerminalPointerCancel(PointerCancelEvent event) {
    _activePointers = 0;
    _longPressTimer?.cancel();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _longPressTimer?.cancel();
    _resizeTimer?.cancel();
    super.dispose();
  }
}
