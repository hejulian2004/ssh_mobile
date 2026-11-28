part of 'message_bubble.dart';

class _AssistantMarkdownBody extends StatelessWidget {
  final String text;
  final ValueListenable<String>? streamingTextListenable;
  final ValueListenable<String>? streamingStatusListenable;

  const _AssistantMarkdownBody({
    required this.text,
    this.streamingTextListenable,
    this.streamingStatusListenable,
  });

  String _cleanTextForMarkdown(String text, BuildContext context) {
    final isEn = context.read<AppSettings>().language == AppLanguage.en;
    return text.replaceAll(
      RegExp(r'```playbook\s*\{[\s\S]*?\}\s*```'),
      isEn
          ? '\n\n*📋 Operational plan steps generated below. Please select a target server first, then execute step-by-step:*'
          : '\n\n*📋 规划的运维步骤已在下方可视化生成，请先选择目标服务器后点击运行：*',
    );
  }

  @override
  Widget build(BuildContext context) {
    final listenable = streamingTextListenable;
    if (listenable == null) {
      return _buildMarkdown(context, _cleanTextForMarkdown(text, context));
    }
    return ValueListenableBuilder<String>(
      valueListenable: listenable,
      builder: (context, value, _) => ValueListenableBuilder<String>(
        valueListenable: streamingStatusListenable ?? emptyStringListenable,
        builder: (context, status, _) {
          final displayText = value.isEmpty ? text : value;
          final hasText = displayText.trim().isNotEmpty;
          final label = status.trim();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (label.isNotEmpty || !hasText)
                AssistantRunIndicator(
                  label: label.isEmpty ? '...' : label,
                  compact: hasText,
                ),
              if (hasText)
                Padding(
                  padding: EdgeInsets.only(top: label.isNotEmpty ? 8 : 0),
                  child: _buildMarkdown(
                    context,
                    _cleanTextForMarkdown(displayText, context),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMarkdown(BuildContext context, String value) {
    return GptMarkdown(
      value.isEmpty ? '...' : value,
      style: context.typography.body,
    );
  }
}
