part of '../terminal_windows_screen.dart';

extension _TerminalWindowsContent on _TerminalWindowsPageState {
  Widget _buildWindowList(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    List<TerminalWindowSnapshot> sessions,
    TerminalStrings strings,
  ) {
    if (page.embedded) {
      final visibleSessions = sessions
          .take(_TerminalWindowsPageState._embeddedPreviewLimit)
          .toList(growable: false);
      final hiddenCount = sessions.length - visibleSessions.length;

      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          children: [
            for (var index = 0; index < visibleSessions.length; index++) ...[
              if (index > 0) const SizedBox(height: 8),
              _buildWindowItem(
                context,
                viewModel,
                visibleSessions[index],
                strings,
              ),
            ],
            if (hiddenCount > 0) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.open_in_full_rounded, size: 16),
                  label: Text(strings.viewAllTerminalWindows(sessions.length)),
                  onPressed: () => Navigator.pushNamed(
                    context,
                    '/terminal-windows',
                    arguments: page.connectionId,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= AppBreakpoints.desktop;
        final accessibleText = MediaQuery.textScalerOf(context).scale(1) > 1.25;
        final columns = accessibleText
            ? 1
            : constraints.maxWidth >= AppBreakpoints.wideDesktop
            ? 3
            : desktop
            ? 2
            : 1;
        final horizontalPadding = desktop ? 24.0 : 12.0;
        final groups = _groupSessions(sessions);

        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: desktop ? 1480 : double.infinity,
            ),
            child: CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 6)),
                for (final group in groups) ...[
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      12,
                      horizontalPadding,
                      10,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: _buildServerGroupHeader(context, group, strings),
                    ),
                  ),
                  if (columns == 1)
                    SliverPadding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                      ),
                      sliver: SliverList.separated(
                        itemCount: group.sessions.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) => _buildWindowItem(
                          context,
                          viewModel,
                          group.sessions[index],
                          strings,
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                      ),
                      sliver: SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 14,
                          mainAxisExtent: 320,
                        ),
                        itemCount: group.sessions.length,
                        itemBuilder: (context, index) => _buildWindowItem(
                          context,
                          viewModel,
                          group.sessions[index],
                          strings,
                        ),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 18)),
              ],
            ),
          ),
        );
      },
    );
  }

  List<_TerminalServerGroup> _groupSessions(
    List<TerminalWindowSnapshot> sessions,
  ) {
    final groups = <String, _TerminalServerGroup>{};
    for (final session in sessions) {
      groups.putIfAbsent(
        session.connectionId,
        () => _TerminalServerGroup(
          connectionName: session.connectionName,
          sessions: [],
        ),
      );
      groups[session.connectionId]!.sessions.add(session);
    }
    return groups.values.toList(growable: false);
  }

  Widget _buildServerGroupHeader(
    BuildContext context,
    _TerminalServerGroup group,
    TerminalStrings strings,
  ) {
    final colors = Theme.of(context).colorScheme;
    final connected = group.sessions
        .where((session) => session.isConnected)
        .length;
    return Semantics(
      container: true,
      header: true,
      label: group.connectionName,
      child: Row(
        children: [
          const AppIconBadge(icon: Icons.dns_outlined, size: 36, iconSize: 18),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.connectionName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  strings.terminalWindowsForServer(
                    group.sessions.length,
                    connected,
                  ),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    List<TerminalWindowSnapshot> sessions,
    TerminalStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final connected = sessions.where((session) => session.isConnected).length;
    final attention = sessions.length - connected;
    final canPop = !page.embedded && Navigator.canPop(context);
    return Container(
      key: const ValueKey('terminal-windows-header'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.84),
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < 560 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.3;
          final title = viewModel.selectionMode
              ? strings.selectedWindows(viewModel.selectedSessionIds.length)
              : strings.terminalWindows;
          final subtitle = viewModel.selectionMode
              ? strings.selectedWindowsHint(sessions.length)
              : strings.terminalWindowsOverview(
                  sessions.length,
                  connected,
                  attention,
                );
          final heading = Semantics(
            header: true,
            liveRegion: viewModel.selectionMode,
            child: Row(
              children: [
                if (viewModel.selectionMode)
                  _headerIconButton(
                    key: const ValueKey('terminal-windows-exit-selection'),
                    icon: Icons.close_rounded,
                    tooltip: strings.exitSelection,
                    onPressed: viewModel.clearSelection,
                  )
                else if (canPop)
                  _headerIconButton(
                    key: const ValueKey('terminal-windows-back'),
                    icon: Icons.arrow_back_rounded,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: () => Navigator.pop(context),
                  )
                else
                  const AppIconBadge(
                    icon: Icons.terminal_rounded,
                    size: 44,
                    iconSize: 22,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: compact ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
          final actions = Row(
            mainAxisSize: MainAxisSize.min,
            children: viewModel.selectionMode
                ? [
                    _headerIconButton(
                      key: const ValueKey('terminal-windows-select-all'),
                      icon: Icons.select_all_rounded,
                      tooltip: strings.selectAll,
                      onPressed: viewModel.selectAll,
                    ),
                    const SizedBox(width: 6),
                    _headerIconButton(
                      key: const ValueKey('terminal-windows-close-selected'),
                      icon: Icons.delete_outline_rounded,
                      tooltip: strings.closeSelectedWindows,
                      color: colorScheme.error,
                      onPressed: viewModel.selectedSessionIds.isEmpty
                          ? null
                          : () => _closeSelectedWindows(context, viewModel),
                    ),
                  ]
                : [
                    if (page.connectionId != null) ...[
                      _headerIconButton(
                        key: const ValueKey('terminal-windows-new'),
                        icon: Icons.add_rounded,
                        tooltip: strings.newTerminalWindow,
                        onPressed: () => _openNewWindow(context, strings),
                      ),
                      const SizedBox(width: 6),
                    ],
                    _headerIconButton(
                      key: const ValueKey('terminal-windows-history'),
                      icon: Icons.history_rounded,
                      tooltip: strings.connectionHistory,
                      onPressed: () => Navigator.pushNamed(context, '/history'),
                    ),
                  ],
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading,
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: heading),
              const SizedBox(width: 14),
              actions,
            ],
          );
        },
      ),
    );
  }

  Widget _headerIconButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return SizedBox.square(
      key: key,
      dimension: 48,
      child: IconButton(
        icon: Icon(icon),
        tooltip: tooltip,
        color: color,
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, TerminalStrings strings) {
    if (page.embedded) {
      return const SizedBox.shrink();
    }

    return AppEmptyState(
      icon: Icons.terminal_rounded,
      title: strings.noOpenWindows,
      message: strings.openWindowsHint,
      action: page.connectionId == null
          ? null
          : FilledButton.icon(
              key: const ValueKey('terminal-windows-empty-new'),
              onPressed: () => _openNewWindow(context, strings),
              icon: const Icon(Icons.add_rounded),
              label: Text(strings.newTerminalWindow),
            ),
    );
  }

  Widget _buildWindowItem(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    TerminalWindowSnapshot session,
    TerminalStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final selected = viewModel.selectedSessionIds.contains(session.id);
    final statusColor = _statusColor(context, session);
    final cleanupCommand = session.tmuxKillCommand;
    final statusLabel = _statusLabel(session, strings);
    final statusDetail = _statusDetail(session);

    return RepaintBoundary(
      child: Semantics(
        key: ValueKey('terminal-window-card-${session.id}'),
        container: true,
        button: true,
        selected: selected,
        label: '${session.displayName}, $statusLabel',
        child: Card(
          elevation: 0,
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.12)
              : colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
            side: BorderSide(
              color: selected
                  ? colorScheme.primary.withValues(alpha: 0.55)
                  : colorScheme.outline,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              if (viewModel.selectionMode) {
                viewModel.toggleSelection(session.id);
              } else {
                _openWindow(context, session);
              }
            },
            onLongPress: () => viewModel.toggleSelection(session.id),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLeadingIcon(
                        context,
                        viewModel,
                        session,
                        selected,
                        statusColor,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            OverflowScrollText(
                              session.displayName,
                              selectable: false,
                              maxLines: 1,
                              style: TextStyle(
                                color: colorScheme.onSurface,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            OverflowScrollText(
                              session.connectionName,
                              selectable: false,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurface.withValues(
                                  alpha: 0.58,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (!viewModel.selectionMode) ...[
                        Container(
                          key: ValueKey('terminal-window-status-${session.id}'),
                          width: 48,
                          height: 48,
                          alignment: Alignment.center,
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: session.isConnected
                                  ? Colors.green.shade600
                                  : colorScheme.error,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              session.isConnected
                                  ? Icons.check_rounded
                                  : Icons.close_rounded,
                              color: Colors.white,
                              size: 13,
                            ),
                          ),
                        ),
                        PopupMenuButton<String>(
                          key: ValueKey('terminal-window-menu-${session.id}'),
                          tooltip: strings.windowActions,
                          onSelected: (value) {
                            switch (value) {
                              case 'rename':
                                _renameWindow(
                                  context,
                                  viewModel,
                                  session,
                                  strings,
                                );
                                break;
                              case 'close':
                                _closeWindow(
                                  context,
                                  viewModel,
                                  session,
                                  strings,
                                );
                                break;
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'rename',
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(
                                  Icons.edit_outlined,
                                  size: 20,
                                ),
                                title: Text(strings.renameTerminalWindow),
                              ),
                            ),
                            PopupMenuItem(
                              value: 'close',
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  Icons.close_rounded,
                                  size: 20,
                                  color: colorScheme.error,
                                ),
                                title: Text(
                                  strings.closeWindow,
                                  style: TextStyle(color: colorScheme.error),
                                ),
                              ),
                            ),
                          ],
                          child: const SizedBox.square(
                            dimension: 48,
                            child: Icon(Icons.more_vert_rounded),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (statusDetail != null) ...[
                    const SizedBox(height: 7),
                    Text(
                      statusDetail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.error,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  _buildSessionMeta(context, session, strings),
                  if (cleanupCommand != null) ...[
                    const SizedBox(height: 10),
                    _buildCleanupCommand(
                      context,
                      viewModel,
                      session.id,
                      cleanupCommand,
                      strings,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCleanupCommand(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    String sessionId,
    String command,
    TerminalStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      key: ValueKey('terminal-window-cleanup-$sessionId'),
      button: true,
      label: strings.copyCommand,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        onTap: () => _copyCleanupCommand(context, viewModel, command, strings),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(
                Icons.content_copy_rounded,
                size: 14,
                color: colorScheme.onSurface.withValues(alpha: 0.62),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OverflowScrollText(
                  command,
                  selectable: false,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontFamilyFallback: [
                      'Consolas',
                      'Microsoft YaHei',
                      'PingFang SC',
                      'sans-serif',
                    ],
                    fontSize: 11,
                    color: colorScheme.onSurface.withValues(alpha: 0.78),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSessionMeta(
    BuildContext context,
    TerminalWindowSnapshot session,
    TerminalStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final metaColor = colorScheme.onSurface.withValues(alpha: 0.62);

    return GestureDetector(
      onTap: () {}, // Prevent taps from propagating to the parent InkWell
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: _MetaChip(
                  icon: session.tmuxSessionName == null
                      ? Icons.terminal_rounded
                      : Icons.layers_outlined,
                  label: strings.sessionMode,
                  value: session.tmuxSessionName == null
                      ? strings.plainSshSession
                      : strings.tmuxSession,
                  color: metaColor,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetaChip(
                  icon: Icons.schedule_rounded,
                  label: strings.createdAt,
                  value: _formatTime(session.createdAt),
                  color: metaColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _MetaChip(
                  icon: Icons.timer_outlined,
                  label: strings.autoDestroy,
                  value: _formatAutoDestroy(session, strings),
                  color: metaColor,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetaChip(
                  icon: Icons.memory_rounded,
                  label: strings.memoryUsage,
                  value: _formatBytes(session.estimatedMemoryBytes),
                  color: metaColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatAutoDestroy(
    TerminalWindowSnapshot session,
    TerminalStrings strings,
  ) {
    final seconds = session.tmuxAutoDeleteSeconds;
    if (session.tmuxSessionName == null || seconds == null) {
      return strings.notAvailable;
    }

    final duration = _formatDuration(seconds, strings);
    if (session.isConnected || session.state == TerminalLinkState.connecting) {
      return strings.autoDestroyAfter(duration);
    }

    return strings.autoDestroyAt(
      _formatTime(session.updatedAt.add(Duration(seconds: seconds))),
    );
  }

  String _formatDuration(int seconds, TerminalStrings strings) {
    if (seconds >= 60) {
      return strings.durationMinutes((seconds + 59) ~/ 60);
    }
    return strings.durationSeconds(seconds);
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kib = bytes / 1024;
    if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
    final mib = kib / 1024;
    return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
  }

  Widget _buildLeadingIcon(
    BuildContext context,
    TerminalWindowsViewModel viewModel,
    TerminalWindowSnapshot session,
    bool selected,
    Color statusColor,
  ) {
    if (viewModel.selectionMode) {
      return Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: selected ? Theme.of(context).colorScheme.primary : null,
        size: 28,
      );
    }

    return AppIconBadge(
      icon: session.tmuxSessionName == null
          ? Icons.terminal_rounded
          : Icons.layers_outlined,
      size: 32,
      iconSize: 16,
      color: statusColor,
    );
  }

  Color _statusColor(BuildContext context, TerminalWindowSnapshot session) {
    final status = AppStatusColors.of(context);
    switch (session.state) {
      case TerminalLinkState.connected:
        return status.success;
      case TerminalLinkState.connecting:
        return status.warning;
      case TerminalLinkState.error:
        return status.error;
      case TerminalLinkState.disconnected:
        return status.neutral;
    }
  }

  String _statusLabel(TerminalWindowSnapshot session, TerminalStrings strings) {
    switch (session.state) {
      case TerminalLinkState.connected:
        return strings.connected;
      case TerminalLinkState.connecting:
        return strings.connecting;
      case TerminalLinkState.error:
        return strings.connectionError;
      case TerminalLinkState.disconnected:
        return strings.disconnected;
    }
  }

  String? _statusDetail(TerminalWindowSnapshot session) {
    if (session.state != TerminalLinkState.error &&
        session.state != TerminalLinkState.disconnected) {
      return null;
    }
    final message = session.errorMessage?.trim();
    return message == null || message.isEmpty ? null : message;
  }
}
