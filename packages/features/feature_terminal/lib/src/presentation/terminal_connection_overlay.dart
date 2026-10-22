import 'package:flutter/material.dart';

import 'package:app_ui/app_ui.dart';

import '../domain/terminal_models.dart';
import '../domain/terminal_strings.dart';

class TerminalConnectionOverlay extends StatelessWidget {
  const TerminalConnectionOverlay({
    super.key,
    required this.strings,
    required this.connectionState,
    required this.reconnectInProgress,
    required this.terminalBackground,
    required this.onReconnect,
    required this.onSwitchWindow,
    required this.onCloseWindow,
    this.endpoint,
    this.errorMessage,
  });

  final TerminalStrings strings;
  final TerminalLinkState connectionState;
  final bool reconnectInProgress;
  final Color terminalBackground;
  final String? endpoint;
  final String? errorMessage;
  final VoidCallback onReconnect;
  final VoidCallback onSwitchWindow;
  final VoidCallback onCloseWindow;

  @override
  Widget build(BuildContext context) {
    if (connectionState == TerminalLinkState.connected &&
        !reconnectInProgress) {
      return const SizedBox.shrink();
    }

    final presentation = _presentation(context);
    final colors = Theme.of(context).colorScheme;
    final isWaiting =
        reconnectInProgress || connectionState == TerminalLinkState.connecting;

    return Semantics(
      key: const ValueKey('terminal-connection-overlay'),
      container: true,
      liveRegion: true,
      label: presentation.title,
      child: ColoredBox(
        color: terminalBackground.withValues(alpha: 0.76),
        child: SafeArea(
          minimum: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxHeight < 390;
              return Center(
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 500),
                    child: Card(
                      key: ValueKey(
                        'terminal-connection-card-${connectionState.name}',
                      ),
                      elevation: 0,
                      color: colors.surface.withValues(alpha: 0.97),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusLarge,
                        ),
                        side: BorderSide(color: colors.outline),
                      ),
                      child: Stack(
                        children: [
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              compact ? 20 : 28,
                              compact ? 20 : 28,
                              compact ? 20 : 28,
                              compact ? 18 : 26,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isWaiting)
                                  AppLoadingIndicator(
                                    size: compact ? 48 : 58,
                                    strokeWidth: 3,
                                    color: presentation.color,
                                    backgroundColor: presentation.color
                                        .withValues(alpha: 0.14),
                                  )
                                else
                                  AppIconBadge(
                                    icon: presentation.icon,
                                    size: compact ? 52 : 64,
                                    iconSize: compact ? 26 : 31,
                                    color: presentation.color,
                                  ),
                                SizedBox(height: compact ? 14 : 20),
                                Text(
                                  presentation.title,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  presentation.message,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: colors.onSurfaceVariant,
                                        height: 1.45,
                                      ),
                                ),
                                if (endpoint != null && endpoint!.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 7,
                                      ),
                                      decoration: BoxDecoration(
                                        color: colors.surfaceContainer,
                                        borderRadius: BorderRadius.circular(
                                          AppTheme.radiusPill,
                                        ),
                                        border: Border.all(
                                          color: colors.outline,
                                        ),
                                      ),
                                      child: Text(
                                        endpoint!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelMedium
                                            ?.copyWith(
                                              color: colors.onSurfaceVariant,
                                              fontFamily: 'monospace',
                                              fontFamilyFallback:
                                                  AppTheme.monospaceFallback,
                                            ),
                                      ),
                                    ),
                                  ),
                                if (errorMessage != null &&
                                    errorMessage!.trim().isNotEmpty &&
                                    !isWaiting)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: colors.errorContainer.withValues(
                                          alpha: 0.6,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          AppTheme.radiusSmall,
                                        ),
                                      ),
                                      child: Text(
                                        errorMessage!.trim(),
                                        maxLines: compact ? 2 : 4,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: colors.onErrorContainer,
                                              fontFamily: 'monospace',
                                              fontFamilyFallback:
                                                  AppTheme.monospaceFallback,
                                            ),
                                      ),
                                    ),
                                  ),
                                SizedBox(height: compact ? 16 : 22),
                                Wrap(
                                  alignment: WrapAlignment.center,
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    if (!isWaiting)
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          minHeight: 48,
                                        ),
                                        child: FilledButton.icon(
                                          key: const ValueKey(
                                            'terminal-reconnect',
                                          ),
                                          onPressed: onReconnect,
                                          icon: const Icon(
                                            Icons.refresh_rounded,
                                          ),
                                          label: Text(strings.reconnect),
                                        ),
                                      ),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minHeight: 48,
                                      ),
                                      child: OutlinedButton.icon(
                                        key: const ValueKey(
                                          'terminal-manage-windows',
                                        ),
                                        onPressed: onSwitchWindow,
                                        icon: const Icon(
                                          Icons.space_dashboard_outlined,
                                        ),
                                        label: Text(strings.manageWindows),
                                      ),
                                    ),
                                  ],
                                ),
                                TextButton.icon(
                                  key: const ValueKey('terminal-close-window'),
                                  onPressed: onCloseWindow,
                                  style: TextButton.styleFrom(
                                    foregroundColor: colors.error,
                                    minimumSize: const Size(48, 48),
                                  ),
                                  icon: const Icon(Icons.close_rounded),
                                  label: Text(strings.closeWindow),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  _TerminalConnectionPresentation _presentation(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final extended = Theme.of(context).extension<ExtendedColors>();
    if (reconnectInProgress) {
      return _TerminalConnectionPresentation(
        title: strings.reconnecting,
        message: strings.connectingSessionHint,
        icon: Icons.sync_rounded,
        color: extended?.warning ?? AppTheme.terminalAmber,
      );
    }
    return switch (connectionState) {
      TerminalLinkState.connecting => _TerminalConnectionPresentation(
        title: strings.connectingSession,
        message: strings.connectingSessionHint,
        icon: Icons.sync_rounded,
        color: extended?.warning ?? AppTheme.terminalAmber,
      ),
      TerminalLinkState.error => _TerminalConnectionPresentation(
        title: strings.terminalConnectionError,
        message: strings.terminalConnectionErrorHint,
        icon: Icons.error_outline_rounded,
        color: colors.error,
      ),
      TerminalLinkState.disconnected => _TerminalConnectionPresentation(
        title: strings.connectionInterrupted,
        message: strings.connectionInterruptedHint,
        icon: Icons.link_off_rounded,
        color: colors.error,
      ),
      TerminalLinkState.connected => _TerminalConnectionPresentation(
        title: strings.connected,
        message: strings.connectingSessionHint,
        icon: Icons.check_circle_outline_rounded,
        color: extended?.success ?? colors.secondary,
      ),
    };
  }
}

class TerminalBufferedOutputIndicator extends StatelessWidget {
  const TerminalBufferedOutputIndicator({super.key, required this.strings});

  final TerminalStrings strings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      minimum: const EdgeInsets.all(12),
      child: Align(
        alignment: Alignment.topRight,
        child: Semantics(
          liveRegion: true,
          label: strings.restoringTerminalOutput,
          child: Card(
            key: const ValueKey('terminal-output-restoring'),
            elevation: 0,
            color: colors.surface.withValues(alpha: 0.94),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppLoadingIndicator(size: 18, strokeWidth: 2),
                  const SizedBox(width: 10),
                  Text(
                    strings.restoringTerminalOutput,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TerminalConnectionPresentation {
  const _TerminalConnectionPresentation({
    required this.title,
    required this.message,
    required this.icon,
    required this.color,
  });

  final String title;
  final String message;
  final IconData icon;
  final Color color;
}
