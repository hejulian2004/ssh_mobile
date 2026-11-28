part of 'message_bubble.dart';

class MessageActions extends StatelessWidget {
  final bool isUser;
  final bool isError;
  final String? assistantText;
  final VoidCallback? onEditUser;
  final VoidCallback? onRegenerate;
  final VoidCallback? onBranch;
  final VoidCallback? onContinueTimeout;

  const MessageActions({
    super.key,
    required this.isUser,
    required this.isError,
    this.assistantText,
    this.onEditUser,
    this.onRegenerate,
    this.onBranch,
    this.onContinueTimeout,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AiStrings(context.read<AppSettings>().language);
    final copyText = assistantText?.trim().isNotEmpty == true
        ? assistantText!.trim()
        : null;
    final children = <Widget>[
      if (copyText != null)
        _actionButton(
          context,
          tooltip: strings.copyReply,
          icon: Icons.content_copy_rounded,
          onPressed: () => _copyAssistantText(context, copyText, strings),
        ),
      if (copyText != null)
        _actionButton(
          context,
          tooltip: strings.selectAndCopy,
          icon: Icons.select_all_rounded,
          onPressed: () => _showSelectableCopySheet(context, copyText, strings),
        ),
      if (onEditUser != null)
        _actionButton(
          context,
          tooltip: strings.editAndResend,
          icon: Icons.edit_outlined,
          onPressed: onEditUser,
        ),
      if (onRegenerate != null)
        _actionButton(
          context,
          tooltip: strings.regenerate,
          icon: Icons.refresh_rounded,
          onPressed: onRegenerate,
        ),
      if (onBranch != null)
        _actionButton(
          context,
          tooltip: strings.createBranch,
          icon: Icons.call_split_rounded,
          onPressed: onBranch,
        ),
      if (onContinueTimeout != null)
        _actionButton(
          context,
          tooltip: strings.continue_,
          icon: Icons.play_arrow_rounded,
          onPressed: onContinueTimeout,
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final buttonSize = 32.0;
        final desiredWidth = children.length * buttonSize;
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : desiredWidth;
        final maxActionsWidth = availableWidth < buttonSize
            ? availableWidth
            : desiredWidth.clamp(buttonSize, availableWidth);
        return Padding(
          padding: const EdgeInsets.only(left: 2, right: 2, bottom: 2),
          child: Align(
            alignment: isUser && !isError
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxActionsWidth),
              child: Wrap(children: children),
            ),
          ),
        );
      },
    );
  }

  Future<void> _copyAssistantText(
    BuildContext context,
    String text,
    AiStrings strings,
  ) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(strings.replyCopied),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showSelectableCopySheet(
    BuildContext context,
    String text,
    AiStrings strings,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.78;
        return SafeArea(
          child: SizedBox(
            height: maxHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          strings.selectAndCopy,
                          style: Theme.of(sheetContext).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        tooltip: strings.copyAll,
                        icon: const Icon(Icons.content_copy_rounded),
                        onPressed: () =>
                            _copyAssistantText(sheetContext, text, strings),
                      ),
                      IconButton(
                        tooltip: strings.close,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(sheetContext),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.36,
                        ),
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusSmall,
                        ),
                        border: Border.all(
                          color: colorScheme.outlineVariant.withValues(
                            alpha: 0.72,
                          ),
                        ),
                      ),
                      child: Scrollbar(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(
                            text,
                            style: TextStyle(
                              color: colorScheme.onSurface,
                              height: 1.38,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _actionButton(
    BuildContext context, {
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        iconSize: 15,
        color: colorScheme.onSurfaceVariant,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
  }
}
