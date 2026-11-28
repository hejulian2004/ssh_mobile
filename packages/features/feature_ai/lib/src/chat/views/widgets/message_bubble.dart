import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'package:feature_ai/src/chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:feature_playbook/feature_playbook.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'ai_strings.dart';
import 'package:feature_ai/src/agent/plan_execution_controller.dart';
import 'package:app_ui/app_ui.dart';
import 'package:feature_ai/src/chat/pages/agent_trace_debug_page.dart';
import 'trace_panel.dart';
import 'message_attachments_wrap.dart';

import '../llm_chat_screen.dart'; // For AiStrings/AiStrings extensions

part 'message_run_summary.dart';
part 'message_trace_link.dart';
part 'message_edit_dialog.dart';
part 'message_markdown_body.dart';
part 'message_actions.dart';
part 'message_todo_panel.dart';

class MessageBubble extends StatelessWidget {
  final String chatId;
  final int index;
  final AiChatMessageRecord message;
  final ValueListenable<String>? streamingTextListenable;
  final ValueListenable<String>? streamingStatusListenable;
  final bool canAct;
  final VoidCallback? onEditUser;
  final VoidCallback? onRegenerate;
  final VoidCallback? onBranch;
  final VoidCallback? onContinueTimeout;
  final VoidCallback? onRevisePlan;

  const MessageBubble({
    super.key,
    required this.chatId,
    required this.index,
    required this.message,
    this.streamingTextListenable,
    this.streamingStatusListenable,
    this.canAct = false,
    this.onEditUser,
    this.onRegenerate,
    this.onBranch,
    this.onContinueTimeout,
    this.onRevisePlan,
  });

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<AiChatViewModel>();
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AiStrings(language);

    final colorScheme = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    final isError = message.role == 'error';
    final isAssistant = !isUser && !isError;
    final canCopyAssistant = isAssistant && message.text.trim().isNotEmpty;
    final runId = message.agentRunId?.trim() ?? '';
    final hasRun = runId.isNotEmpty;
    final statsText = isAssistant && message.totalTokens != null
        ? _messageStats(message)
        : null;
    final showLedger =
        isAssistant &&
        (hasRun ||
            message.traces.isNotEmpty ||
            message.todoSteps.isNotEmpty ||
            statsText != null);

