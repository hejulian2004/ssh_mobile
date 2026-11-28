import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:feature_ai/src/chat/views/widgets/ai_strings.dart';
import 'package:app_ui/app_ui.dart';

/// Agent 轨迹台账的发丝分隔线：与聊天消息运行台账同一分隔语言。
class TraceLedgerRule extends StatelessWidget {
  const TraceLedgerRule({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: Theme.of(
        context,
      ).colorScheme.outlineVariant.withValues(alpha: 0.4),
    );
  }
}

/// 轨迹事件行：扁平列表语言（发丝线 + 语义色图标 + 可展开原文）。
///
/// 与聊天消息台账里的「执行详情」条目一致，不再逐条套描边卡片；
/// 原文区固定在一个 280dp 的滚动块内，复制按钮保持 48dp 触控目标。
class TraceTimelineItem extends StatelessWidget {
  final AgentTraceEvent event;

  /// 相对运行起点的偏移文案，例如 `+1.2s`；由调用方格式化。
  final String offsetLabel;
  final AiStrings strings;
  final bool isFirst;
  final bool isLast;

  const TraceTimelineItem({
    super.key,
    required this.event,
    required this.offsetLabel,
    required this.strings,
    this.isFirst = false,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final typography = context.typography;
    final preview = traceEventPreview(event.content);
    final meta = [
      offsetLabel,
      event.kind,
      if (event.status.isNotEmpty) event.status,
      if (event.toolName?.trim().isNotEmpty == true) event.toolName!,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isFirst) const TraceLedgerRule(),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: PageStorageKey<String>('trace-expansion-${event.id}'),
            minTileHeight: 48,
            tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            childrenPadding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.md,
            ),
            iconColor: colorScheme.onSurfaceVariant,
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            expandedAlignment: Alignment.centerLeft,
            leading: Icon(
              _iconForKind(event.kind),
              size: 16,
              color: _colorForEvent(colorScheme, event),
            ),
            title: Text(
              '${event.sequence}. ${event.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typography.bodyMedium.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typography.caption.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                if (preview.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: typography.codeSmall.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
              ],
            ),
            children: [
              Wrap(
                alignment: WrapAlignment.start,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.sm,
                children: [
                  TextButton.icon(
                    key: ValueKey('trace-copy-${event.id}'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                      ),
                    ),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: event.content));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(strings.agentTraceCopied)),
                      );
                    },
                    icon: const Icon(Icons.copy_outlined, size: 15),
                    label: Text(strings.agentTraceCopyRaw),
                  ),
                  if (event.truncated)
                    Text(
                      strings.agentTraceTruncated,
                      style: typography.metadata.copyWith(
                        color: colorScheme.error,
                      ),
                    ),
                ],
              ),
              _TraceRawContent(
                key: ValueKey('trace-raw-content-${event.id}'),
                event: event,
              ),
            ],
          ),
        ),
        if (isLast) const TraceLedgerRule(),
      ],
    );
  }
}

class _TraceRawContent extends StatefulWidget {
  final AgentTraceEvent event;

  const _TraceRawContent({super.key, required this.event});

  @override
  State<_TraceRawContent> createState() => _TraceRawContentState();
}

class _TraceRawContentState extends State<_TraceRawContent> {
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
    final colorScheme = Theme.of(context).colorScheme;
    final typography = context.typography;
    return Container(
      key: ValueKey('trace-raw-${widget.event.id}'),
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 280),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Scrollbar(
        controller: _verticalController,
        child: SingleChildScrollView(
          controller: _verticalController,
          child: OverflowScrollText(
            widget.event.content,
            style: typography.codeSmall.copyWith(
              height: 1.35,
              color: colorScheme.onSurface.withValues(alpha: 0.86),
            ),
          ),
        ),
      ),
    );
  }
}

/// 事件原文的单行预览：折叠态也要能读出关键信息，因此保留换行压平逻辑。
String traceEventPreview(String value) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.length <= 220) return normalized;
  return '${normalized.substring(0, 220)}...';
}

IconData _iconForKind(String kind) {
  if (kind == 'tool_exposure') return Icons.inventory_2_outlined;
  if (kind == 'multi_agent' || kind.contains('multi_agent')) {
    return Icons.groups_outlined;
  }
  if (kind == 'tool_request') return Icons.build_circle_outlined;
  if (kind == 'tool_result') return Icons.fact_check_outlined;
  if (kind == 'approval') return Icons.verified_user_outlined;
  if (kind == 'tool_blocked' || kind.contains('blocked')) {
    return Icons.shield_outlined;
  }
  if (kind == 'budget' || kind.contains('audit')) return Icons.warning_amber;
  if (kind == 'agent_run_summary') return Icons.analytics_outlined;
  if (kind == 'error') return Icons.error_outline;
  if (kind.contains('compression')) return Icons.compress_outlined;
  return Icons.info_outline;
}

Color _colorForEvent(ColorScheme colorScheme, AgentTraceEvent event) {
  final status = event.status.toLowerCase();
  if (status.contains('error') ||
      status.contains('failed') ||
      status.contains('rejected')) {
    return colorScheme.error;
  }
  if (status.contains('blocked') || status.contains('unavailable')) {
    return colorScheme.tertiary;
  }
  if (event.kind.contains('tool')) return colorScheme.primary;
  if (event.kind.contains('approval')) return colorScheme.secondary;
  return colorScheme.onSurfaceVariant;
}
