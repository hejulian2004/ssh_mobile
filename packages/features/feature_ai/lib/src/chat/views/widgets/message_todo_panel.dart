part of 'message_bubble.dart';

class ChatTodoPanel extends StatefulWidget {
  final AiChatMessageRecord message;
  final AiStrings strings;
  final String? Function(String connectionId) serverDisplayNameFor;
  final Future<void> Function(String stepId) onRetryStep;
  final Future<void> Function(String stepId, String reason) onSkipStep;
  final VoidCallback? onRevisePlan;

  const ChatTodoPanel({
    super.key,
    required this.message,
    required this.strings,
    required this.serverDisplayNameFor,
    required this.onRetryStep,
    required this.onSkipStep,
    this.onRevisePlan,
  });

  @override
  State<ChatTodoPanel> createState() => _ChatTodoPanelState();
}

class _ChatTodoPanelState extends State<ChatTodoPanel> {
  final Set<String> _expandedStepIds = {};

  @override
  void didUpdateWidget(covariant ChatTodoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final liveIds = widget.message.todoSteps.map((step) => step.id).toSet();
    _expandedStepIds.removeWhere((id) => !liveIds.contains(id));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final typography = context.typography;
    final statusColors = AppStatusColors.of(context);
    final snapshot = const PlanExecutionController().snapshot(
      widget.message.todoSteps,
    );
    final currentStepId = snapshot.currentStep?.id;
    final total = widget.message.todoSteps.length;
    final done = widget.message.todoSteps
        .where(
          (step) =>
              step.status == StepStatus.success ||
              step.status == StepStatus.skipped,
        )
        .length;
    final allDone = total > 0 && done == total;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.assignment_outlined,
                size: 16,
                color: colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  widget.strings.todoTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typography.bodyMedium.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '$done/$total',
                style: typography.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: allDone
                      ? statusColors.success
                      : colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          for (var index = 0; index < widget.message.todoSteps.length; index++)
            _buildStepRow(
              context,
              widget.message.todoSteps[index],
              currentStepId,
              colorScheme,
              isFirst: index == 0,
              isLast: index == widget.message.todoSteps.length - 1,
            ),
        ],
      ),
    );
  }

  Widget _buildStepRow(
    BuildContext context,
    AiTodoStep step,
    String? currentStepId,
    ColorScheme colorScheme, {
    required bool isFirst,
    required bool isLast,
  }) {
    final typography = context.typography;
    final isExpanded = _expandedStepIds.contains(step.id);
    final hasLogs =
        step.stdout?.isNotEmpty == true || step.stderr?.isNotEmpty == true;
    final isCurrent = currentStepId == step.id;
    final isFailed = step.status == StepStatus.failed;
    final isRunning = step.status == StepStatus.running;
    final isSuccess = step.status == StepStatus.success;
    final connectionId = step.connectionId?.trim();
    final resolvedServerName = connectionId?.isNotEmpty == true
        ? widget.serverDisplayNameFor(connectionId!)?.trim()
        : null;
    final serverName = connectionId?.isNotEmpty == true
        ? (resolvedServerName?.isNotEmpty == true
              ? resolvedServerName!
              : widget.strings.serverTarget)
        : null;
    final expandedIndent = MediaQuery.sizeOf(context).width < 360
        ? 0.0
        : AppSpacing.xxl;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          container: true,
          button: true,
          expanded: isExpanded,
          label: widget.strings.todoStepSemantics(step.name, step.status),
          child: InkWell(
            key: ValueKey('todo-step-${step.id}'),
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expandedStepIds.remove(step.id);
                } else {
                  _expandedStepIds.add(step.id);
                }
              });
            },
            borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            child: Ink(
              decoration: BoxDecoration(
                color: isRunning
                    ? colorScheme.primary.withValues(alpha: 0.07)
                    : isFailed
                    ? colorScheme.error.withValues(alpha: 0.07)
                    : isCurrent && step.status == StepStatus.pending
                    ? colorScheme.secondaryContainer.withValues(alpha: 0.25)
                    : null,
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _StepSpine(
                        isFirst: isFirst,
                        isLast: isLast,
                        icon: _buildStatusIcon(
                          context,
                          step.status,
                          colorScheme,
                        ),
                        lineColor: colorScheme.outlineVariant.withValues(
                          alpha: 0.7,
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                            vertical: AppSpacing.sm,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      step.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: typography.bodyMedium.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: isSuccess
                                            ? colorScheme.onSurface.withValues(
                                                alpha: 0.55,
                                              )
                                            : colorScheme.onSurface,
                                        decoration: isSuccess
                                            ? TextDecoration.lineThrough
                                            : null,
                                      ),
                                    ),
                                    if (step.description.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          step.description,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: typography.caption,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (serverName != null) ...[
                                const SizedBox(width: AppSpacing.sm),
                                _TodoServerChip(
                                  key: ValueKey('todo-server-${step.id}'),
                                  name: serverName,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (isExpanded)
          Padding(
            padding: EdgeInsets.only(
              left: expandedIndent,
              top: AppSpacing.xs,
              right: AppSpacing.xs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (step.command.isNotEmpty)
                  _TodoCodeBlock(
                    key: ValueKey('todo-command-${step.id}'),
                    text: step.command,
                    semanticLabel: widget.strings.todoCommand,
                    maxHeight: 160,
                    backgroundColor: colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.55),
                    foregroundColor: colorScheme.onSurface,
                    borderColor: colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                    fontSize: 11,
                  ),
                if (isFailed) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    widget.strings.todoFailureGuidance,
                    style: typography.caption,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      FilledButton.icon(
                        key: ValueKey('todo-retry-${step.id}'),
                        onPressed: () => widget.onRetryStep(step.id),
                        icon: const Icon(Icons.refresh, size: 16),
                        label: Text(widget.strings.todoRetryStep),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          visualDensity: VisualDensity.standard,
                          tapTargetSize: MaterialTapTargetSize.padded,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                          ),
                          textStyle: typography.button.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        key: ValueKey('todo-skip-${step.id}'),
                        onPressed: () => _skipStep(step),
                        icon: const Icon(Icons.skip_next, size: 16),
                        label: Text(widget.strings.todoSkipStep),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          visualDensity: VisualDensity.standard,
                          tapTargetSize: MaterialTapTargetSize.padded,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                          ),
                          textStyle: typography.button.copyWith(fontSize: 12),
                        ),
                      ),
                      OutlinedButton.icon(
                        key: ValueKey('todo-revise-${step.id}'),
                        onPressed: widget.onRevisePlan,
                        icon: const Icon(Icons.edit_note_outlined, size: 16),
                        label: Text(widget.strings.todoRevisePlan),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          visualDensity: VisualDensity.standard,
                          tapTargetSize: MaterialTapTargetSize.padded,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                          ),
                          textStyle: typography.button.copyWith(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
                if (hasLogs) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _TodoCodeBlock(
                    key: ValueKey('todo-logs-${step.id}'),
                    text: '${step.stdout ?? ''}\n${step.stderr ?? ''}'.trim(),
                    semanticLabel: widget.strings.todoLogs,
                    maxHeight: 180,
                    backgroundColor: AppTheme.terminalBg,
                    foregroundColor: AppTheme.terminalGreen,
                    fontSize: 11,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _skipStep(AiTodoStep step) async {
    final reason = await showTodoSkipReasonDialog(context, widget.strings);
    if (!mounted || reason == null) return;
    await widget.onSkipStep(step.id, reason);
  }

  Widget _buildStatusIcon(
    BuildContext context,
    StepStatus status,
    ColorScheme colorScheme,
  ) {
    switch (status) {
      case StepStatus.pending:
        return Icon(
          Icons.circle_outlined,
          size: 16,
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        );
      case StepStatus.running:
        return const AppLoadingIndicator(size: 16, strokeWidth: 2);
      case StepStatus.success:
        final extColors = Theme.of(context).extension<ExtendedColors>();
        return Icon(
          Icons.check_circle_rounded,
          size: 16,
          color: extColors?.success ?? colorScheme.primary,
        );
      case StepStatus.failed:
        return Icon(Icons.cancel_rounded, size: 16, color: colorScheme.error);
      case StepStatus.skipped:
        return Icon(
          Icons.next_plan_outlined,
          size: 16,
          color: colorScheme.onSurfaceVariant,
        );
    }
  }
}

/// 步骤时间轴脊线：状态点 + 连接上一/下一步的细线。
class _StepSpine extends StatelessWidget {
  final bool isFirst;
  final bool isLast;
  final Widget icon;
  final Color lineColor;

  const _StepSpine({
    required this.isFirst,
    required this.isLast,
    required this.icon,
    required this.lineColor,
  });

  static const double _iconTop = 9.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      child: Column(
        children: [
          if (isFirst)
            const SizedBox(height: _iconTop)
          else
            SizedBox(height: _iconTop, child: _buildLine()),
          icon,
          if (!isLast) Expanded(child: _buildLine()),
        ],
      ),
    );
  }

  Widget _buildLine() {
    return Center(child: Container(width: 2, color: lineColor));
  }
}

class _TodoServerChip extends StatelessWidget {
  final String name;

  const _TodoServerChip({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final maxWidth = (MediaQuery.sizeOf(context).width * 0.3)
        .clamp(68.0, 150.0)
        .toDouble();
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dns_outlined,
              size: 12,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9.5,
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TodoCodeBlock extends StatefulWidget {
  final String text;
  final String semanticLabel;
  final double maxHeight;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color? borderColor;
  final double fontSize;

  const _TodoCodeBlock({
    super.key,
    required this.text,
    required this.semanticLabel,
    required this.maxHeight,
    required this.backgroundColor,
    required this.foregroundColor,
    this.borderColor,
    required this.fontSize,
  });

  @override
  State<_TodoCodeBlock> createState() => _TodoCodeBlockState();
}

class _TodoCodeBlockState extends State<_TodoCodeBlock> {
  late final ScrollController _verticalController;

  @override
  void initState() {
    super.initState();
    _verticalController = ScrollController(keepScrollOffset: false);
  }

  @override
  void dispose() {
    _verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = context.typography.codeSmall;
    return Semantics(
      label: widget.semanticLabel,
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: widget.backgroundColor,
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
          border: widget.borderColor == null
              ? null
              : Border.all(color: widget.borderColor!),
        ),
        child: Scrollbar(
          controller: _verticalController,
          child: SingleChildScrollView(
            controller: _verticalController,
            child: OverflowScrollText(
              widget.text,
              style: baseStyle.copyWith(
                color: widget.foregroundColor,
                fontSize: widget.fontSize,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<String?> showTodoSkipReasonDialog(
  BuildContext context,
  AiStrings strings,
) {
  return showDialog<String>(
    context: context,
    builder: (_) => TodoSkipReasonDialog(strings: strings),
  );
}

class TodoSkipReasonDialog extends StatefulWidget {
  final AiStrings strings;

  const TodoSkipReasonDialog({super.key, required this.strings});

  @override
  State<TodoSkipReasonDialog> createState() => _TodoSkipReasonDialogState();
}

class _TodoSkipReasonDialogState extends State<TodoSkipReasonDialog> {
  late final TextEditingController _controller;

  bool get _canSubmit => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController()..addListener(_handleTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleTextChanged)
      ..dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    if (mounted) setState(() {});
  }

  void _submit() {
    final reason = _controller.text.trim();
    if (reason.isEmpty) return;
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final visibleHeight = media.size.height - media.viewInsets.bottom;
    final compact = visibleHeight < 320;

    return Dialog(
      key: const ValueKey('todo-skip-dialog'),
      insetPadding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: compact ? 8 : 16,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: EdgeInsets.all(compact ? 12 : 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.skip_next_rounded,
                    size: compact ? 20 : 24,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.strings.todoSkipReasonTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              SizedBox(height: compact ? 6 : 14),
              Flexible(
                child: SingleChildScrollView(
                  key: const ValueKey('todo-skip-dialog-scroll'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!compact) ...[
                        Text(widget.strings.todoSkipReasonPrompt),
                        const SizedBox(height: 8),
                      ],
                      TextField(
                        key: const ValueKey('todo-skip-reason-field'),
                        controller: _controller,
                        autofocus: true,
                        minLines: 1,
                        maxLines: compact ? 1 : 3,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) {
                          if (_canSubmit) _submit();
                        },
                        decoration: InputDecoration(
                          labelText: compact
                              ? widget.strings.todoSkipReasonPrompt
                              : null,
                          hintText: widget.strings.todoSkipReasonHint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: compact ? 6 : 14),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const ValueKey('todo-skip-cancel'),
                    style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(widget.strings.cancel),
                  ),
                  FilledButton(
                    key: const ValueKey('todo-skip-confirm'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    onPressed: _canSubmit ? _submit : null,
                    child: Text(widget.strings.todoSkipConfirm),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
