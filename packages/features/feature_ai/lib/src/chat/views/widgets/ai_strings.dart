import 'package:feature_ai/src/agent/agent_model_profile.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:feature_ai/src/llm/provider/llm_api_format.dart';
import 'package:feature_playbook/feature_playbook.dart';

/// AI 功能专用文案，避免 Feature 反向依赖 App Shell 的全局文案实现。

class AiStrings {
  final AppLanguage language;

  const AiStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get apiFormat => _en ? 'API Format' : 'API 协议格式';
  String get connectionAndModel => _en ? 'Connection & model' : '连接与模型';
  String get advancedModelOptions => _en ? 'Advanced model options' : '高级模型选项';
  String get agentBehavior => _en ? 'Agent behavior' : 'Agent 行为';
  String get reasoningSettings => _en ? 'Reasoning & thinking' : '推理与思考';
  String get searchTools => _en ? 'Search tools' : '搜索工具';
  String get knowledgeBaseSettings => _en ? 'Knowledge base' : '知识库';
  String get uploadLimits => _en ? 'Upload limits' : '上传限制';
  String get apiFormatUnsupported => _en
      ? 'API format unsupported. Switched to OpenAI.'
      : '所选 API 格式暂不支持，已切换回 OpenAI Chat Completions。';
  String get recommendedBaseUrl => _en ? 'Recommended' : '推荐值';
  String get useRecommendedBaseUrl => _en ? 'Use Recommended' : '使用推荐值';
  String apiFormatLabel(LlmApiFormat format) {
    switch (format) {
      case LlmApiFormat.openAiChatCompletions:
        return 'OpenAI Chat Completions';
      case LlmApiFormat.openAiResponses:
        return 'OpenAI Responses';
      case LlmApiFormat.anthropicMessages:
        return 'Anthropic Messages';
      case LlmApiFormat.geminiNative:
        return 'Gemini Native';
      case LlmApiFormat.geminiOpenAiCompatible:
        return 'Gemini OpenAI-compatible';
    }
  }

