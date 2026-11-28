import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:app_ui/app_ui.dart';

class TracePanel extends StatelessWidget {
  final List<AiMessageTrace> traces;
  final String storageKey;

  const TracePanel({super.key, required this.traces, required this.storageKey});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final typography = context.typography;
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = _TracePanelStrings(language);
    return Material(
      type: MaterialType.transparency,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: PageStorageKey<String>(storageKey),
          tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          childrenPadding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            0,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          minTileHeight: 48,
          leading: Icon(
            Icons.account_tree_outlined,
            size: 16,
            color: colorScheme.onSurfaceVariant,
          ),
          title: Text(
            strings.executionDetails(traces.length),
            style: typography.metadata.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            for (var i = 0; i < traces.length; i++)
              _TraceEntry(
                key: ValueKey<String>('trace-entry-${traces[i].id}'),
                trace: traces[i],
                index: i + 1,
                isFirst: i == 0,
                storageKey: '$storageKey-entry-${traces[i].id}',
                strings: strings,
              ),
          ],
        ),
      ),
    );
  }
}

class _TraceEntry extends StatelessWidget {
  final AiMessageTrace trace;
  final int index;
  final bool isFirst;
  final String storageKey;
  final _TracePanelStrings strings;

  const _TraceEntry({
    super.key,
    required this.trace,
    required this.index,
    required this.isFirst,
    required this.storageKey,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final typography = context.typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isFirst)
          Container(
            height: 1,
            color: colorScheme.outlineVariant.withValues(alpha: 0.35),
          ),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: PageStorageKey<String>(storageKey),
            tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            childrenPadding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.md,
            ),
            minTileHeight: 48,
            leading: Icon(
              _traceIcon(trace.kind),
              size: 15,
              color: _traceColor(colorScheme, trace.kind),
            ),
            title: Text(
              '$index. ${strings.traceTitle(trace)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typography.metadata.copyWith(fontWeight: FontWeight.w500),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: _BoundedTraceContent(
                  traceId: trace.id,
                  content: trace.content.isEmpty ? '-' : trace.content,
                  style: typography.codeSmall.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.82),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  IconData _traceIcon(String kind) {
    switch (kind) {
      case 'reasoning':
        return Icons.psychology_alt_outlined;
      case 'rag_context':
        return Icons.auto_stories_outlined;
      case 'tool_request':
        return Icons.build_circle_outlined;
      case 'tool_result':
        return Icons.fact_check_outlined;
      case 'approval':
        return Icons.verified_user_outlined;
      case 'budget':
        return Icons.tune_rounded;
      default:
        return Icons.info_outline;
    }
  }

  Color _traceColor(ColorScheme colorScheme, String kind) {
    switch (kind) {
      case 'reasoning':
        return colorScheme.secondary;
      case 'rag_context':
        return colorScheme.tertiary;
      case 'tool_request':
        return colorScheme.primary;
      case 'tool_result':
        return colorScheme.tertiary;
      case 'approval':
        return colorScheme.error;
      case 'budget':
        return colorScheme.secondary;
      default:
        return colorScheme.onSurfaceVariant;
    }
  }
}

class _BoundedTraceContent extends StatefulWidget {
  const _BoundedTraceContent({
    required this.traceId,
    required this.content,
    required this.style,
  });

  final String traceId;
  final String content;
  final TextStyle? style;

  @override
  State<_BoundedTraceContent> createState() => _BoundedTraceContentState();
}

class _BoundedTraceContentState extends State<_BoundedTraceContent> {
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
    return ConstrainedBox(
      key: ValueKey<String>('trace-content-${widget.traceId}'),
      constraints: const BoxConstraints(maxHeight: 280),
      child: Scrollbar(
        controller: _verticalController,
        child: SingleChildScrollView(
          controller: _verticalController,
          child: OverflowScrollText(widget.content, style: widget.style),
        ),
      ),
    );
  }
}

class _TracePanelStrings {
  const _TracePanelStrings(this.language);

  final AppLanguage language;

  bool get _en => language == AppLanguage.en;

  String executionDetails(int count) =>
      _en ? 'Execution details ($count)' : '执行详情 ($count)';

  String traceTitle(AiMessageTrace trace) {
    switch (trace.kind) {
      case 'reasoning':
        return _en ? 'Deep reasoning' : '深度思考';
      case 'rag_context':
        return _en ? 'Knowledge context' : '知识库上下文';
      case 'tool_request':
        return _withDetail(
          _en ? 'Tool request' : '工具调用',
          _stripPrefix(trace.title, 'Tool request: '),
        );
      case 'tool_result':
        return _withDetail(
          _en ? 'Tool result' : '工具结果',
          _stripPrefix(trace.title, 'Tool result: '),
        );
      case 'approval':
        final approved = trace.title.toLowerCase().contains('approved');
        return approved
            ? (_en ? 'Tool operation approved' : '工具操作已同意')
            : (_en ? 'Tool operation rejected' : '工具操作已拒绝');
      case 'budget':
        final lowerTitle = trace.title.toLowerCase();
        if (lowerTitle.contains('running')) {
          return _en ? 'Budget Safety Audit' : '工具预算安全审计';
        }
        if (lowerTitle.contains('approved')) {
          return _en ? 'Budget Approved' : '工具预算审计通过';
        }
        if (lowerTitle.contains('rejected')) {
          return _en ? 'Budget Stopped' : '工具预算已停止';
        }
        return _en ? 'Budget Notice' : '工具预算提醒';
      default:
        return trace.title;
    }
  }

  String _stripPrefix(String value, String prefix) {
    return value.startsWith(prefix) ? value.substring(prefix.length) : value;
  }

  String _withDetail(String label, String detail) {
    final normalized = detail.trim();
    return normalized.isEmpty ? label : '$label - $normalized';
  }
}
