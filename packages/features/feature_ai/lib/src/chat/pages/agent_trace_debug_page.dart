import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:feature_ai/src/chat/views/widgets/agent_trace_timeline.dart';
import 'package:feature_ai/src/chat/views/widgets/ai_strings.dart';
import 'package:app_ui/app_ui.dart';

enum _TraceFilter { all, tools, approvals, blocked, errors }

final _kPlaceholderTraceData = _TraceDebugData(
  metrics: AgentRunMetrics(
    id: 'placeholder-run-id',
    startedAt: DateTime(2026, 9, 1, 10, 0),
    finishedAt: DateTime(2026, 9, 1, 10, 0, 15),
    model: 'claude-3-5-sonnet',
    promptTokens: 1240,
    completionTokens: 380,
    totalTokens: 1620,
    elapsedMs: 15400,
    toolCalls: 4,
    cacheHits: 1,
    approvalCount: 1,
    approvedCount: 1,
    success: true,
  ),
  events: [
    AgentTraceEvent(
      runId: 'placeholder-run-id',
      chatId: 'placeholder-chat-id',
      createdAt: DateTime(2026, 9, 1, 10, 0, 1),
      sequence: 1,
      kind: 'agent_start',
      title: 'Agent run initiated',
      content: 'Task: Check memory and running processes on production host',
      status: 'completed',
      durationMs: 120,
    ),
    AgentTraceEvent(
      runId: 'placeholder-run-id',
      chatId: 'placeholder-chat-id',
      createdAt: DateTime(2026, 9, 1, 10, 0, 3),
      sequence: 2,
      kind: 'tool_call',
      title: 'execute_command(ps aux --sort=-%cpu)',
      content:
          'USER PID %CPU %MEM COMMAND\nroot 1024 45.2 2.1 nginx: master\napp 2048 18.4 12.8 node /app/server.js',
      toolName: 'execute_command',
      status: 'success',
      durationMs: 450,
    ),
    AgentTraceEvent(
      runId: 'placeholder-run-id',
      chatId: 'placeholder-chat-id',
      createdAt: DateTime(2026, 9, 1, 10, 0, 6),
      sequence: 3,
      kind: 'approval_request',
      title: 'Command Execution Approval Granted',
      content: 'Action: Restart service unit "worker-pool.service"',
      status: 'approved',
      durationMs: 200,
    ),
    AgentTraceEvent(
      runId: 'placeholder-run-id',
      chatId: 'placeholder-chat-id',
      createdAt: DateTime(2026, 9, 1, 10, 0, 10),
      sequence: 4,
      kind: 'agent_finish',
      title: 'Task completed successfully',
      content: 'Generated diagnosis and resolution summary for the operator.',
      status: 'completed',
      durationMs: 80,
    ),
  ],
);

class AgentTraceDebugPage extends StatefulWidget {
  final String chatId;
  final String runId;

  const AgentTraceDebugPage({
    super.key,
    required this.chatId,
    required this.runId,
  });

  @override
  State<AgentTraceDebugPage> createState() => _AgentTraceDebugPageState();
}

