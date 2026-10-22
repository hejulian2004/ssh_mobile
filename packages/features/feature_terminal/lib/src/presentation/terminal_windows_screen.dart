import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:app_ui/app_ui.dart';

import '../application/terminal_windows_viewmodel.dart';
import '../domain/terminal_models.dart';
import '../domain/terminal_ports.dart';
import '../domain/terminal_strings.dart';

part 'widgets/terminal_windows_content.dart';
part 'widgets/terminal_windows_actions.dart';

class TerminalWindowsScreen extends StatelessWidget {
  final String? connectionId;

  const TerminalWindowsScreen({super.key, this.connectionId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppPageSurface(
        child: SafeArea(child: TerminalWindowsPage(connectionId: connectionId)),
      ),
    );
  }
}

class TerminalWindowsPage extends StatefulWidget {
  final String? connectionId;
  final bool showHeader;
  final bool embedded;

  const TerminalWindowsPage({
    super.key,
    this.connectionId,
    this.showHeader = true,
    this.embedded = false,
  });

  @override
  State<TerminalWindowsPage> createState() => _TerminalWindowsPageState();
}

class _TerminalWindowsPageState extends State<TerminalWindowsPage> {
  static const int _embeddedPreviewLimit = 4;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<TerminalWindowsViewModel>(
      create: (context) => TerminalWindowsViewModel.fromContext(
        context,
        settings: context.read<TerminalSettingsPort>(),
      )..connectionId = widget.connectionId,
      child: Consumer<TerminalWindowsViewModel>(
        builder: (context, viewModel, child) {
          final sessions = viewModel.sessions;
          final strings = TerminalStrings(viewModel.language);

          final body = sessions.isEmpty
              ? _buildEmptyState(context, strings)
              : _buildWindowList(context, viewModel, sessions, strings);

          if (widget.embedded) return body;

          return Column(
            children: [
              if (widget.showHeader)
                _buildHeader(context, viewModel, sessions, strings),
              Expanded(child: body),
            ],
          );
        },
      ),
    );
  }

  TerminalWindowsPage get page => widget;
}

class _TerminalServerGroup {
  const _TerminalServerGroup({
    required this.connectionName,
    required this.sessions,
  });

  final String connectionName;
  final List<TerminalWindowSnapshot> sessions;
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MetaChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: OverflowScrollText(
              '$label $value',
              selectable: false,
              maxLines: 1,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Terminal Package 自有的窗口名编辑弹窗，避免依赖 App Shell 的旧 Widget。
final class TerminalWindowNameDialog extends StatefulWidget {
  /// 创建窗口名弹窗。
  const TerminalWindowNameDialog({
    super.key,
    required this.initialName,
    required this.isNameAvailable,
    required this.title,
    required this.confirmLabel,
  });

  final String initialName;
  final bool Function(String name) isNameAvailable;
  final String title;
  final String confirmLabel;

  @override
  State<TerminalWindowNameDialog> createState() =>
      _TerminalWindowNameDialogState();
}

final class _TerminalWindowNameDialogState
    extends State<TerminalWindowNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _controller.text.trim();
    final valid = widget.isNameAvailable(name);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.title,
          errorText: name.isEmpty || valid ? null : 'Name already exists',
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (valid) Navigator.pop(context, name);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            TerminalStrings(
              context.read<TerminalSettingsPort>().language,
            ).cancel,
          ),
        ),
        FilledButton(
          onPressed: valid ? () => Navigator.pop(context, name) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