  String get title => _en ? 'LLM Assistant' : '大模型助手';
  String get welcome => _en
      ? 'Ask me about servers, logs, or remote files.'
      : '可以问我服务器状态、日志、远程文件等。';
  String get welcomeTitle => _en ? 'What can I help with?' : '今天想处理什么？';
  String get chatBootstrapFailedTitle =>
      _en ? 'Unable to open AI chat' : '无法打开 AI 对话';
  String get chatBootstrapFailedMessage =>
      _en ? 'Failed to load chat settings. Try again.' : '无法读取对话设置，请检查本地存储后重试。';
  String get retry => _en ? 'Retry' : '重试';
  String get checkServersSuggestion => _en ? 'Check server health' : '检查服务器状态';
  String get checkServersPrompt =>
      _en ? 'Check servers and highlight issues.' : '检查我的服务器，并指出需要关注的问题。';
  String get reviewLogsSuggestion => _en ? 'Review recent logs' : '查看近期日志';
  String get reviewLogsPrompt =>
      _en ? 'Review recent logs and summarize errors.' : '查看近期日志，并总结重要的错误或警告。';
  String get remoteFileSuggestion => _en ? 'Work with a remote file' : '处理远程文件';
  String get remoteFilePrompt =>
      _en ? 'Help me view or edit a remote file.' : '帮我检查或更新远程服务器上的文件。';
  String get composerHint =>
      _en ? 'Ask a question, or type / for commands' : '描述任务，或输入 / 查看命令';
  String get history => _en ? 'Chat history' : '聊天历史';
  String get loading => _en ? 'Loading...' : '正在加载...';
  String get newChat => _en ? 'New chat' : '新聊天';
  String get delete => _en ? 'Delete' : '删除';
  String get deleteChatTitle => _en ? 'Delete chat?' : '删除对话？';
  String deleteChatContent(String title) => _en
      ? 'Delete "$title"? This action cannot be undone.'
      : '确定删除“$title”吗？此操作不可恢复。';
  String get regenerateReplyTitle =>
      _en ? 'Regenerate this reply?' : '确认重新生成这条回复吗？';
  String get regenerateReplyMessage => _en
      ? 'This deletes this reply and subsequent messages, then regenerates.'
      : '这会删除当前回复及其后的所有消息，并从该位置重新生成。';
  String get regenerateReplyAction => _en ? 'Regenerate' : '重新生成';
  String get createBranchTitle => _en ? 'Create a chat branch?' : '确认创建聊天分支吗？';
  String get createBranchMessage => _en
      ? 'Creates a new chat branch from this message.'
      : '这会从当前消息创建新对话，之后可独立继续。';
  String get createBranchAction => _en ? 'Create branch' : '创建分支';
  String get deleteBaseUrlHistoryTitle =>
      _en ? 'Delete history entry?' : '删除历史记录？';
  String deleteBaseUrlHistoryContent(String baseUrl) => _en
      ? 'Delete this Base URL history entry?\n$baseUrl'
      : '确定删除这个 Base URL 历史记录吗？\n$baseUrl';
  String get deleteApiKeyHistoryTitle =>
      _en ? 'Delete API key history?' : '删除 API Key 历史？';
  String deleteApiKeyHistoryContent(String maskedValue) => _en
      ? 'Delete this API key history entry?\n$maskedValue'
      : '确定删除这个 API Key 历史记录吗？\n$maskedValue';
  String get appSettings => _en ? 'App settings' : '应用设置';
  String get settings => _en ? 'LLM settings' : '大模型设置';
  String get settingsOpenFailed =>
      _en ? 'Unable to open LLM settings. Try again.' : '无法打开大模型设置，请重试。';
  String get settingsApplyFailed => _en
      ? 'Settings were saved, but the active chat could not update. Try again or start a new chat.'
      : '设置已保存，但当前对话未能更新。请重试或新建对话。';
  String get settingsSaveFailed => _en
      ? 'Unable to save LLM settings. Check the values and try again.'
      : '无法保存大模型设置，请检查填写内容后重试。';
  String get discardSettingsTitle =>
      _en ? 'Discard settings changes?' : '放弃设置更改？';
  String get discardSettingsContent =>
      _en ? 'Your LLM settings changes have not been saved.' : '大模型设置中的更改尚未保存。';
  String get discardChanges => _en ? 'Discard changes' : '放弃更改';
  String get send => _en ? 'Send' : '发送';
  String get branch => _en ? 'Branch' : '分支';
  String get executeApprovedPlan =>
      _en ? 'Execute the approved plan.' : '执行已批准的计划。';
  String get copyReply => _en ? 'Copy reply' : '复制回复';
  String get selectAndCopy => _en ? 'Select and copy' : '选择复制';
  String get editAndResend => _en ? 'Edit and resend' : '编辑并重发';
  String get regenerate => _en ? 'Regenerate' : '重新生成';
  String get createBranch => _en ? 'Create branch' : '创建分支';
  String get continue_ => _en ? 'Continue' : '继续生成';
  String get replyCopied => _en ? 'Reply copied' : '已复制回复';
  String get copyAll => _en ? 'Copy all' : '复制全文';
  String removeAttachmentNamed(String name) =>
      _en ? 'Remove attachment $name' : '移除附件 $name';
  String previewImage(String name) =>
      _en ? 'Preview image $name' : '预览图片 $name';
  String imagePreviewUnavailable(String name) =>
      _en ? 'Image preview unavailable for $name' : '图片预览不可用 $name';
  String get trace => _en ? 'Trace' : '轨迹';
  String traceEvents(int count) => _en ? '$count events' : '$count 个事件';
  String traceTools(int count) => _en ? '$count tools' : '$count 个工具';
  String traceApprovals(int count) => _en ? '$count approvals' : '$count 次审批';
  String get agentTraceTitle => _en ? 'Agent Trace' : 'Agent 执行轨迹';
  String get agentTraceLoadFailedTitle =>
      _en ? 'Failed to load trace' : '无法加载执行轨迹';
  String get agentTraceLoadFailedMessage =>
      _en ? 'Trace data could not be loaded. Try again.' : '无法读取执行轨迹数据，请重试。';
  String get agentTraceOverview => _en ? 'Overview' : '执行概览';
  String agentTraceEventCount(int count) =>
      _en ? '$count events' : '$count 个事件';
  String get agentTraceNoMatchingTitle =>
      _en ? 'No matching events' : '没有匹配的事件';
  String get agentTraceNoMatchingMessage =>
      _en ? 'No events match this filter.' : '当前筛选条件下没有事件。';
  String get agentTraceEmptyTitle =>
      _en ? 'No persisted trace events found for this run.' : '未找到本次运行保存的执行轨迹。';
  String get agentTraceFilterAll => _en ? 'All' : '全部';
  String get agentTraceFilterTools => _en ? 'Tools' : '工具';
  String get agentTraceFilterApprovals => _en ? 'Approvals' : '审批';
  String get agentTraceFilterBlocked => _en ? 'Blocked' : '已拦截';
  String get agentTraceFilterErrors => _en ? 'Errors' : '错误';
  String get agentTraceMetricStatus => _en ? 'Status' : '状态';
  String get agentTraceMetricRun => _en ? 'Run' : '运行 ID';
  String get agentTraceMetricModel => _en ? 'Model' : '模型';
  String get agentTraceMetricHelper => _en ? 'Helper' : '辅助模型';
  String get agentTraceMetricAudit => _en ? 'Audit' : '审计模型';
  String get agentTraceMetricElapsed => _en ? 'Elapsed' : '耗时';
  String get agentTraceMetricPrompt => _en ? 'Prompt' : '输入 Token';
  String get agentTraceMetricCompletion => _en ? 'Completion' : '输出 Token';
  String get agentTraceMetricTotal => _en ? 'Total' : '总 Token';
  String get agentTraceMetricTools => _en ? 'Tools' : '工具调用';
  String get agentTraceMetricCacheHits => _en ? 'Cache hits' : '缓存命中';
  String get agentTraceMetricDedupBlocked => _en ? 'Dedup blocked' : '去重拦截';
  String get agentTraceMetricApprovals => _en ? 'Approvals' : '审批';
  String get agentTraceMetricApproved => _en ? 'Approved' : '已批准';
  String get agentTraceMetricAudits => _en ? 'Audits' : '安全审计';
  String get agentTraceMetricHelperFanout => _en ? 'Helper fanout' : '辅助 Agent';
  String get agentTraceSelectedTools => _en ? 'Selected tools' : '已选工具';
  String get agentTraceMemorySources => _en ? 'Memory sources' : '记忆来源';
  String get agentTraceFinalReason => _en ? 'Final reason' : '最终原因';
  String get agentTraceCopyRaw => _en ? 'Copy raw' : '复制原始内容';
  String get agentTraceCopied => _en ? 'Trace content copied' : '已复制轨迹原始内容';
  String get agentTraceTruncated => _en ? 'truncated' : '已截断';
  String get agentTraceStatusSuccess => _en ? 'Success' : '成功';
  String get agentTraceStatusFailed => _en ? 'Failed' : '失败';
  String get agentRunCompleted => _en ? 'Run completed' : '运行完成';
  String get agentRunNeedsAttention => _en ? 'Run needs attention' : '运行需处理';
  String agentRunTools(int count) =>
      _en ? '$count ${count == 1 ? 'tool' : 'tools'}' : '$count 个工具';
  String agentRunApprovals(int approved, int total) =>
      _en ? '$approved/$total approvals' : '$approved/$total 次审批';
  String agentRunBlocked(int count) => _en ? '$count blocked' : '$count 次阻断';
  String get agentTraceOutcomeCancelled => _en ? 'Cancelled by user' : '用户已取消';
  String get agentTraceOutcomeModelError =>
      _en ? 'Model request failed' : '模型请求失败';
  String get agentTraceOutcomeToolError =>
      _en ? 'Tool execution failed' : '工具执行失败';
  String get agentTraceOutcomeApprovalRejected =>
      _en ? 'User rejected approval' : '用户拒绝审批';
  String get agentTraceOutcomeApprovalUnavailable =>
      _en ? 'Approval UI unavailable' : '审批界面不可用';
  String get agentTraceOutcomeBudgetAuditRejected =>
      _en ? 'Tool budget audit rejected' : '工具预算审计未通过';
  String get agentTraceOutcomeLoopGuardBlocked =>
      _en ? 'Tool loop guard blocked execution' : '工具循环保护已拦截执行';
  String get agentTraceOutcomePlanModeBlocked =>
      _en ? 'Plan Mode blocked execution' : '规划模式已拦截执行';
  String get agentTraceOutcomePlanExecutionBlocked =>
      _en ? 'Plan execution gate blocked execution' : '计划执行门禁已拦截执行';
  String get agentTraceOutcomeAgentLoopStopped =>
      _en ? 'Agent loop stopped' : 'Agent 循环已停止';
  String get agentTraceOutcomeUnknown =>
      _en ? 'Run ended with an unknown result' : '运行结果未知';
  String agentTraceOutcomeLabel(String value) {
    switch (value.trim()) {
      case 'success':
      case 'completed':
        return agentTraceStatusSuccess;
      case 'cancelled':
        return agentTraceOutcomeCancelled;
      case 'modelError':
        return agentTraceOutcomeModelError;
      case 'toolError':
        return agentTraceOutcomeToolError;
      case 'approvalRejected':
        return agentTraceOutcomeApprovalRejected;
      case 'approvalUnavailable':
        return agentTraceOutcomeApprovalUnavailable;
      case 'budgetAuditRejected':
        return agentTraceOutcomeBudgetAuditRejected;
      case 'loopGuardBlocked':
        return agentTraceOutcomeLoopGuardBlocked;
      case 'planModeBlocked':
        return agentTraceOutcomePlanModeBlocked;
      case 'planExecutionBlocked':
        return agentTraceOutcomePlanExecutionBlocked;
      case 'agentLoopStopped':
        return agentTraceOutcomeAgentLoopStopped;
      default:
        return agentTraceOutcomeUnknown;
    }
  }

