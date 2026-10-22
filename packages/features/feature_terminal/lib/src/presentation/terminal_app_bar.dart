import 'package:flutter/material.dart';

import 'package:app_ui/app_ui.dart';

import '../domain/terminal_models.dart';
import '../domain/terminal_strings.dart';

class TerminalScreenAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  final TerminalStrings strings;
  final String? displayName;
  final String? serverName;
  final String? serverEndpoint;
  final TerminalLinkState connectionState;
  final bool isDarkMode;
  final bool reconnectInProgress;
  final VoidCallback onReconnect;
  final VoidCallback onToggleTheme;
  final VoidCallback? onOpenSettings;
  final VoidCallback onSwitchWindow;
  final VoidCallback onCloseWindow;
  final VoidCallback onOpenSiblingSession;
  final VoidCallback onSmallerFont;
  final VoidCallback onLargerFont;

  const TerminalScreenAppBar({
    super.key,
    required this.strings,
    required this.displayName,
    required this.serverName,
    required this.serverEndpoint,
    required this.connectionState,
    required this.isDarkMode,
    required this.reconnectInProgress,
    required this.onReconnect,
    required this.onToggleTheme,
    this.onOpenSettings,
    required this.onSwitchWindow,
    required this.onCloseWindow,
    required this.onOpenSiblingSession,
    required this.onSmallerFont,
    required this.onLargerFont,
  });

  bool get _isConnected => connectionState == TerminalLinkState.connected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final status = _statusPresentation(context, colorScheme);
    final closeColor = colorScheme.error;

    return AppBar(
      key: const ValueKey('terminal-app-bar'),
      toolbarHeight: preferredSize.height,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 4,
      title: _TerminalAppBarTitle(
        title: displayName ?? serverName ?? strings.defaultTerminal,
        endpoint: serverEndpoint ?? serverName,
        status: status,
      ),
      actions: [
        SizedBox.square(
          dimension: 48,
          child: IconButton(
            key: const ValueKey('terminal-switch-window'),
            icon: const Icon(Icons.space_dashboard_outlined),
            tooltip: strings.switchWindow,
            onPressed: onSwitchWindow,
          ),
        ),
        PopupMenuButton<String>(
          key: const ValueKey('terminal-more-actions'),
          tooltip: strings.moreActions,
          onSelected: (value) {
            switch (value) {
              case 'new_window':
                onOpenSiblingSession();
                break;
              case 'smaller_font':
                onSmallerFont();
                break;
              case 'larger_font':
                onLargerFont();
                break;
              case 'toggle_theme':
                onToggleTheme();
                break;
              case 'terminal_settings':
                onOpenSettings?.call();
                break;
              case 'reconnect':
                onReconnect();
                break;
              case 'close_window':
                onCloseWindow();
                break;
            }
          },
          itemBuilder: (context) {
            final fontStyle = TextStyle(
              color: colorScheme.onSurface,
              fontSize: 15,
            );
            return [
              _menuItem(
                value: 'new_window',
                icon: Icons.add_to_photos_outlined,
                label: strings.newWindow,
                style: fontStyle,
              ),
              _menuItem(
                value: 'toggle_theme',
                icon: isDarkMode
                    ? Icons.light_mode_rounded
                    : Icons.dark_mode_rounded,
                label: isDarkMode
                    ? strings.switchToLightMode
                    : strings.switchToDarkMode,
                style: fontStyle,
              ),
              if (onOpenSettings != null)
                _menuItem(
                  value: 'terminal_settings',
                  icon: Icons.tune_rounded,
                  label: strings.terminalAppearance,
                  style: fontStyle,
                ),
              _menuItem(
                value: 'smaller_font',
                icon: Icons.text_decrease_rounded,
                label: strings.smallerFont,
                style: fontStyle,
              ),
              _menuItem(
                value: 'larger_font',
                icon: Icons.text_increase_rounded,
                label: strings.largerFont,
                style: fontStyle,
              ),
              if (!_isConnected)
                _menuItem(
                  value: 'reconnect',
                  icon: Icons.refresh_rounded,
                  label: reconnectInProgress
                      ? strings.reconnecting
                      : strings.reconnect,
                  style: fontStyle,
                  enabled: !reconnectInProgress,
                ),
              const PopupMenuDivider(),
              _menuItem(
                value: 'close_window',
                icon: _isConnected
                    ? Icons.power_settings_new_rounded
                    : Icons.close_rounded,
                label: _isConnected
                    ? strings.disconnect
                    : strings.closeDisconnected,
                style: fontStyle.copyWith(color: closeColor),
                iconColor: closeColor,
              ),
            ];
          },
          child: const SizedBox.square(
            dimension: 48,
            child: Icon(Icons.more_vert_rounded),
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  PopupMenuItem<String> _menuItem({
    required String value,
    required IconData icon,
    required String label,
    required TextStyle style,
    bool enabled = true,
    Color? iconColor,
  }) {
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 12),
          Flexible(child: Text(label, style: style)),
        ],
      ),
    );
  }

  _TerminalStatusPresentation _statusPresentation(
    BuildContext context,
    ColorScheme colors,
  ) {
    final statusColors = AppStatusColors.of(context);
    if (reconnectInProgress) {
      return _TerminalStatusPresentation(
        label: strings.reconnecting,
        icon: Icons.sync_rounded,
        color: statusColors.warning,
      );
    }
    return switch (connectionState) {
      TerminalLinkState.connected => _TerminalStatusPresentation(
        label: strings.connected,
        icon: Icons.check_rounded,
        color: statusColors.success,
      ),
      TerminalLinkState.connecting => _TerminalStatusPresentation(
        label: strings.connecting,
        icon: Icons.sync_rounded,
        color: statusColors.warning,
      ),
      TerminalLinkState.error => _TerminalStatusPresentation(
        label: strings.terminalConnectionErrorStatus,
        icon: Icons.close_rounded,
        color: statusColors.error,
      ),
      TerminalLinkState.disconnected => _TerminalStatusPresentation(
        label: strings.disconnected,
        icon: Icons.close_rounded,
        color: statusColors.neutral,
      ),
    };
  }

  @override
  Size get preferredSize => const Size.fromHeight(56);
}

class _TerminalAppBarTitle extends StatelessWidget {
  const _TerminalAppBarTitle({
    required this.title,
    required this.endpoint,
    required this.status,
  });

  final String title;
  final String? endpoint;
  final _TerminalStatusPresentation status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Row(
      children: [
        Semantics(
          key: const ValueKey('terminal-connection-status'),
          label: status.label,
          liveRegion: true,
          child: ExcludeSemantics(
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: status.color,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              if (endpoint != null && endpoint!.isNotEmpty)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    endpoint!,
                    maxLines: 1,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontFamily: 'monospace',
                      fontFamilyFallback: AppTheme.monospaceFallback,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TerminalStatusPresentation {
  const _TerminalStatusPresentation({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;
}