class _AgentTraceDebugPageState extends State<AgentTraceDebugPage> {
  late Future<_TraceDebugData> _future;
  _TraceFilter _filter = _TraceFilter.all;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_TraceDebugData> _load() async {
    try {
      final storage = context.read<AiStoragePort>();
      final events = await storage.loadAgentTraceEvents(widget.runId);
      final metrics = await storage.loadAgentRunMetrics();
      return _TraceDebugData(
        events: events,
        metrics: metrics.cast<AgentRunMetrics?>().firstWhere(
          (metric) => metric?.id == widget.runId,
          orElse: () => null,
        ),
      );
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'Failed to load agent trace',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  void _retry() {
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AiStrings(language);
    return Scaffold(
      appBar: AppBar(title: Text(strings.agentTraceTitle)),
      body: AppPageSurface(
        child: FutureBuilder<_TraceDebugData>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return AppSkeletonizer.zone(
                enabled: true,
                semanticsLabel: strings.agentTraceTitle,
                child: _TraceDebugBody(
                  runId: widget.runId,
                  data: _kPlaceholderTraceData,
                  events: _kPlaceholderTraceData.events,
                  strings: strings,
                  selectedFilter: _TraceFilter.all,
                  onFilterSelected: (_) {},
                ),
              );
            }
            final data = snapshot.data;
            if (snapshot.hasError) {
              return AppEmptyState(
                icon: Icons.error_outline_rounded,
                title: strings.agentTraceLoadFailedTitle,
                message: strings.agentTraceLoadFailedMessage,
                action: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(strings.retry),
                ),
              );
            }
            if (data == null || (data.events.isEmpty && data.metrics == null)) {
              return _EmptyTrace(runId: widget.runId, strings: strings);
            }
            return _TraceDebugBody(
              runId: widget.runId,
              data: data,
              events: _filteredEvents(data.events),
              strings: strings,
              selectedFilter: _filter,
              onFilterSelected: (value) => setState(() => _filter = value),
            );
          },
        ),
      ),
    );
  }

  List<AgentTraceEvent> _filteredEvents(List<AgentTraceEvent> events) {
    return events
        .where((event) {
          switch (_filter) {
            case _TraceFilter.all:
              return true;
            case _TraceFilter.tools:
              return event.kind.contains('tool') ||
                  event.toolName?.trim().isNotEmpty == true;
            case _TraceFilter.approvals:
              return event.kind.contains('approval');
            case _TraceFilter.blocked:
              return event.kind.contains('blocked') ||
                  event.status.contains('blocked') ||
                  event.status.contains('rejected') ||
                  event.status.contains('unavailable');
            case _TraceFilter.errors:
              return event.kind.contains('error') ||
                  event.status.contains('error') ||
                  event.status.contains('failed');
          }
        })
        .toList(growable: false);
  }
}

class _TraceDebugData {
  final List<AgentTraceEvent> events;
  final AgentRunMetrics? metrics;

  const _TraceDebugData({required this.events, required this.metrics});
}

class _TraceDebugBody extends StatelessWidget {
  final String runId;
  final _TraceDebugData data;
  final List<AgentTraceEvent> events;
  final AiStrings strings;
  final _TraceFilter selectedFilter;
  final ValueChanged<_TraceFilter> onFilterSelected;

  const _TraceDebugBody({
    required this.runId,
    required this.data,
    required this.events,
    required this.strings,
    required this.selectedFilter,
    required this.onFilterSelected,
  });

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = MediaQuery.sizeOf(context).width < 600
        ? AppTheme.compactPagePadding
        : AppTheme.pagePadding;
    final bottomPadding = MediaQuery.paddingOf(context).bottom + 16;

    return CustomScrollView(
      key: const ValueKey('agent-trace-scroll'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            horizontalPadding,
            horizontalPadding,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: _TraceContentWidth(
              child: _OverviewSection(
                runId: runId,
                events: data.events,
                metrics: data.metrics,
                strings: strings,
              ),
            ),
          ),
        ),
        if (data.events.isEmpty)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            sliver: SliverToBoxAdapter(
              child: _TraceContentWidth(
                child: _EmptyTrace(runId: runId, strings: strings),
              ),
            ),
          )
        else ...[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              AppSpacing.lg,
              horizontalPadding,
              0,
            ),
            sliver: SliverToBoxAdapter(
              child: _TraceContentWidth(
                child: _FilterBar(
                  selected: selectedFilter,
                  onSelected: onFilterSelected,
                  strings: strings,
                ),
              ),
            ),
          ),
          if (events.isEmpty)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: SliverToBoxAdapter(
                child: _TraceContentWidth(
                  child: AppEmptyState(
                    icon: Icons.filter_alt_off_outlined,
                    title: strings.agentTraceNoMatchingTitle,
                    message: strings.agentTraceNoMatchingMessage,
                    compact: true,
                    contained: false,
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                AppSpacing.sm,
                horizontalPadding,
                0,
              ),
              sliver: SliverList.builder(
                itemCount: events.length,
                itemBuilder: (context, index) {
                  final event = events[index];
                  return _TraceContentWidth(
                    key: ValueKey('trace-event-${event.id}'),
                    child: TraceTimelineItem(
                      key: ValueKey(event.id),
                      event: event,
                      strings: strings,
                      isFirst: index == 0,
                      isLast: index == events.length - 1,
                      offsetLabel:
                          '+${_formatDuration(event.createdAt.difference(data.events.first.createdAt))}',
                    ),
                  );
                },
              ),
            ),
        ],
        SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
      ],
    );
  }
}

