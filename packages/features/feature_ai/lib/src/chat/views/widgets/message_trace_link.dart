part of 'message_bubble.dart';

class _AgentTraceLink extends StatelessWidget {
  final String chatId;
  final String runId;
  final AiChatMessageRecord message;

  const _AgentTraceLink({
    required this.chatId,
    required this.runId,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final typography = context.typography;
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AiStrings(language);
    final String label;
    if (message.traces.isNotEmpty) {
      label = [
        strings.trace,
        strings.traceEvents(message.traces.length),
      ].join(' · ');
    } else {
      final shortRunId = runId.length > 8
          ? runId.substring(runId.length - 8)
          : runId;
      label = '${strings.trace} · $shortRunId';
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: InkWell(
        key: const ValueKey('agent-trace-link'),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AgentTraceDebugPage(chatId: chatId, runId: runId),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 12,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: 14,
                color: colorScheme.primary.withValues(alpha: 0.9),
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typography.caption.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