  String get unknown => _en ? 'Unknown' : '未知';
  String get stop => _en ? 'Stop' : '停止';
  String get jumpToLatestMessage => _en ? 'Jump to latest message' : '跳转到最新消息';
  String get stopped => _en ? '[Stopped by user]' : '[用户已终止]';
  String get baseUrl => _en ? 'Base URL' : 'Base URL';
  String get baseUrlHistory => _en ? 'Base URL history' : 'Base URL 历史';
  String get noBaseUrlHistory =>
      _en ? 'No saved Base URLs yet' : '还没有保存过 Base URL';
  String get model => _en ? 'Model' : '模型';
  String get helperModel => _en ? 'Helper model (optional)' : '辅助模型（可选）';
  String get helperModelHint => _en
      ? 'Used for helper agents. Leave blank to reuse main model.'
      : '用于 helper agent 和快速分类。留空时回退到主模型。';
  String get auditModel => _en ? 'Audit model (optional)' : '审计模型（可选）';
  String get auditModelHint => _en
      ? 'Used for tool-safety audits. Leave blank to reuse main model.'
      : '用于工具预算审计和安全检查。留空时回退到主模型。';
  String get modelFallbackPolicy => _en ? 'Secondary model policy' : '副模型策略';
  String modelFallbackPolicyLabel(String value) {
    switch (AgentModelFallbackPolicy.normalize(value)) {
      case AgentModelFallbackPolicy.mainOnly:
        return _en ? 'Always use main model' : '始终使用主模型';
      case AgentModelFallbackPolicy.fallbackToMain:
      default:
        return _en ? 'Fallback to main model' : '缺失时回退到主模型';
    }
  }

