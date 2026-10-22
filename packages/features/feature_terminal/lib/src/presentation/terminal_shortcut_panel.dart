import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:app_ui/app_ui.dart';

import '../domain/terminal_keyboard_models.dart';
import '../domain/terminal_ports.dart';
import '../domain/terminal_strings.dart';
import 'widgets/terminal_custom_keyboard.dart';

const _builtinTerminalShortcutCommands = <TerminalShortcutCommand>[
  TerminalShortcutCommand(id: 'tab', label: 'TAB', code: '\t'),
  TerminalShortcutCommand(id: 'esc', label: 'ESC', code: '\x1b'),
  TerminalShortcutCommand(id: 'enter', label: 'ENTER', code: '\r'),
  TerminalShortcutCommand(id: 'bksp', label: 'BKSP', code: '\x7f'),
  TerminalShortcutCommand(id: 'up', label: '↑', code: '\x1b[A'),
  TerminalShortcutCommand(id: 'down', label: '↓', code: '\x1b[B'),
  TerminalShortcutCommand(id: 'left', label: '←', code: '\x1b[D'),
  TerminalShortcutCommand(id: 'right', label: '→', code: '\x1b[C'),
  TerminalShortcutCommand(id: 'home', label: 'HOME', code: '\x1b[H'),
  TerminalShortcutCommand(id: 'end', label: 'END', code: '\x1b[F'),
  TerminalShortcutCommand(id: 'pgup', label: 'PGUP', code: '\x1b[5~'),
  TerminalShortcutCommand(id: 'pgdn', label: 'PGDN', code: '\x1b[6~'),
  TerminalShortcutCommand(id: 'ctrl_c', label: 'CTRL+C', code: '\x03'),
  TerminalShortcutCommand(id: 'ctrl_d', label: 'CTRL+D', code: '\x04'),
  TerminalShortcutCommand(id: 'ctrl_l', label: 'CTRL+L', code: '\x0c'),
];

class TerminalShortcutPanel extends StatelessWidget {
  final TerminalStrings strings;
  final Color toolbarColor;
  final TextEditingController complexInputController;
  final ValueChanged<String> onSendData;
  final ValueChanged<String> onSendComplexInput;
  final ValueChanged<TerminalKeyboardStroke> onTerminalStroke;
  final FocusNode terminalFocusNode;
  final bool ctrlActive;
  final VoidCallback onToggleCtrl;
  final bool altActive;
  final VoidCallback onToggleAlt;

  const TerminalShortcutPanel({
    super.key,
    required this.strings,
    required this.toolbarColor,
    required this.complexInputController,
    required this.onSendData,
    required this.onSendComplexInput,
    required this.onTerminalStroke,
    required this.terminalFocusNode,
    required this.ctrlActive,
    required this.onToggleCtrl,
    required this.altActive,
    required this.onToggleAlt,
  });

  @visibleForTesting
  static int adjustedReorderIndex(int oldIndex, int newIndex) {
    return newIndex > oldIndex ? newIndex - 1 : newIndex;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final borderColor = colorScheme.outlineVariant;
    final scale = mobileUiScaleOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelColor = Color.alphaBlend(
      colorScheme.surface.withValues(alpha: isDark ? 0.72 : 0.82),
      toolbarColor,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: panelColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final accessibleCompactLayout =
                constraints.maxWidth < 400 &&
                MediaQuery.textScalerOf(context).scale(1) > 1.3;
            final actions = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _toolbarIconButton(
                  context,
                  key: const ValueKey('terminal-add-shortcut'),
                  icon: Icons.add_rounded,
                  tooltip: strings.addShortcut,
                  onPressed: () => _showAddShortcutDialog(context),
                ),
                const SizedBox(width: 6),
                _toolbarIconButton(
                  context,
                  key: const ValueKey('terminal-advanced-keyboard'),
                  icon: Icons.keyboard_rounded,
                  tooltip: strings.windowsKeyboard,
                  onPressed: () => _showAdvancedKeyboardBottomSheet(context),
                ),
              ],
            );