    return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (isUser || isError)
                  Container(
                    margin: const EdgeInsets.only(bottom: AppSpacing.xs),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.md,
                    ),
                    decoration: BoxDecoration(
                      color: isError
                          ? colorScheme.error.withValues(alpha: 0.07)
                          : colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadiusDirectional.only(
                        topStart: const Radius.circular(AppTheme.radiusLarge),
                        topEnd: const Radius.circular(AppTheme.radiusLarge),
                        bottomStart: const Radius.circular(
                          AppTheme.radiusLarge,
                        ),
                        bottomEnd: const Radius.circular(AppTheme.radiusSmall),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isUser && message.attachments.isNotEmpty)
                          MessageAttachmentsWrap(
                            attachments: message.attachments,
                            isEnglish: language == AppLanguage.en,
                          ),
                        SelectableText(
                          message.text.isEmpty ? '...' : message.text,
                          style: TextStyle(
                            color: isError
                                ? colorScheme.error
                                : colorScheme.onSurface,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                    ),
                    child: _AssistantMarkdownBody(
                      text: message.text,
                      streamingTextListenable: streamingTextListenable,
                      streamingStatusListenable: streamingStatusListenable,
                    ),
                  ),
                if (showLedger)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: _buildRunLedger(
                      context,
                      strings,
                      viewModel,
                      hasRun: hasRun,
                      runId: runId,
                      statsText: statsText,
                    ),
                  ),
                if (isError && hasRun) ...[
                  AgentRunInlineSummary(message: message),
                  _AgentTraceLink(
                    chatId: chatId,
                    runId: runId,
                    message: message,
                  ),
                ],
                if (canAct &&
                    (onEditUser != null ||
                        onRegenerate != null ||
                        onBranch != null ||
                        onContinueTimeout != null ||
                        canCopyAssistant))
                  MessageActions(
                    isUser: isUser,
                    isError: isError,
                    assistantText: isAssistant ? message.text : null,
                    onEditUser: onEditUser,
                    onRegenerate: onRegenerate,
                    onBranch: onBranch,
                    onContinueTimeout: onContinueTimeout,
                  ),
                const SizedBox(height: AppSpacing.sm),
              ],
            ),
          ),
        )
        .animate(
          key: ValueKey(
            'msg-animate-${message.createdAt.microsecondsSinceEpoch}',
          ),
        )
        .fade(duration: 150.ms);
  }

  /// Agent 运行台账：一次运行只有一个带描边的表面，内部段落以发丝线分隔。
  Widget _buildRunLedger(
    BuildContext context,
    AiStrings strings,
    AiChatViewModel viewModel, {
    required bool hasRun,
    required String runId,
    required String? statsText,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final sections = <Widget>[];

    void addSection(Widget section) {
      if (sections.isNotEmpty) {
        sections.add(
          Container(
            height: 1,
            color: colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        );
      }
      sections.add(section);
    }

    if (hasRun) {
      addSection(AgentRunInlineSummary(message: message));
    }
    if (message.todoSteps.isNotEmpty) {
      addSection(
        ChatTodoPanel(
          message: message,
          strings: strings,
          serverDisplayNameFor: (connectionId) =>
              viewModel.getConnection(connectionId)?.name,
          onRetryStep: viewModel.retryTodoStep,
          onSkipStep: viewModel.skipTodoStep,
          onRevisePlan: onRevisePlan,
        ),
      );
    }
    if (message.traces.isNotEmpty) {
      addSection(
        TracePanel(
          traces: message.traces,
          storageKey: 'trace-panel-${message.createdAt.microsecondsSinceEpoch}',
        ),
      );
    }
    final footer = _buildLedgerFooter(context, hasRun, runId, statsText);
    if (footer != null) {
      addSection(footer);
    }

    return Material(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.26),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: sections,
      ),
    );
  }

  /// 台账页脚：轨迹入口与 token 统计合并为一行元信息。
  Widget? _buildLedgerFooter(
    BuildContext context,
    bool hasRun,
    String runId,
    String? statsText,
  ) {
    if (!hasRun && statsText == null) return null;
    final colorScheme = Theme.of(context).colorScheme;
    final typography = context.typography;
    final link = hasRun
        ? _AgentTraceLink(chatId: chatId, runId: runId, message: message)
        : null;
    final stats = statsText == null
        ? null
        : Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  statsText,
                  maxLines: 1,
                  style: typography.caption.copyWith(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.72),
                  ),
                ),
              ),
            ),
          );
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Row(
        children: [
          if (link != null) Flexible(child: link),
          if (link != null && stats != null)
            const SizedBox(width: AppSpacing.sm),
          if (stats != null) stats,
        ],
      ),
    );
  }

  String _messageStats(AiChatMessageRecord message) {
    final parts = <String>[];
    if (message.totalTokens != null) {
      parts.add(
        '${message.tokenUsageEstimated == true ? 'est.' : 'API'} tokens ${message.totalTokens}',
      );
    }
    if (message.promptTokens != null || message.completionTokens != null) {
      parts.add(
        'in ${message.promptTokens ?? '-'} / out ${message.completionTokens ?? '-'}',
      );
    }
    if (message.elapsedMs != null &&
        message.agentRunId?.trim().isNotEmpty != true) {
      parts.add('time ${_formatElapsed(message.elapsedMs!)}');
    }
    if (message.promptCacheHitTokens != null ||
        message.promptCacheMissTokens != null) {
      parts.add(
        'cache ${message.promptCacheHitTokens ?? 0}/${message.promptCacheMissTokens ?? 0}',
      );
    }
    if (message.reasoningTokens != null && message.reasoningTokens! > 0) {
      parts.add('reasoning ${message.reasoningTokens}');
    }
    return parts.join(' · ');
  }

  String _formatElapsed(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }
}