  String get refreshModels => _en ? 'Refresh models' : '刷新模型';
  String get requestTimeout => _en ? 'Request timeout' : '请求超时';
  String get deepSeekThinking => _en ? 'DeepSeek thinking' : 'DeepSeek 思考模式';
  String get deepSeekThinkingHint => _en
      ? 'Applies to DeepSeek API. Disable for faster simple replies.'
      : '仅在 DeepSeek API 地址下发送。关闭后简单回复会更快。';
  String get deepSeekReasoningEffort =>
      _en ? 'DeepSeek reasoning effort' : 'DeepSeek 思考强度';
  String get webSearch => _en ? 'Local web search' : '本地网络搜索';
  String get webSearchHint => _en
      ? 'Enables web search using local WebView. No API key needed.'
      : '通过当前聊天绑定的本机 WebView 给模型提供 web_search 工具，不需要搜索 API Key。';
  String get ragTitle => _en ? 'RAG Ops Knowledge Base' : 'RAG 运维知识库';
  String get ragSettings => _en ? 'Knowledge retrieval' : '知识检索';
  String get ragHint => _en
      ? 'Retrieve offline context from manuals based on query.'
      : '根据问题自动在本地检索运维手册与文档，并作为参考上下文喂给 AI 助手。';
  String get ragManage => _en ? 'Manage Knowledge Base' : '管理运维知识库';
  String get ragSearchMode => _en ? 'Retrieval Mode' : '检索模式';
  String get ragSearchModeBm25 =>
      _en ? 'Keywords (BM25 - Offline)' : '本地关键词检索 (BM25 - 完全离线)';
  String get ragSearchModeVector =>
      _en ? 'Semantic Vector (Aliyun DashScope)' : '语义向量检索 (Vector - 通义向量)';
  String get ragSearchModeHybrid =>
      _en ? 'Hybrid RRF (Recommended)' : '双模混合检索 (Hybrid - 推荐效果最好)';
  String get ragSearchModeNeedKey => _en
      ? '⚠️ Semantic & Hybrid modes require Aliyun API Key configured in Knowledge Base settings.'
      : '⚠️ 语义向量与混合检索模式需要在下方“管理运维知识库”中配置阿里云 API 密钥。';
  String get ragTopN =>
      _en ? 'Retrieval Context Count (Top N)' : '知识库参考段数 (Top N)';
  String ragTopNValue(int value) => _en ? '$value chunks' : '$value 个参考段';
  String get webSearchMaxResults => _en ? 'Search results per call' : '每次搜索结果数';
  String get webSearchEngine => _en ? 'Web search engine' : '搜索引擎';

  String webSearchEngineLabel(String value) {
    switch (value) {
      case 'google':
        return _en ? 'Google' : '谷歌 (Google)';
      case 'bing':
        return _en ? 'Bing' : '必应 (Bing)';
      case 'baidu':
        return _en ? 'Baidu' : '百度 (Baidu)';
      case 'quark':
        return _en ? 'Quark Cloud (Aliyun)' : '阿里云夸克 (Quark Cloud)';
      case 'duckduckgo':
      default:
        return _en ? 'DuckDuckGo' : 'DuckDuckGo';
    }
  }