            if (accessibleCompactLayout) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildShortcutBar(context, scale, scrollAll: true),
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: _buildShortcutBar(context, scale)),
                const SizedBox(width: 6),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _toolbarIconButton(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      key: key,
      width: 48,
      height: 48,
      child: IconButton(
        icon: Icon(icon, size: 21),
        tooltip: tooltip,
        style: IconButton.styleFrom(
          backgroundColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.11),
          foregroundColor: Theme.of(context).colorScheme.primary,
          side: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.18),
          ),
        ),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildShortcutBar(
    BuildContext context,
    double scale, {
    bool scrollAll = false,
  }) {
    final shortcuts = context.read<TerminalShortcutPort>();
    context.select<TerminalShortcutPort, int>(
      (service) => service.orderVersion,
    );
    final customCommands = context
        .select<TerminalShortcutPort, List<TerminalShortcutCommand>>(
          (service) => service.customCommands,
        );

    final sortedAll = shortcuts.sortByUsage([
      ..._builtinTerminalShortcutCommands,
      ...customCommands,
    ]);

    final primaryIds = shortcuts.quickCommandIds.toSet();
    final primaryCommands = sortedAll
        .where((c) => primaryIds.contains(c.id) || c.custom)
        .toList();
    final secondaryCommands = sortedAll
        .where((c) => !primaryIds.contains(c.id) && !c.custom)
        .toList();

    if (scrollAll) {
      return SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            _buildCtrlKey(context, scale),
            SizedBox(width: 2 * scale),
            _buildAltKey(context, scale),
            SizedBox(width: 4 * scale),
            for (final command in primaryCommands)
              _quickKey(context, command, scale),
            if (secondaryCommands.isNotEmpty) ...[
              SizedBox(width: 4 * scale),
              _moreKeysButton(context, secondaryCommands, scale),
            ],
          ],
        ),
      );
    }

    return Row(
      children: [
        _buildCtrlKey(context, scale),
        SizedBox(width: 2 * scale),
        _buildAltKey(context, scale),
        SizedBox(width: 4 * scale),
        Expanded(
          child: SizedBox(
            height: 48,
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              itemCount: primaryCommands.length,
              onReorderItem: (oldIndex, newIndex) {
                final reordered = primaryCommands.toList();
                final item = reordered.removeAt(oldIndex);
                reordered.insert(newIndex, item);
                // Also reconstruct full commands list order to keep customized list state
                final finalIds = [
                  ...reordered.map((c) => c.id),
                  ...secondaryCommands.map((c) => c.id),
                ];
                shortcuts.reorderCommands(finalIds);
              },
              itemBuilder: (context, index) {
                final command = primaryCommands[index];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(command.id),
                  index: index,
                  child: _quickKey(context, command, scale),
                );
              },
            ),
          ),
        ),
        if (secondaryCommands.isNotEmpty) ...[
          SizedBox(width: 4 * scale),
          _moreKeysButton(context, secondaryCommands, scale),
        ],
      ],
    );
  }

  Widget _moreKeysButton(
    BuildContext context,
    List<TerminalShortcutCommand> secondaryCommands,
    double scale,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: InputChip(
        label: Text(
          strings.isEnglish ? 'MORE' : '更多键',
          style: TextStyle(
            fontSize: (11 * scale).clamp(9.5, 12.0),
            fontWeight: FontWeight.w700,
            color: colorScheme.primary,
          ),
        ),
        backgroundColor: colorScheme.primary.withValues(alpha: 0.08),
        side: BorderSide(color: colorScheme.primary.withValues(alpha: 0.35)),
        padding: EdgeInsets.symmetric(
          horizontal: (7 * scale).clamp(4.0, 8.0),
          vertical: (3 * scale).clamp(1.5, 4.0),
        ),
        materialTapTargetSize: MaterialTapTargetSize.padded,
        onPressed: () =>
            _showMoreKeysBottomSheet(context, secondaryCommands, scale),
      ),
    );
  }

  Widget _buildCtrlKey(BuildContext context, double scale) {
    final colorScheme = Theme.of(context).colorScheme;

    final activeBackground = colorScheme.primary;
    final activeBorder = colorScheme.primary;
    final activeForeground = colorScheme.onPrimary;

    final normalBackground = colorScheme.surfaceContainer.withValues(
      alpha: 0.72,
    );
    final normalBorder = colorScheme.primary.withValues(alpha: 0.48);
    final normalForeground = colorScheme.primary;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2 * scale),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: InputChip(
          label: Text(
            'CTRL',
            style: TextStyle(
              fontSize: (11 * scale).clamp(9.5, 12.0),
              fontFamily: 'monospace',
              fontFamilyFallback: const [
                'Consolas',
                'Microsoft YaHei',
                'PingFang SC',
                'sans-serif',
              ],
              fontWeight: FontWeight.w700,
            ),
          ),
          labelStyle: TextStyle(
            color: ctrlActive ? activeForeground : normalForeground,
          ),
          backgroundColor: ctrlActive ? activeBackground : normalBackground,
          side: BorderSide(color: ctrlActive ? activeBorder : normalBorder),
          padding: EdgeInsets.symmetric(
            horizontal: (7 * scale).clamp(4.0, 8.0),
            vertical: (3 * scale).clamp(1.5, 4.0),
          ),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onPressed: onToggleCtrl,
        ),
      ),
    );
  }

  Widget _buildAltKey(BuildContext context, double scale) {
    final colorScheme = Theme.of(context).colorScheme;

    final activeBackground = colorScheme.primary;
    final activeBorder = colorScheme.primary;
    final activeForeground = colorScheme.onPrimary;

    final normalBackground = colorScheme.surfaceContainer.withValues(
      alpha: 0.72,
    );
    final normalBorder = colorScheme.primary.withValues(alpha: 0.48);
    final normalForeground = colorScheme.primary;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2 * scale),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: InputChip(
          label: Text(
            'ALT',
            style: TextStyle(
              fontSize: (11 * scale).clamp(9.5, 12.0),
              fontFamily: 'monospace',
              fontFamilyFallback: const [
                'Consolas',
                'Microsoft YaHei',
                'PingFang SC',
                'sans-serif',
              ],
              fontWeight: FontWeight.w700,
            ),
          ),
          labelStyle: TextStyle(
            color: altActive ? activeForeground : normalForeground,
          ),
          backgroundColor: altActive ? activeBackground : normalBackground,
          side: BorderSide(color: altActive ? activeBorder : normalBorder),
          padding: EdgeInsets.symmetric(
            horizontal: (7 * scale).clamp(4.0, 8.0),
            vertical: (3 * scale).clamp(1.5, 4.0),
          ),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onPressed: onToggleAlt,
        ),
      ),
    );
  }

  Widget _quickKey(
    BuildContext context,
    TerminalShortcutCommand command,
    double scale,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final normalBackground = colorScheme.surfaceContainerHighest.withValues(
      alpha: 0.5,
    );
    final normalBorder = colorScheme.outlineVariant;
    final customBackground = colorScheme.primary.withValues(alpha: 0.12);
    final customBorder = command.custom
        ? AppTheme.terminalCyan
        : colorScheme.primary;
    final foreground = colorScheme.onSurfaceVariant;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2 * scale),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: InputChip(
          label: Container(
            constraints: BoxConstraints(maxWidth: 80 * scale),
            child: Text(
              command.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: (11 * scale).clamp(9.5, 12.0),
                fontFamily: 'monospace',
                fontFamilyFallback: const [
                  'Consolas',
                  'Microsoft YaHei',
                  'PingFang SC',
                  'sans-serif',
                ],
                fontWeight: FontWeight.w700,
                color: command.custom ? customBorder : foreground,
              ),
            ),
          ),
          backgroundColor: command.custom ? customBackground : normalBackground,
          side: BorderSide(color: command.custom ? customBorder : normalBorder),
          padding: EdgeInsets.symmetric(
            horizontal: (7 * scale).clamp(4.0, 8.0),
            vertical: (3 * scale).clamp(1.5, 4.0),
          ),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          avatar: command.custom
              ? Icon(Icons.bolt, size: 14 * scale, color: customBorder)
              : null,
          deleteIcon: Icon(Icons.close_rounded, size: 14 * scale),
          onDeleted: command.custom
              ? () => _confirmRemoveShortcut(context, command)
              : null,
          onPressed: () {
            context.read<TerminalShortcutPort>().recordUse(command.id);
            onSendData(command.code);
            terminalFocusNode.requestFocus();
          },
        ),
      ),
    );
  }

  void _showMoreKeysBottomSheet(
    BuildContext context,
    List<TerminalShortcutCommand> secondaryCommands,
    double scale,
  ) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppPageHeader(
                  title: strings.moreKeys,
                  subtitle: strings.moreKeysHint,
                  icon: Icons.keyboard_alt_outlined,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: secondaryCommands.map((cmd) {
                    return ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: InputChip(
                        label: Text(
                          cmd.label,
                          style: TextStyle(
                            fontSize: (11 * scale).clamp(9.5, 12.0),
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        onPressed: () {
                          context.read<TerminalShortcutPort>().recordUse(
                            cmd.id,
                          );
                          onSendData(cmd.code);
                          terminalFocusNode.requestFocus();
                        },
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showAdvancedKeyboardBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 820),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppPageHeader(
                    title: strings.windowsKeyboard,
                    subtitle: strings.windowsKeyboardHint,
                    icon: Icons.keyboard_rounded,
                  ),
                  const SizedBox(height: 16),
                  TerminalCustomKeyboard(
                    strings: strings,
                    controller: complexInputController,
                    onTerminalStroke: (stroke) {
                      onTerminalStroke(stroke);
                      terminalFocusNode.requestFocus();
                    },
                    onSubmit: (text) {
                      onSendComplexInput(text);
                      terminalFocusNode.requestFocus();
                    },
                    onCustomizeQuickKeys: () {
                      Navigator.pop(ctx);
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (context.mounted) {
                          _showQuickKeyCustomizer(context);
                        }
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showQuickKeyCustomizer(BuildContext context) async {
    final service = context.read<TerminalShortcutPort>();
    var selected = service.quickCommandIds.toSet();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppPageHeader(
                    title: strings.quickKeysTitle,
                    subtitle: strings.quickKeysHint,
                    icon: Icons.tune_rounded,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _builtinTerminalShortcutCommands.map((command) {
                      return FilterChip(
                        key: ValueKey('terminal-quick-key-${command.id}'),
                        label: Text(
                          command.label,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        selected: selected.contains(command.id),
                        onSelected: (enabled) async {
                          if (!enabled && selected.length == 1) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(strings.quickKeysAtLeastOne),
                              ),
                            );
                            return;
                          }
                          setModalState(() {
                            selected = {...selected};
                            if (enabled) {
                              selected.add(command.id);
                            } else {
                              selected.remove(command.id);
                            }
                          });
                          await service.setQuickCommandIds(selected);
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        key: const ValueKey('terminal-quick-keys-reset'),
                        onPressed: () async {
                          await service.resetQuickCommandIds();
                          setModalState(
                            () => selected = service.quickCommandIds.toSet(),
                          );
                        },
                        icon: const Icon(Icons.restart_alt_rounded),
                        label: Text(strings.resetQuickKeys),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('terminal-quick-keys-done'),
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(strings.done),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showAddShortcutDialog(BuildContext context) async {
    var label = '';
    var command = '';

    final result = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.addShortcut),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: InputDecoration(
                  labelText: strings.label,
                  hintText: 'e.g. LS',
                ),
                textInputAction: TextInputAction.next,
                onChanged: (value) => label = value,
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: strings.command,
                  hintText: 'e.g. ls -la',
                  alignLabelWithHint: true,
                ),
                keyboardType: TextInputType.multiline,
                minLines: 2,
                maxLines: 4,
                onChanged: (value) => command = value,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, (label, command)),
            child: Text(strings.add),
          ),
        ],
      ),
    );

    if (result == null || !context.mounted) return;

    await context.read<TerminalShortcutPort>().addCustomCommand(
      result.$1,
      result.$2,
    );
  }

  Future<void> _confirmRemoveShortcut(
    BuildContext context,
    TerminalShortcutCommand command,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.removeShortcut),
        content: Text(strings.removeShortcutContent(command.label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(strings.remove),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;
    await context.read<TerminalShortcutPort>().removeCustomCommand(command.id);
  }
}
