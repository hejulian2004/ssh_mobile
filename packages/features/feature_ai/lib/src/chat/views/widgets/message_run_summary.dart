part of 'message_bubble.dart';

class AgentRunInlineSummary extends StatefulWidget {
  final AiChatMessageRecord message;

  const AgentRunInlineSummary({super.key, required this.message});

  String get runId => message.agentRunId?.trim() ?? '';

  @override
  State<AgentRunInlineSummary> createState() => _AgentRunInlineSummaryState();
}

class _AgentRunInlineSummaryState extends State<AgentRunInlineSummary> {
  late Future<_AgentRunInlineData?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant AgentRunInlineSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.message, widget.message)) {
      _future = _load();
    }
  }

  Future<_AgentRunInlineData?> _load() async {
    final embedded = _AgentRunInlineData.fromMessage(widget.message);
    if (embedded != null) return embedded;

    final storage = context.read<AiStoragePort>();
    final metrics = await storage.loadAgentRunMetrics();
    AgentRunMetrics? metric;
    for (final item in metrics) {
      if (item.id == widget.runId) {
        metric = item;
        break;
      }
    }
    if (metric != null) return _AgentRunInlineData.fromMetric(metric);

    final events = await storage.loadAgentTraceEvents(widget.runId);
    if (events.isEmpty) return null;
    return _AgentRunInlineData.fromEvents(events);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_AgentRunInlineData?>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final language = context.select<AppSettings, AppLanguage>(
          (settings) => settings.language,
        );
        final strings = AiStrings(language);
        final statusColors = AppStatusColors.of(context);
        final statusColor = data.success
            ? statusColors.success
            : statusColors.error;
        final chips = <Widget>[
          _RunSummaryChip(
            key: const ValueKey('run-summary-status'),
            icon: data.success
                ? Icons.check_circle_outline
                : Icons.error_outline,
            label: data.success
                ? strings.agentRunCompleted
                : strings.agentRunNeedsAttention,
            color: statusColor,
            maxWidth: double.infinity,
          ),
          if (data.toolCalls > 0)
            _RunSummaryChip(
              key: const ValueKey('run-summary-tools'),
              icon: Icons.build_outlined,
              label: strings.agentRunTools(data.toolCalls),
              color: colorScheme.primary,
              maxWidth: double.infinity,
            ),
          if (data.approvalCount > 0)
            _RunSummaryChip(
              key: const ValueKey('run-summary-approvals'),
              icon: Icons.verified_user_outlined,
              label: strings.agentRunApprovals(
                data.approvedCount,
                data.approvalCount,
              ),
              color: colorScheme.tertiary,
              maxWidth: double.infinity,
            ),
          if (data.blockedCount > 0)
            _RunSummaryChip(
              key: const ValueKey('run-summary-blocked'),
              icon: Icons.block_outlined,
              label: strings.agentRunBlocked(data.blockedCount),
              color: colorScheme.error,
              maxWidth: double.infinity,
            ),
          if (data.elapsedMs != null)
            _RunSummaryChip(
              key: const ValueKey('run-summary-elapsed'),
              icon: Icons.timer_outlined,
              label: _formatRunElapsed(data.elapsedMs!),
              color: colorScheme.onSurfaceVariant,
              maxWidth: double.infinity,
            ),
          if (data.finalOutcome != null && !data.success)
            _RunSummaryChip(
              key: const ValueKey('run-summary-outcome'),
              icon: Icons.flag_outlined,
              label: strings.agentTraceOutcomeLabel(data.finalOutcome!),
              color: colorScheme.onSurfaceVariant,
              maxWidth: double.infinity,
            ),
        ];

        return Padding(
          key: ValueKey('agent-run-summary-${widget.runId}'),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < chips.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.sm),
                  chips[i],
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatRunElapsed(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }
}

class _AgentRunInlineData {
  final bool success;
  final int toolCalls;
  final int approvalCount;
  final int approvedCount;
  final int blockedCount;
  final int? elapsedMs;
  final String? finalOutcome;

  const _AgentRunInlineData({
    required this.success,
    required this.toolCalls,
    required this.approvalCount,
    required this.approvedCount,
    required this.blockedCount,
    required this.elapsedMs,
    required this.finalOutcome,
  });

  factory _AgentRunInlineData.fromMetric(AgentRunMetrics metric) {
    return _AgentRunInlineData(
      success: metric.success,
      toolCalls: metric.toolCalls,
      approvalCount: metric.approvalCount,
      approvedCount: metric.approvedCount,
      blockedCount: 0,
      elapsedMs: metric.elapsedMs,
      finalOutcome: metric.success ? null : '',
    );
  }