  String get quarkApiKeySaved =>
      _en ? 'Quark API Key (saved, leave blank)' : '夸克 API Key（已保存，留空不改）';
  String get quarkApiKeyRequired => _en ? 'Quark API Key' : '夸克 API Key';
  String get quarkApiKeyReplaceHint => _en
      ? 'Enter Aliyun Quark Search API Key to replace the saved one.'
      : '输入阿里云夸克搜索 API Key。留空保留已保存的 Key。';
  String get quarkSearchEndpoint =>
      _en ? 'Quark Search Endpoint' : '夸克搜索 API 地址';
  String get quarkSearchEndpointHint => _en
      ? 'Alibaba Cloud DashScope or Model Studio Quark search API endpoint.'
      : '阿里云百炼/DashScope 夸克搜索服务接口地址。';

  String get multiAgent => _en ? 'Multi-agent collaboration' : '多 Agent 协作';
  String get multiAgentHint => _en
      ? 'Ask helper agents to plan and review complex tasks.'
      : '复杂任务前自动让辅助 Agent 规划、建议安全操作并检查风险。';
  String get multiAgentMaxAgents =>
      _en ? 'Maximum helper agents' : '最大辅助 Agent 数';
  String get toolCallBudget => _en ? 'Tool call budget' : '工具调用预算';
  String get toolCallBudgetHint => _en
      ? 'Limits tool calls per request. First limit hit auto-extends.'
      : '按单次请求计数，首次达到预算会自动增加一半；后续每次扩容都需要内部安全审计。';
  String get budgetAuditTitle =>
      _en ? 'Confirm continued tool use' : '确认连续调用工具授权';
  String get budgetAuditReason => _en
      ? 'The AI assistant has performed 3 automated safety audits. Do you want to allow it to continue using tools?'
      : 'AI 助手已自动进行了 3 次安全审计。您是否允许其继续调用工具？';
  String get maxImageSize => _en ? 'Image upload size limit' : '图片上传大小限制';
  String get maxFileSize => _en ? 'File upload size limit' : '文件上传大小限制';
  String imageTooLarge(String name, String limit) => _en
      ? 'Image "$name" exceeds the $limit limit.'
      : '图片「$name」超过 $limit 限制。';
  String fileTooLarge(String name, String limit) =>
      _en ? 'File "$name" exceeds the $limit limit.' : '文件「$name」超过 $limit 限制。';
  String get openAiReasoningEffort =>
      _en ? 'OpenAI reasoning effort' : 'OpenAI 思考强度';
  String get openAiReasoningHint => _en
      ? 'Used for supported OpenAI reasoning models such as GPT-5 and o-series.'
      : '用于支持的 OpenAI 推理模型，例如 GPT-5 和 o 系列。';
  String get continueAfterTimeoutPrompt => _en
      ? 'Continue the previous answer. If a server command timed out, narrow the scope and continue with a smaller diagnostic step.'
      : '继续上一次回答。如果服务器命令超时，请缩小范围，用更小的诊断步骤继续。';
  String modelsFailed(String error) =>
      _en ? 'Unable to load models: $error' : '无法加载模型：$error';
  String savedCount(int count) => _en ? '$count saved' : '已保存 $count 条';
  String get apiKeySaved =>
      _en ? 'API Key (saved, leave blank)' : 'API Key（已保存，留空不改）';
  String get apiKeyRequired => _en ? 'API Key' : 'API Key';
  String get apiKeyHistory => _en ? 'API key history' : 'API Key 历史';
  String get noApiKeyHistory =>
      _en ? 'No saved API keys yet' : '还没有保存过 API Key';
  String get apiKeyReplaceHint => _en
      ? 'Leave this blank to keep the saved key, or enter a new key to replace it.'
      : '留空会保留已保存的 Key，输入新 Key 会替换当前 Key。';
  String get apiKeyHistoryHint => _en
      ? 'Choose a saved key from history, or enter a new one to add it.'
      : '可从历史中选择已保存 Key，或输入新 Key 后保存新增。';
  String apiKeySelected(String maskedValue) =>
      _en ? 'Current saved key: $maskedValue' : '当前已保存 Key：$maskedValue';
  String apiKeyMaskedPreview(String maskedValue) =>
      _en ? 'Selected key: $maskedValue' : '当前选择的 Key：$maskedValue';
  String get apiKeyClearPending => _en
      ? 'The saved API key will be removed when you save.'
      : '保存后会清除当前已保存的 API Key。';
  String get clearSavedApiKey => _en ? 'Clear saved API key' : '清除已保存的 API Key';
  String get keepSavedApiKey => _en ? 'Keep saved API key' : '保留已保存的 API Key';
  String get close => _en ? 'Close' : '关闭';
  String get cancel => _en ? 'Cancel' : '取消';
  String get save => _en ? 'Save' : '保存';
  String failed(Object error) => _en ? 'Failed: $error' : '失败：$error';
  String get commands => _en ? 'Commands' : '命令';
  String get planMode => _en ? 'Plan Mode' : '规划模式';
  String get planModeReadOnlyHint =>
      _en ? 'Read-only analysis and planning' : '仅进行只读分析与规划';
  String get planModeDisableAction => _en ? 'Turn off Plan Mode' : '关闭规划模式';
  String get planModeRemoveCommand =>
      _en ? 'Remove the Plan Mode command' : '移除规划模式命令';
  String planModeUpdated(bool enabled) => _en
      ? (enabled ? 'Plan Mode enabled.' : 'Plan Mode disabled.')
      : (enabled ? '规划模式已启用。' : '规划模式已关闭。');
  String get planModeUpdateFailed =>
      _en ? 'Unable to update Plan Mode. Try again.' : '无法更新规划模式，请重试。';
  String get planModeTargetChanged => _en
      ? 'The active chat changed. Try again in the current chat.'
      : '当前对话已切换，请在当前对话中重试。';
  String get newChatCreateFailed =>
      _en ? 'Unable to create a new chat. Try again.' : '无法新建对话，请重试。';
  String get newChatBusy => _en
      ? 'Another chat update is in progress. Try New chat again.'
      : '当前对话正在更新，请稍后重试新建对话。';
  String get aiActionInProgress =>
      _en ? 'Another AI action is in progress.' : '另一个 AI 操作正在进行中。';
  String get playbooks => _en ? 'Playbooks' : '运维剧本';
  String get commandUnknownHint => _en
      ? 'Type a command to use. Available: /compact, /tools, /skills, /plan.'
      : '输入以 / 开头的命令，如 /compact、/tools、/skills 或 /plan';
  String get commandCompactSummary =>
      _en ? 'Compress context for the next request.' : '为下一次请求压缩上下文。';
  String get commandToolsSummary =>
      _en ? 'Limit the tools available in this chat.' : '限制当前对话可使用的工具。';
  String get commandSkillsSummary =>
      _en ? 'Open and manage local AI skills.' : '打开并管理本地 AI Skills。';
  String get commandPlanSummary => _en
      ? 'Enable Plan Mode and optionally submit a request.'
      : '启用规划模式，并可同时提交请求。';
  String get commandUnknown => _en ? 'Unknown slash command.' : '未识别的斜杠命令。';
  String commandUnknownWithName(String command) =>
      _en ? 'Unknown command: /$command' : '未识别命令: /$command';
  String get commandCompact => _en
      ? 'Context compression is enabled for the next request.'
      : '已为下一次请求启用上下文压缩。';
  String commandToolsUpdated(int count) => _en
      ? 'Tool whitelist updated: $count selected.'
      : '工具白名单已更新：共选中 $count 个。';
  String get commandSkillsOpened =>
      _en ? 'Skills manager opened.' : '已打开 Skills 管理。';
  String commandToolsUnknown(List<String> unknown) => _en
      ? 'Unknown tool(s): ${unknown.join(', ')}'
      : '未识别工具：${unknown.join(', ')}';
  String get commandToolsLoadFailed =>
      _en ? 'Unable to load available tools.' : '无法加载可用工具。';
  String get commandToolsNoTools =>
      _en ? 'No tools are currently available.' : '当前无可用工具。';
  String get commandToolsSearch => _en ? 'Search tools' : '搜索工具';
  String get commandToolsNoResult =>
      _en ? 'No tools match the search.' : '未找到匹配的工具。';
  String get commandToolsTitle => _en ? 'Choose tools' : '选择可用工具';
  String commandToolsSelected(int count) =>
      _en ? '$count selected' : '已选择 $count 个';
  String get commandToolsClearSelection => _en ? 'Clear selection' : '清除选择';
  String get commandToolsClearSearch => _en ? 'Clear search' : '清除搜索';
  String get approveAndExecutePlan =>
      _en ? 'Approve & Execute Plan' : '同意并执行计划';
  String get planApprovalChecking =>
      _en ? 'Checking execution readiness…' : '正在检查执行条件…';
  String get planApprovalHint =>
      _en ? 'Approve or revise this plan.' : '执行或调整此计划。';
  String get planApprovalStarting =>
      _en ? 'Starting plan execution…' : '正在启动计划执行…';
  String get planApprovalNoPlan => _en
      ? 'This plan is no longer available. Review the latest plan and try again.'
      : '当前计划已不可执行，请检查最新计划后重试。';
  String get planApprovalApiKeyMissing => _en
      ? 'Add an API key in LLM settings before executing the plan.'
      : '请先在大模型设置中配置 API Key，再执行计划。';
  String get planApprovalPlanChanged => _en
      ? 'The plan changed during the runtime check. Review the latest plan and try again.'
      : '运行环境检查期间计划已发生变化，请检查最新计划后重试。';
  String get planApprovalFailed =>
      _en ? 'Unable to start plan execution. Try again.' : '无法启动计划执行，请重试。';
  String get planApprovalCancelled =>
      _en ? 'Plan execution was cancelled.' : '计划执行已取消。';
  String get planRevisionPrompt => _en ? 'Revise this plan: ' : '请按以下意见调整计划：';
  String get todoTitle => _en ? 'Execution plan' : '执行计划';
  String get todoFailureGuidance => _en
      ? 'Fix cause and retry, skip if safe, or return to Plan Mode.'
      : '请先查看日志并修复原因后重试；仅在确认安全时跳过，也可以返回规划模式调整后续步骤。';
  String get todoRetryStep => _en ? 'Retry step' : '重试此步骤';
  String get todoSkipStep => _en ? 'Skip step' : '跳过此步骤';
  String get todoRevisePlan => _en ? 'Revise plan' : '调整计划';
  String get todoSkipReasonTitle => _en ? 'Skip step' : '跳过步骤';
  String get todoSkipReasonPrompt =>
      _en ? 'Provide a reason for skipping this task:' : '请输入跳过此任务的原因：';
  String get todoSkipReasonHint => _en ? 'e.g. Completed manually' : '例如：已手动完成';
  String get todoSkipConfirm => _en ? 'Skip' : '跳过';
  String get todoCommand => _en ? 'Command' : '命令';
  String get todoLogs => _en ? 'Execution logs' : '执行日志';
  String todoStatusLabel(StepStatus status) {
    switch (status) {
      case StepStatus.pending:
        return _en ? 'Pending' : '待执行';
      case StepStatus.running:
        return _en ? 'Running' : '执行中';
      case StepStatus.success:
        return _en ? 'Completed' : '已完成';
      case StepStatus.failed:
        return _en ? 'Failed' : '执行失败';
      case StepStatus.skipped:
        return _en ? 'Skipped' : '已跳过';
    }
  }