class _TraceContentWidth extends StatelessWidget {
  final Widget child;

  const _TraceContentWidth({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}

class _OverviewSection extends StatelessWidget {
  final String runId;
  final List<AgentTraceEvent> events;
  final AgentRunMetrics? metrics;
  final AiStrings strings;

  const _OverviewSection({
    required this.runId,
    required this.events,
    required this.metrics,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final summary = _summaryJson(events);
    final finalOutcome = summary['finalOutcome'] as String?;
    final selectedTools = (metrics?.selectedToolSet.isNotEmpty == true)
        ? metrics!.selectedToolSet
        : _stringList(summary['selectedToolSet']);
    final memorySources = (metrics?.memorySources.isNotEmpty == true)
        ? metrics!.memorySources
        : _stringList(summary['memorySources']);
    final statusColor = _statusColor(context, metrics, finalOutcome);
    final provenance = <Widget>[
      if (selectedTools.isNotEmpty)
        _SmallLabel(strings.agentTraceSelectedTools, selectedTools.join(', ')),
      if (memorySources.isNotEmpty)
        _SmallLabel(strings.agentTraceMemorySources, memorySources.join(', ')),
      if (finalOutcome != null)
        _SmallLabel(
          strings.agentTraceFinalReason,
          _finalOutcomeLabel(finalOutcome, strings),
        ),
    ];
    return AppSectionCard(
      title: strings.agentTraceOverview,
      icon: Icons.analytics_outlined,
      trailing: Text(
        strings.agentTraceEventCount(events.length),
        style: context.typography.caption.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      contentGap: AppSpacing.sm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              _MetricPill(
                strings.agentTraceMetricStatus,
                _statusLabel(metrics, finalOutcome, strings),
                valueColor: statusColor,
              ),
              _MetricPill(
                strings.agentTraceMetricModel,
                metrics?.model ?? '${summary['model'] ?? '-'}',
              ),
              _MetricPill(
                strings.agentTraceMetricHelper,
                metrics?.helperModel ?? '${summary['helperModel'] ?? '-'}',
              ),
              _MetricPill(
                strings.agentTraceMetricAudit,
                metrics?.auditModel ?? '${summary['auditModel'] ?? '-'}',
              ),
              _MetricPill(
                strings.agentTraceMetricElapsed,
                _elapsed(metrics, summary),
              ),
              _MetricPill(strings.agentTraceMetricRun, runId),
              _MetricPill(
                strings.agentTraceMetricTotal,
                '${metrics?.totalTokens ?? _totalTokens(summary)}',
              ),
              _MetricPill(
                strings.agentTraceMetricPrompt,
                '${metrics?.promptTokens ?? summary['promptTokens'] ?? 0}',
              ),
              _MetricPill(
                strings.agentTraceMetricCompletion,
                '${metrics?.completionTokens ?? summary['completionTokens'] ?? 0}',
              ),
              _MetricPill(
                strings.agentTraceMetricTools,
                '${metrics?.toolCalls ?? summary['toolCalls'] ?? _countKind(events, 'tool_request')}',
              ),
              _MetricPill(
                strings.agentTraceMetricApprovals,
                '${metrics?.approvalCount ?? summary['approvalCount'] ?? _countKind(events, 'approval')}',
              ),
              _MetricPill(
                strings.agentTraceMetricApproved,
                '${metrics?.approvedCount ?? summary['approvedCount'] ?? 0}',
              ),
              _MetricPill(
                strings.agentTraceMetricCacheHits,
                '${metrics?.cacheHits ?? summary['cacheHits'] ?? 0}',
              ),
              _MetricPill(
                strings.agentTraceMetricDedupBlocked,
                '${metrics?.dedupBlockedCalls ?? summary['dedupBlockedCalls'] ?? 0}',
              ),
              _MetricPill(
                strings.agentTraceMetricAudits,
                '${metrics?.auditCount ?? summary['auditEscalationLevel'] ?? 0}',
              ),
              _MetricPill(
                strings.agentTraceMetricHelperFanout,
                '${metrics?.helperFanout ?? summary['helperFanout'] ?? 0}',
              ),
            ],
          ),
          if (provenance.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            const TraceLedgerRule(),
            const SizedBox(height: AppSpacing.xs),
            ...provenance,
          ],
        ],
      ),
    );
  }

