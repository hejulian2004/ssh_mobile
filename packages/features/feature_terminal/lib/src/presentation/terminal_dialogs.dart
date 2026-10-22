part of 'terminal_screen.dart';

extension _TerminalDialogs on _TerminalScreenState {
  Future<void> _openSiblingSession(BuildContext context) async {
    final strings = _strings(context);
    final action = await showDialog<_NewWindowAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.openNewWindow),
        content: Text(strings.createFrom(_serverName ?? strings.currentServer)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _NewWindowAction.editCurrent),
            child: Text(strings.editServer),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _NewWindowAction.addNew),
            child: Text(strings.addServer),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _NewWindowAction.current),
            child: Text(strings.create),
          ),
        ],
      ),
    );

    if (!context.mounted || action == null) return;

    switch (action) {
      case _NewWindowAction.current:
        await _openSessionWindow(context, widget.connectionId);
        break;
      case _NewWindowAction.editCurrent:
        final result = await Navigator.pushNamed(
          context,
          '/edit',
          arguments: widget.connectionId,
        );
        if (!context.mounted || result == null) return;
        await _openSessionWindow(context, widget.connectionId);
        break;
      case _NewWindowAction.addNew:
        final result = await Navigator.pushNamed(context, '/add');
        if (!context.mounted || result is! String) return;
        await _openSessionWindow(context, result);
        break;
    }
  }

  Future<void> _openSessionWindow(
    BuildContext context,
    String connectionId,
  ) async {
    final connections = context.read<TerminalConnectionPort>();
    final windowName = connections.defaultDisplayNameForConnection(
      connectionId,
    );
    await _openSessionWindowWithOptions(context, connectionId, windowName);
  }

  Future<void> _openSessionWindowWithOptions(
    BuildContext context,
    String connectionId,
    String windowName,
  ) async {
    final colorScheme = Theme.of(context).colorScheme;
    final strings = _strings(context);
    final connections = context.read<TerminalConnectionPort>();
    final viewModel = context.read<TerminalSessionViewModel>();
    final config = connections.getConnection(connectionId);
    final connectionName = config?.name ?? _serverName ?? strings.currentServer;

    showDialog(
      context: context,
      barrierDismissible: false,
      useSafeArea: false,
      builder: (ctx) => ConnectionProgressDialog(
        title: strings.connectingTo(connectionName),
        message: strings.openingNewWindow,
      ),
    );

    await Future<void>.delayed(Duration.zero);
    if (!context.mounted) return;

    final sessionId = await connections.openSession(
      connectionId,
      displayName: windowName,
    );
    if (!context.mounted) return;
    Navigator.of(context).pop();

    if (sessionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _formatConnectionFailure(strings, viewModel.capabilityError),
          ),
          backgroundColor: colorScheme.error,
        ),
      );
      return;
    }

    final session = viewModel.windowById(sessionId);
    if (session == null) return;

    _replaceWithTerminalSession(session, animated: true);
  }

  String _formatConnectionFailure(TerminalStrings strings, String? message) {
    final text = message ?? strings.unknown;
    final lower = text.toLowerCase();
    if (lower.contains('tmux is not installed') ||
        lower.contains('unable to check tmux')) {
      return strings.tmuxMissingHint(text);
    }
    return strings.connectionFailed(text);
  }

  Future<void> _showSessionSwitcher(BuildContext context) async {
    final strings = _strings(context);
    final viewModel = context.read<TerminalSessionViewModel>();
    final sessions = viewModel.windows;
    if (sessions.isEmpty) return;

    final action = await showModalBottomSheet<_SessionSwitcherAction>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => SafeArea(
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: sessions.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final session = sessions[index];
            final current = session.id == widget.sessionId;
            return ListTile(
              leading: Icon(
                session.isConnected ? Icons.link : Icons.link_off,
                color: session.isConnected
                    ? AppTheme.terminalGreen
                    : Theme.of(context).colorScheme.error,
              ),
              title: Text(session.displayName),
              subtitle: Text(
                session.isConnected
                    ? strings.connected
                    : (session.errorMessage ?? strings.disconnected),
              ),
              trailing: current
                  ? const Icon(Icons.check, color: AppTheme.terminalGreen)
                  : IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: session.isConnected
                          ? strings.disconnect
                          : strings.closeDisconnected,
                      onPressed: () => Navigator.pop(
                        ctx,
                        _SessionSwitcherAction.close(session.id),
                      ),
                    ),
              onTap: () => Navigator.pop(
                ctx,
                _SessionSwitcherAction.switchTo(session.id),
              ),
            );
          },
        ),
      ),
    );

    if (!context.mounted || action == null) return;

    if (action.close) {
      await viewModel.disconnectWindow(action.sessionId);
      if (!context.mounted) return;

      if (action.sessionId == widget.sessionId) {
        final nextSession = viewModel.nextWindowAfter(widget.sessionId);
        if (nextSession != null) {
          _replaceWithTerminalSession(nextSession, animated: true);
        } else {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      }
      return;
    }

    if (action.sessionId == widget.sessionId) return;

    final target = viewModel.windowById(action.sessionId);
    if (target == null) return;

    _replaceWithTerminalSession(target);
  }

  Future<void> _showTerminalEditMenu(TerminalSessionViewModel viewModel) async {
    if (_terminalMenuOpen) return;
    _terminalMenuOpen = true;
    _requestWindowsAwareTerminalFocus(viewModel);
    final strings = _strings(context);

    final selectedText = viewModel.getSelectedText();
    final action = await showMenu<_TerminalEditAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        _lastLongPressPosition.dx,
        _lastLongPressPosition.dy,
        _lastLongPressPosition.dx,
        _lastLongPressPosition.dy,
      ),
      items: [
        PopupMenuItem(
          value: _TerminalEditAction.selectCopy,
          child: Text(strings.selectCopy),
        ),
        PopupMenuItem(
          value: _TerminalEditAction.copy,
          enabled: selectedText.trim().isNotEmpty,
          child: Text(strings.copy),
        ),
        PopupMenuItem(
          value: _TerminalEditAction.paste,
          child: Text(strings.paste),
        ),
        if (!_isWindowsTerminalTarget) // Non-Windows selects all text from terminal view anchor
          PopupMenuItem(
            value: _TerminalEditAction.selectAll,
            child: Text(_selectAllLabel(context)),
          ),
      ],
    );

    _terminalMenuOpen = false;

    if (!mounted || action == null) return;

    switch (action) {
      case _TerminalEditAction.selectCopy:
        viewModel.clearSelection();
        await _showSelectableCopyLayer(viewModel);
        break;
      case _TerminalEditAction.copy:
        if (selectedText.trim().isEmpty) return;
        await viewModel.copySelectedText();
        viewModel.clearSelection();
        break;
      case _TerminalEditAction.paste:
        await viewModel.pasteClipboardText();
        break;
      case _TerminalEditAction.selectAll:
        viewModel.selectAllText();
        break;
    }
  }

  Future<void> _showSelectableCopyLayer(
    TerminalSessionViewModel viewModel,
  ) async {
    final strings = _strings(context);
    final text = viewModel.terminal.buffer.getText().trimRight();
    if (text.isEmpty) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => TerminalCopyScreen(
          title: _serverName ?? strings.defaultTerminal,
          text: text,
        ),
      ),
    );

    if (!mounted) return;
    _requestWindowsAwareTerminalFocus(viewModel);
  }

  Future<void> _confirmDisconnect(BuildContext context) async {
    final strings = _strings(context);
    final viewModel = context.read<TerminalSessionViewModel>();
    final session = viewModel.windowById(widget.sessionId);
    final windowName =
        session?.displayName ?? _serverName ?? strings.defaultTerminal;
    final isConnected = session?.isConnected == true;

    final confirmed = await AppConfirmDialog.show(
      context,
      title: isConnected ? strings.disconnect : strings.closeDisconnectedTitle,
      content: isConnected
          ? strings.disconnectContent(windowName)
          : strings.closeDisconnectedContent(windowName),
      cancelLabel: strings.cancel,
      confirmLabel: isConnected
          ? strings.disconnect
          : strings.closeDisconnected,
      isDestructive: true,
    );

    if (confirmed && context.mounted) {
      await viewModel.disconnectWindow(widget.sessionId);
      if (!context.mounted) return;

      final nextSession = viewModel.nextWindowAfter(widget.sessionId);
      if (nextSession != null) {
        _replaceWithTerminalSession(nextSession, animated: true);
      } else {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  String _selectAllLabel(BuildContext context) {
    return _strings(context).selectAll;
  }
}