  String todoStepSemantics(String name, StepStatus status) => _en
      ? '$name, ${todoStatusLabel(status)}'
      : '$name，${todoStatusLabel(status)}';

  String get toolsAndAutomation => _en ? 'Tools & Automation' : '工具与自动化';
  String get openAiSkills => _en ? 'AI Skills' : 'AI Skills';
  String get aiSkillsHint => _en
      ? 'Manage custom AI prompts, workflows, and references'
      : '管理自定义 AI 提示词、工作流及规则说明';
  String get openMcpSettings => _en ? 'MCP settings' : 'MCP 设置';
  String get mcpServerHint => _en
      ? 'Streamable HTTP server for CLI agent integrations.'
      : '供 Codex、Claude Code、Gemini CLI 使用的本地 Streamable HTTP 端点。';

  String get runtimeWarningsTitle => _en ? 'Runtime warnings' : '运行环境风险';
  String get runtimeBlockedTitle =>
      _en ? 'Runtime check blocked execution' : '运行环境检查阻止执行';
  String get runtimeWarningsMessage => _en
      ? 'Plan can run, but environment limits may interrupt long runs.'
      : '计划可以继续执行，但客户端环境可能影响长时间 Agent 任务。';
  String get runtimeBlockedMessage => _en
      ? 'Resolve these client issues to execute plan.'
      : '请先处理以下客户端问题，再执行此计划。';
  String get runtimeBlockingLabel => _en ? 'Blocking' : '阻断';
  String get runtimeWarningLabel => _en ? 'Warning' : '警告';
  String get runtimeSystemSettings => _en ? 'System settings' : '系统设置';
  String get runtimeContinue => _en ? 'Continue' : '继续执行';
  String get noConfiguredServers => _en ? 'No configured servers.' : '没有配置服务器。';
  String get selectTargetServers => _en ? 'Select target servers' : '选择目标服务器';
  String get loadingPrompts => _en ? 'Loading prompts...' : '正在加载提示词...';
  String get clearAll => _en ? 'Clear all' : '清空全部';
  String selectedServers(int count) =>
      _en ? '$count ${count == 1 ? 'server' : 'servers'}' : '$count 台服务器';