  static _AgentRunInlineData? fromMessage(AiChatMessageRecord message) {
    var sawMalformedSummary = false;
    for (final trace in message.traces.reversed) {
      if (trace.kind != 'agent_run_summary') continue;
      final summary = _decodeSummaryMap(trace.content);
      if (summary == null) {
        sawMalformedSummary = true;
        continue;
      }
      final blockedCount = message.traces.where((item) {
        if (item.kind == 'agent_run_summary') return false;
        final searchable = '${item.kind} ${item.title}'.toLowerCase();
        return searchable.contains('blocked') ||
            searchable.contains('rejected');
      }).length;
      return _AgentRunInlineData._fromSummary(
        summary,
        blockedCount: blockedCount,
        elapsedFallback: message.elapsedMs,
        toolCallsFallback: _messageToolCount(message.traces),
        approvalCountFallback: _messageKindCount(message.traces, 'approval'),
      );
    }
    if (sawMalformedSummary) {
      return _AgentRunInlineData._fromSummary(
        const {},
        blockedCount: 0,
        elapsedFallback: message.elapsedMs,
      );
    }
    return null;
  }

  factory _AgentRunInlineData.fromEvents(List<AgentTraceEvent> events) {
    final blockedCount = events.where((event) {
      final searchable = '${event.kind} ${event.status}'.toLowerCase();
      return searchable.contains('blocked') || searchable.contains('rejected');
    }).length;
    final toolEvents = _traceToolCount(events);
    final approvalEvents = events
        .where((event) => event.kind.contains('approval'))
        .length;
    for (final event in events.reversed) {
      if (event.kind != 'agent_run_summary') continue;
      final summary = _decodeSummaryMap(event.content);
      if (summary == null) continue;
      return _AgentRunInlineData._fromSummary(
        summary,
        blockedCount: blockedCount,
        elapsedFallback: event.durationMs,
        toolCallsFallback: toolEvents,
        approvalCountFallback: approvalEvents,
      );
    }

    return _AgentRunInlineData(
      success: false,
      toolCalls: toolEvents,
      approvalCount: approvalEvents,
      approvedCount: 0,
      blockedCount: blockedCount,
      elapsedMs: null,
      finalOutcome: '',
    );
  }

  factory _AgentRunInlineData._fromSummary(
    Map<String, dynamic> summary, {
    required int blockedCount,
    required int? elapsedFallback,
    int toolCallsFallback = 0,
    int approvalCountFallback = 0,
  }) {
    final finalOutcome =
        '${summary['finalOutcome'] ?? summary['outcome'] ?? ''}'.trim();
    final success = finalOutcome == 'success' || finalOutcome == 'completed';
    final startedAt = DateTime.tryParse('${summary['startedAt'] ?? ''}');
    final finishedAt = DateTime.tryParse('${summary['finishedAt'] ?? ''}');
    final derivedElapsed = startedAt != null && finishedAt != null
        ? finishedAt.difference(startedAt).inMilliseconds
        : null;
    return _AgentRunInlineData(
      success: success,
      toolCalls: _nullableIntValue(summary['toolCalls']) ?? toolCallsFallback,
      approvalCount:
          _nullableIntValue(summary['approvalCount']) ?? approvalCountFallback,
      approvedCount: _intValue(summary['approvedCount']),
      blockedCount: blockedCount,
      elapsedMs:
          _nullableIntValue(summary['elapsedMs']) ??
          elapsedFallback ??
          derivedElapsed,
      finalOutcome: finalOutcome,
    );
  }

  static Map<String, dynamic>? _decodeSummaryMap(String content) {
    try {
      final decoded = jsonDecode(content);
      return decoded is Map<String, dynamic>
          ? decoded
          : decoded is Map
          ? {for (final entry in decoded.entries) '${entry.key}': entry.value}
          : null;
    } catch (_) {
      return null;
    }
  }

  static int _intValue(Object? value) => _nullableIntValue(value) ?? 0;

  static int _messageKindCount(List<AiMessageTrace> traces, String pattern) {
    return traces
        .where(
          (trace) =>
              trace.kind != 'agent_run_summary' && trace.kind.contains(pattern),
        )
        .length;
  }

  static int _messageToolCount(List<AiMessageTrace> traces) {
    final requests = traces
        .where((trace) => trace.kind == 'tool_request')
        .length;
    if (requests > 0) return requests;
    return traces.where((trace) => trace.kind == 'tool_result').length;
  }

  static int _traceToolCount(List<AgentTraceEvent> events) {
    final requests = events
        .where((event) => event.kind == 'tool_request')
        .length;
    if (requests > 0) return requests;
    return events.where((event) => event.kind == 'tool_result').length;
  }

  static int? _nullableIntValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

class _RunSummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final double maxWidth;

  const _RunSummaryChip({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final typography = context.typography;
    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: AppSpacing.xs),
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: typography.caption.copyWith(
                    color: color,
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