  static Map<String, dynamic> _summaryJson(List<AgentTraceEvent> events) {
    for (final event in events.reversed) {
      if (event.kind != 'agent_run_summary') continue;
      try {
        final decoded = jsonDecode(event.content);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) {
          return {
            for (final entry in decoded.entries) '${entry.key}': entry.value,
          };
        }
      } catch (_) {
        return const {};
      }
    }
    return const {};
  }

  static String _statusLabel(
    AgentRunMetrics? metrics,
    String? finalOutcome,
    AiStrings strings,
  ) {
    if (finalOutcome != null) return _finalOutcomeLabel(finalOutcome, strings);
    if (metrics == null) return strings.unknown;
    return metrics.success
        ? strings.agentTraceStatusSuccess
        : strings.agentTraceStatusFailed;
  }

  /// 状态色只表达结果，不做装饰：成功绿、失败红、拦截/审批类琥珀、取消灰。
  static Color _statusColor(
    BuildContext context,
    AgentRunMetrics? metrics,
    String? finalOutcome,
  ) {
    final status = AppStatusColors.of(context);
    if (finalOutcome != null) {
      switch (finalOutcome) {
        case 'success':
        case 'completed':
          return status.success;
        case 'cancelled':
          return status.neutral;
        case 'modelError':
        case 'toolError':
          return status.error;
        default:
          return status.warning;
      }
    }
    if (metrics == null) return status.neutral;
    return metrics.success ? status.success : status.error;
  }

  static String _elapsed(
    AgentRunMetrics? metrics,
    Map<String, dynamic> summary,
  ) {
    final value = metrics?.elapsedMs ?? summary['elapsedMs'];
    if (value is int) return _formatDuration(Duration(milliseconds: value));
    final started = DateTime.tryParse('${summary['startedAt'] ?? ''}');
    final finished = DateTime.tryParse('${summary['finishedAt'] ?? ''}');
    if (started != null && finished != null) {
      return _formatDuration(finished.difference(started));
    }
    return '-';
  }

  static int _totalTokens(Map<String, dynamic> summary) {
    final total = summary['totalTokens'];
    if (total is int) return total;
    final prompt = summary['promptTokens'];
    final completion = summary['completionTokens'];
    return (prompt is int ? prompt : 0) + (completion is int ? completion : 0);
  }

  static int _countKind(List<AgentTraceEvent> events, String kind) {
    return events.where((event) => event.kind == kind).length;
  }

  static List<String> _stringList(Object? value) {
    if (value is List) {
      return value
          .whereType<Object>()
          .map((item) => '$item')
          .where((item) => item.trim().isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }
}

class _FilterBar extends StatelessWidget {
  final _TraceFilter selected;
  final ValueChanged<_TraceFilter> onSelected;
  final AiStrings strings;

  const _FilterBar({
    required this.selected,
    required this.onSelected,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final typography = context.typography;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final value in _TraceFilter.values)
          ChoiceChip(
            key: ValueKey('trace-filter-${value.name}'),
            label: Text(_filterLabel(value, strings)),
            selected: selected == value,
            onSelected: (_) => onSelected(value),
            showCheckmark: false,
            avatar: Icon(
              _filterIcon(value),
              size: 15,
              color: selected == value
                  ? colorScheme.onSecondaryContainer
                  : colorScheme.onSurfaceVariant,
            ),
            labelStyle: typography.button.copyWith(
              color: selected == value
                  ? colorScheme.onSecondaryContainer
                  : colorScheme.onSurfaceVariant,
              fontWeight: selected == value ? FontWeight.w600 : FontWeight.w500,
            ),
            backgroundColor: colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.35,
            ),
            selectedColor: colorScheme.secondaryContainer,
            side: BorderSide.none,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            ),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            visualDensity: VisualDensity.standard,
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
      ],
    );
  }
}