  ({String title, String detail, String recommendation}) runtimeHealthIssue(
    ClientRuntimeHealthIssue issue,
  ) {
    switch (issue.code) {
      case 'network_status_unavailable':
        return _en
            ? (
                title: 'Network status unavailable',
                detail: 'The client network state could not be read.',
                recommendation:
                    'Verify the device network before starting long agent work.',
              )
            : (
                title: '网络状态不可用',
                detail: '无法读取客户端网络状态。',
                recommendation: '开始长时间 Agent 任务前，请手动确认设备网络正常。',
              );
      case 'network_disconnected':
        return _en
            ? (
                title: 'No client network connection',
                detail: 'The Android device has no active network connection.',
                recommendation:
                    'Connect to a stable network before executing the plan.',
              )
            : (
                title: '客户端未连接网络',
                detail: 'Android 设备当前没有活动网络连接。',
                recommendation: '请先连接稳定网络，再执行计划。',
              );
      case 'network_not_validated':
        return _en
            ? (
                title: 'Network has no validated internet access',
                detail:
                    'Android reports that the active network cannot reach the internet.',
                recommendation:
                    'Switch networks or complete captive-portal sign-in first.',
              )
            : (
                title: '网络无法访问互联网',
                detail: 'Android 报告当前网络尚未通过互联网可用性验证。',
                recommendation: '请切换网络或先完成门户登录。',
              );
      case 'metered_network':
        return _en
            ? (
                title: 'Metered network active',
                detail: 'The client is using a metered network.',
                recommendation:
                    'Prefer Wi-Fi for large transfers or long monitoring sessions.',
              )
            : (
                title: '当前使用按流量计费网络',
                detail: '客户端正在使用按流量计费的网络。',
                recommendation: '大文件传输或长时间监控时建议改用 Wi-Fi。',
              );
      case 'vpn_active':
        return _en
            ? (
                title: 'VPN is active',
                detail: 'A client-side VPN may affect SSH routing or latency.',
                recommendation:
                    'Confirm that the VPN route can reach the target servers.',
              )
            : (
                title: 'VPN 已启用',
                detail: '客户端 VPN 可能影响 SSH 路由或延迟。',
                recommendation: '请确认 VPN 路由能够访问目标服务器。',
              );
      case 'http_proxy_active':
        return _en
            ? (
                title: 'HTTP proxy detected',
                detail: 'The active network has a client proxy configured.',
                recommendation:
                    'Confirm that the proxy does not interfere with model or web requests.',
              )
            : (
                title: '检测到 HTTP 代理',
                detail: '当前网络配置了客户端代理。',
                recommendation: '请确认代理不会影响模型或网页请求。',
              );
      case 'permission_status_unavailable':
        return _en
            ? (
                title: 'Permission status unavailable',
                detail: 'The client permission state could not be read.',
                recommendation:
                    'Check system settings if notifications or background services fail.',
              )
            : (
                title: '权限状态不可用',
                detail: '无法读取客户端权限状态。',
                recommendation: '如果通知或后台服务异常，请检查系统设置。',
              );
      case 'background_service_unavailable':
        return _en
            ? (
                title: 'Background service unavailable',
                detail:
                    'This platform cannot keep long SSH work in a native service.',
                recommendation:
                    'Keep the app foregrounded or use a platform with background-service support.',
              )
            : (
                title: '后台服务不可用',
                detail: '当前平台无法通过原生服务维持长时间 SSH 任务。',
                recommendation: '请保持应用在前台，或改用支持后台服务的平台。',
              );
      case 'notification_permission_denied':
        return _en
            ? (
                title: 'Notification permission denied',
                detail:
                    'Long-running agent work needs notification permission for reliable status updates.',
                recommendation:
                    'Grant notification permission in system settings.',
              )
            : (
                title: '通知权限被拒绝',
                detail: '长时间 Agent 任务需要通知权限来可靠更新状态。',
                recommendation: '请在系统设置中授予通知权限。',
              );
      case 'battery_optimization_active':
        return _en
            ? (
                title: 'Battery optimization may stop background work',
                detail:
                    'Android may restrict the app while SSH or monitoring is running.',
                recommendation:
                    'Allow a battery-optimization exemption for long background execution.',
              )
            : (
                title: '电池优化可能中断后台任务',
                detail: 'SSH 或监控运行时，Android 可能限制本应用。',
                recommendation: '长时间后台执行前，请允许本应用不受电池优化限制。',
              );
      case 'power_save_mode':
        return _en
            ? (
                title: 'Power save mode is active',
                detail:
                    'Power save mode can delay network and background work.',
                recommendation:
                    'Disable power save mode before long SSH, SFTP, or monitoring tasks.',
              )
            : (
                title: '省电模式已启用',
                detail: '省电模式可能延迟网络与后台任务。',
                recommendation: '长时间运行 SSH、SFTP 或监控前，请关闭省电模式。',
              );
      case 'low_battery':
        return _en
            ? (
                title: 'Low battery',
                detail: 'The device battery is low and it is not charging.',
                recommendation:
                    'Charge the device before long agent execution.',
              )
            : (
                title: '设备电量较低',
                detail: '设备电量较低且当前未充电。',
                recommendation: '开始长时间 Agent 执行前，请先为设备充电。',
              );
      case 'thermal_pressure':
        return _en
            ? (
                title: 'Device thermal pressure',
                detail: 'Android reports elevated device temperature.',
                recommendation:
                    'Let the device cool down before long model or tool loops.',
              )
            : (
                title: '设备温度较高',
                detail: 'Android 报告设备当前存在温度压力。',
                recommendation: '长时间模型或工具循环前，请先让设备降温。',
              );
      default:
        return _en
            ? (
                title: issue.title,
                detail: issue.detail,
                recommendation: issue.recommendation,
              )
            : (
                title: '客户端环境异常（${issue.code}）',
                detail: '检测到未识别的客户端环境问题。',
                recommendation: '请检查设备网络、权限、电量和后台运行设置。',
              );
    }
  }
}