IconData _filterIcon(_TraceFilter value) {
  switch (value) {
    case _TraceFilter.all:
      return Icons.format_list_bulleted_rounded;
    case _TraceFilter.tools:
      return Icons.build_outlined;
    case _TraceFilter.approvals:
      return Icons.verified_user_outlined;
    case _TraceFilter.blocked:
      return Icons.block;
    case _TraceFilter.errors:
      return Icons.error_outline;
  }
}

/// 指标单元：扁平等高块，标签弱化、数值加重，避免一排描边胶囊抢焦点。
class _MetricPill extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _MetricPill(this.label, this.value, {this.valueColor});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final typography = context.typography;
    final maxWidth = (MediaQuery.sizeOf(context).width - 32)
        .clamp(140.0, 360.0)
        .toDouble();
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.38),
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: 5,
          ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$label: ',
                  style: typography.caption.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                TextSpan(
                  text: value,
                  style: typography.metadata.copyWith(
                    fontWeight: FontWeight.w600,
                    color: valueColor ?? colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class _SmallLabel extends StatelessWidget {
  final String label;
  final String value;

  const _SmallLabel(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final typography = context.typography;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: typography.metadata.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            TextSpan(
              text: value,
              style: typography.metadata.copyWith(
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _EmptyTrace extends StatelessWidget {
  final String runId;
  final AiStrings strings;

  const _EmptyTrace({required this.runId, required this.strings});

  @override
  Widget build(BuildContext context) {
    return AppEmptyState(
      icon: Icons.account_tree_outlined,
      title: strings.agentTraceEmptyTitle,
      message: runId,
      compact: true,
      contained: false,
    );
  }
}

String _filterLabel(_TraceFilter value, AiStrings strings) {
  switch (value) {
    case _TraceFilter.all:
      return strings.agentTraceFilterAll;
    case _TraceFilter.tools:
      return strings.agentTraceFilterTools;
    case _TraceFilter.approvals:
      return strings.agentTraceFilterApprovals;
    case _TraceFilter.blocked:
      return strings.agentTraceFilterBlocked;
    case _TraceFilter.errors:
      return strings.agentTraceFilterErrors;
  }
}

String _formatDuration(Duration duration) {
  final ms = duration.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  return '${(ms / 1000).toStringAsFixed(1)}s';
}

String _finalOutcomeLabel(String value, AiStrings strings) {
  switch (value) {
    case 'success':
    case 'completed':
    case 'cancelled':
    case 'modelError':
    case 'toolError':
    case 'approvalRejected':
    case 'approvalUnavailable':
    case 'budgetAuditRejected':
    case 'loopGuardBlocked':
    case 'planModeBlocked':
    case 'planExecutionBlocked':
    case 'agentLoopStopped':
      return strings.agentTraceOutcomeLabel(value);
    default:
      return value;
  }
}
