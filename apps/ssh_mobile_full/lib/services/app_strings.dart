part of 'app_settings.dart';

class AppStrings {
  final AppLanguage language;

  const AppStrings(this.language);

  bool get _en => language == AppLanguage.en;
  bool get isEnglish => _en;

  String get appTitle => 'SSH Mobile';
  String get switchToChinese => '中文';
  String get switchToEnglish => 'EN';
  String get languageLabel => _en ? 'Language' : '语言';
  String get currentLanguageName => _en ? 'English' : '中文';
  String get defaultOption => _en ? 'Default' : '默认';
  String get switchToLightMode => _en ? 'Switch to light mode' : '切换到浅色主题';
  String get switchToDarkMode => _en ? 'Switch to dark mode' : '切换到深色主题';
  String get oledDarkMode => _en ? 'OLED Black Mode' : 'OLED 纯黑模式';
  String get colorPalette => _en ? 'App Color' : '应用配色';
  String get paletteMonochrome => _en ? 'Monochrome' : '黑白灰';
  String get paletteIndigo => _en ? 'Indigo' : '靛蓝';
  String get paletteOcean => _en ? 'Ocean' : '海洋蓝';
  String get paletteEmerald => _en ? 'Emerald' : '翡翠绿';
  String get paletteRose => _en ? 'Rose' : '玫瑰红';
  String get paletteAmber => _en ? 'Amber' : '琥珀橙';
  String get terminalTheme => _en ? 'Terminal Theme' : '终端配色方案';
  String get customTerminalFont => _en ? 'Custom Terminal Font' : '自定义终端字体';
  String get customTerminalFontHint => _en
      ? 'System monospaced font family, e.g. Fira Code'
      : '系统已安装的等宽字体名称，如 Fira Code';
  String get serverListLayout => _en ? 'Server List Layout' : '服务器列表布局';
  String get layoutList => _en ? 'List' : '列表';
  String get layoutGrid => _en ? 'Grid' : '网格';

  String get servers => _en ? 'Servers' : '服务器';
  String get server => _en ? 'Server' : '服务器';
  String get loadingServers => _en ? 'Loading servers...' : '正在加载服务器...';
  String get windows => _en ? 'Windows' : '窗口';
  String get window => _en ? 'Window' : '窗口';
  String get active => _en ? 'Active' : '活跃';
  String get performanceMonitor => _en ? 'Monitor' : '监控';
  String get monitor => performanceMonitor;
  String get admin => systemAdmin;
  String get logs => _en ? 'Logs' : '日志';
  String get cancel => _en ? 'Cancel' : '取消';
  String get create => _en ? 'Create' : '创建';
  String get save => _en ? 'Save' : '保存';
  String get saving => _en ? 'Saving...' : '保存中...';
  String get add => _en ? 'Add' : '添加';
  String get edit => _en ? 'Edit' : '编辑';
  String get delete => _en ? 'Delete' : '删除';
  String get close => _en ? 'Close' : '关闭';
  String get copy => _en ? 'Copy' : '复制';
  String get remove => _en ? 'Remove' : '删除';
  String get unknown => _en ? 'Unknown' : '未知';

  String get addConnection => _en ? 'Add connection' : '添加连接';
  String get verifyAndSave => _en ? 'Verify & Save' : '验证并保存';
  String get deleteRemoteEntryConfirmPrompt =>
      _en ? 'Type the exact name to confirm:' : '请输入完整名称确认：';
  String get deleteRemoteEntryConfirmLabel => _en ? 'Entry name' : '文件或目录名称';
  String get deleteRemoteEntryConfirmMismatch =>
      _en ? 'Name does not match.' : '名称不匹配。';
  String uploadFileTooLarge(String limit) =>
      _en ? 'File is larger than $limit' : '文件大小超过了 $limit';
  String get uploadFileNoAccess =>
      _en ? 'Unable to access file path on this platform.' : '此平台无法访问文件路径。';
  String get uploadCancelled => _en ? 'Upload cancelled' : '上传已取消';
  String downloadFileTooLarge(String limit) =>
      _en ? 'File is larger than $limit' : '文件大小超过了 $limit';
  String get downloadCancelled => _en ? 'Download cancelled' : '下载已取消';
  String uploadingFile(String name) => _en ? 'Uploading $name' : '正在上传 $name';
  String downloadingFile(String name) =>
      _en ? 'Downloading $name' : '正在下载 $name';
  String get editConnection => _en ? 'Edit connection' : '编辑连接';
  String get noConnections => _en ? 'No saved servers yet' : '还没有保存的服务器';
  String get addHint => _en
      ? 'Add a connection to start a secure SSH session.'
      : '添加连接，开始安全的 SSH 会话。';
  String get reorderServer => _en ? 'Reorder server' : '调整服务器顺序';
  String get noMonitoringData => _en ? 'No monitoring data' : '暂无监控数据';
  String get newWindow => _en ? 'New window' : '新建窗口';
  String connectingTo(String name) =>
      _en ? 'Connecting to $name' : '正在连接 $name';
  String get establishingConnection =>
      _en ? 'Establishing SSH connection...' : '正在建立 SSH 连接...';
  String get deleteConnectionTitle => _en ? 'Delete connection' : '删除连接';
  String deleteConnectionContent(String name) => _en
      ? 'Delete "$name"? Password and private key will also be removed.'
      : '确定删除 "$name" 吗？\n密码和私钥也会一并清除。';
  String get deleteConnectionConfirm => _en ? 'Delete' : '删除';

  String get connectionInfo => _en ? 'Connection' : '连接信息';
  String get basicInfo => _en ? 'Basic info' : '基本信息';
  String get authMethod => _en ? 'Authentication' : '认证方式';
  String get jumpHostOptional => _en ? 'Jump host (optional)' : '跳板机（可选）';
  String get advancedOptions => _en ? 'Advanced options' : '高级选项';
  String get connectionName => _en ? 'Connection name' : '连接名称';
  String get connectionNameHint => _en ? 'My server' : '我的服务器';
  String get enterConnectionName => _en ? 'Enter connection name' : '请输入连接名称';
  String get hostAddress => _en ? 'Host address' : '主机地址';
  String get hostAddressHint =>
      _en ? '192.168.1.1 or example.com' : '192.168.1.1 或 example.com';
  String get enterHostAddress => _en ? 'Enter host address' : '请输入主机地址';
  String get port => _en ? 'Port' : '端口';
  String get invalidPort => _en ? 'Invalid port' : '无效端口';
  String get username => _en ? 'Username' : '用户名';
  String get enterUsername => _en ? 'Enter username' : '请输入用户名';
  String get password => _en ? 'Password' : '密码';
  String get privateKey => _en ? 'Private key' : '私钥';
  String get privateKeyPassword => _en ? 'Private key + password' : '私钥+密码';
  String get passwordHint => _en ? 'Enter SSH password' : '输入 SSH 密码';
  String get showPassword => _en ? 'Show password' : '显示密码';
  String get hidePassword => _en ? 'Hide password' : '隐藏密码';
  String get passwordRequired =>
      _en ? 'Password authentication requires a password' : '密码认证需要输入密码';
  String get sshPrivateKey => _en ? 'SSH private key' : 'SSH 私钥';
  String get privateKeyRequired => _en
      ? 'Private key authentication requires a private key'
      : '私钥认证需要输入私钥内容';
  String get jumpHost => _en ? 'Jump host address' : '跳板机地址';
  String get jumpHostHint =>
      _en ? 'Optional (leave empty for direct)' : '可选，留空则直连';
  String get jumpPort => _en ? 'Jump host port' : '跳板机端口';
  String get jumpUsername => _en ? 'Jump host username' : '跳板机用户名';
  String get optional => _en ? 'Optional' : '可选';
  String get tmuxModeDescription => _en
      ? 'Auto-connect to tmux session matching the window name.'
      : '连接 SSH 后自动进入与当前窗口同名的 tmux 会话。';
  String get sshModeDescription =>
      _en ? 'Open a normal interactive SSH shell.' : '打开普通交互式 SSH shell。';
  String get tmuxAutoDeleteMinutes =>
      _en ? 'tmux auto-delete wait time (minutes)' : 'tmux 无连接自动删除等待时间（分钟）';
  String get tmuxAutoDeleteHelp => _en
      ? 'Unit: minutes. If nobody reconnects after disconnecting, the tmux session will be deleted after this time.'
      : '单位：分钟。断开后无人重新连接，超过该时间自动删除 tmux 会话。';
  String get minOneMinute => _en ? 'Minimum 1 minute' : '最少 1 分钟';
  String get max1440Minutes => _en ? 'Maximum 1440 minutes' : '最多 1440 分钟';
  String get keepAliveTitle => _en ? 'Keep connection in background' : '后台保持连接';
  String get keepAliveSubtitle => _en
      ? 'The app uses a background service and keep-alive to keep SSH connected when possible.'
      : '应用会通过后台服务和 keep-alive 尽量维持 SSH 连接。';
  String saveFailed(Object error) =>
      _en ? 'Save failed: $error' : '保存失败: $error';
  String get saveFailedGuidance => _en
      ? 'Please check the host address, port, username, password or private key, then save again.'
      : '请检查主机地址、端口、用户名、密码或私钥后重新保存。';
  String get paste => _en ? 'Paste' : '粘贴';
  String get serverSystem => _en ? 'Server system' : '服务器系统';
  String get windowsTmuxUnavailable => _en
      ? 'tmux requires a Linux/WSL connection with tmux installed.'
      : 'Windows OpenSSH 使用普通交互式 shell。tmux 只适用于 Linux/WSL 且服务器已安装 tmux 的场景。';
  String get windowsMonitoringDescription => _en
      ? 'PowerShell diagnostics monitor. Terminal uses plain SSH.'
      : 'Windows 监控会使用 PowerShell 诊断命令；终端模式固定为普通 SSH。';
  String get linuxMonitoringDescription => _en
      ? 'Default. Supports plain SSH and SSH + tmux.'
      : '默认选项。服务器安装 tmux 时支持普通 SSH 和 SSH + tmux。';
  String get saveWillCloseWindowsTitle =>
      _en ? 'Related windows will be closed' : '保存后将关闭相关窗口';
  String saveWillCloseWindowsContent(int count) => _en
      ? 'Saving closes $count active terminal ${count == 1 ? "window" : "windows"} to apply the connection changes.'
      : '当前配置有关联的 $count 个终端窗口。保存修改后，这些旧窗口会自动关闭，避免继续向旧 SSH 或旧 tmux 会话发送输入。';
  String get saveAndDisconnect => _en ? 'Save and disconnect' : '保存并断开';

  String get newTerminalWindow => _en ? 'New terminal window' : '新建终端窗口';
  String get windowName => _en ? 'Window name' : '窗口名称';
  String get enterWindowName => _en ? 'Enter window name' : '请输入窗口名称';
  String get duplicateWindowName =>
      _en ? 'Window name already exists' : '窗口名称已存在';

  String get terminalWindows => _en ? 'Terminal windows' : '终端窗口';
  String terminalWindowsOverview(int total, int connected, int attention) => _en
      ? '$total ${total == 1 ? "window" : "windows"} · $connected connected${attention > 0 ? " · $attention ${attention == 1 ? "needs" : "need"} attention" : ""}'
      : '$total 个窗口 · $connected 个已连接${attention > 0 ? " · $attention 个需处理" : ""}';
  String terminalWindowsForServer(int total, int connected) => _en
      ? '$total ${total == 1 ? "window" : "windows"} · $connected connected'
      : '$total 个窗口 · $connected 个已连接';
  String selectedWindows(int count) =>
      _en ? '$count selected' : '已选择 $count 个窗口';
  String selectedWindowsHint(int total) => _en
      ? 'Choose actions for the selected windows · $total total'
      : '对选中的窗口执行操作 · 共 $total 个';
  String selectedServers(int count) =>
      _en ? '$count selected' : '已选择 $count 台服务器';
  String viewAllTerminalWindows(int totalCount) => _en
      ? 'View all $totalCount ${totalCount == 1 ? "window" : "windows"}'
      : '查看全部 $totalCount 个窗口';
  String get exitSelection => _en ? 'Exit selection' : '退出选择';
  String get selectAll => _en ? 'Select all' : '全选';
  String get closeSelectedWindows => _en ? 'Close selected windows' : '关闭选中窗口';
  String get connectionHistory => _en ? 'Connection history' : '连接历史';
  String get noOpenWindows => _en ? 'No open terminal windows' : '暂无打开的终端窗口';
  String get openWindowsHint => _en
      ? 'Opened terminals will appear here after connecting to a server.'
      : '连接服务器后，打开的终端会显示在这里。';
  String get enterWindow => _en ? 'Enter window' : '进入窗口';
  String get renameTerminalWindow => _en ? 'Rename window' : '重命名窗口';
  String get windowActions => _en ? 'Window actions' : '窗口操作';
  String get closeWindow => _en ? 'Close window' : '关闭窗口';
  String get sessionMode => _en ? 'Mode' : '模式';
  String get tmuxSession => _en ? 'tmux' : 'tmux';
  String get plainSshSession => _en ? 'SSH' : 'SSH';
  String get createdAt => _en ? 'Created' : '创建';
  String get autoDestroy => _en ? 'Auto delete' : '销毁';
  String get memoryUsage => _en ? 'Memory' : '内存';
  String get notAvailable => _en ? 'N/A' : '不适用';
  String autoDestroyAfter(String duration) =>
      _en ? 'after disconnect: $duration' : '断开后 $duration';
  String autoDestroyAt(String time) => _en ? 'around $time' : '预计 $time';
  String durationMinutes(int minutes) => _en ? '$minutes min' : '$minutes 分钟';
  String durationSeconds(int seconds) => _en ? '$seconds sec' : '$seconds 秒';
  String get connected => _en ? 'Connected' : '已连接';
  String get connecting => _en ? 'Connecting' : '连接中';
  String get connectionError => _en ? 'Connection error' : '连接错误';
  String get disconnected => _en ? 'Disconnected' : '已断开';
  String closeWindowTitle(String name) =>
      _en ? 'Close "$name"?' : '确定关闭 "$name" 吗？';
  String get closeTerminalWindow => _en ? 'Close terminal window' : '关闭终端窗口';
  String get staleTmuxHint => _en
      ? 'If an abnormal tmux session remains on the server, run:'
      : '如果服务器上残留异常 tmux 会话，可手动执行：';
  String get copyCommand => _en ? 'Copy command' : '复制命令';
  String get copiedCleanupCommand =>
      _en ? 'Server cleanup command copied' : '已复制服务器清理命令';
  String closeSelectedContent(int count) => _en
      ? 'Close $count selected terminal ${count == 1 ? "window" : "windows"}?'
      : '确定关闭选中的 $count 个终端窗口吗？';

  String get developerLogs => _en ? 'Developer logs' : '开发日志';
  String get copyFilteredLogs => _en ? 'Copy filtered logs' : '复制当前筛选日志';
  String get clearLogs => _en ? 'Clear logs' : '清空日志';
  String get noLogs => _en ? 'No logs' : '暂无日志';
  String get noLogsForLevel => _en ? 'No logs for this level' : '当前等级暂无日志';
  String get copiedFilteredLogs => _en ? 'Filtered logs copied' : '已复制当前筛选日志';
  String get logsCleared => _en ? 'Logs cleared' : '已清空日志';
  String get copySingleLog => _en ? 'Copy this log' : '复制单条日志';
  String get expandFullLog => _en ? 'Tap to expand full log' : '点击展开完整日志';
  String get copiedSingleLog => _en ? 'Log copied' : '已复制单条日志';

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

  String get connectionHistoryHint => _en
      ? 'History of terminal sessions and tmux cleanups.'
      : '查看最近的终端会话、连接结果和 tmux 清理命令。';
  String connectionHistoryCount(int count) => _en
      ? '$count recent ${count == 1 ? "session" : "sessions"}'
      : '最近 $count 条会话记录';
  String get loadingConnectionHistory =>
      _en ? 'Loading connection history…' : '正在加载连接历史…';
  String get connectionHistoryLoadFailed =>
      _en ? 'Could not load connection history' : '无法加载连接历史';
  String get connectionHistoryLoadFailedHint =>
      _en ? 'Unable to read session history. Retry.' : '暂时无法读取已保存的会话记录，请重试。';
  String get noConnectionHistory =>
      _en ? 'No connection history yet' : '暂无连接历史';
  String get noConnectionHistoryHint => _en
      ? 'Recent terminal sessions will appear here.'
      : '最近打开的终端会话及其连接状态会显示在这里。';
  String historyUpdatedAt(String time) => _en ? 'Updated $time' : '更新于 $time';
  String get deleteHistoryRecord => _en ? 'Delete history record' : '删除历史记录';
  String get deleteHistoryRecordFailed => _en
      ? 'Could not delete this history record. Try again.'
      : '无法删除这条历史记录，请重试。';
  String get copyCleanupCommandFailed =>
      _en ? 'Could not copy the cleanup command. Try again.' : '无法复制清理命令，请重试。';

  String get backgroundConnectionSettings => _en ? 'Background access' : '后台运行';
  String get enableBackgroundPermission =>
      _en ? 'Keep SSH connected in the background' : '让 SSH 在后台保持连接';
  String get backgroundPermissionGuide => _en
      ? 'Android battery optimization may drop connections. Configure background access to keep SSH alive.'
      : 'Android 可能会为了省电暂停后台网络。请检查以下设置，减少 SSH 会话和文件传输意外断开的情况。';
  String get backgroundChecklistTitle => _en ? 'Recommended settings' : '建议设置';
  String get allowBackgroundActivity =>
      _en ? 'Allow background activity' : '允许后台活动';
  String get allowNotifications => _en ? 'Allow notifications' : '允许发送通知';
  String get relaxBatteryRestrictions =>
      _en ? 'Remove battery restrictions' : '放宽电池限制';
  String get adjustPowerLimit => _en ? 'Review battery settings' : '检查电池设置';
  String get openAppSettings => _en ? 'Open app settings' : '打开应用设置';
  String get settings => _en ? 'Settings' : '设置';
  String get backgroundGuideNote => _en
      ? 'Settings vary by device. Unresolved battery limits will prompt on next launch.'
      : '不同设备的设置名称可能不同。你可以暂时继续；如果限制仍然存在，下次启动时会再次提醒。';
  String get enterApp => _en ? 'Continue for now' : '暂时继续';
  String get continueToApp => _en ? 'Continue to app' : '进入应用';
  String get powerLimitExempt =>
      _en ? 'Battery restrictions are relaxed' : '已放宽电池限制';
  String get powerLimitUnknown =>
      _en ? 'Battery restriction status needs review' : '需要检查电池限制状态';

  String get sftp => _en ? 'SFTP' : 'SFTP';
  String get sftpServers => _en ? 'SFTP servers' : 'SFTP 服务器';
  String get collapseServerList => _en ? 'Collapse server list' : '折叠服务器列表';
  String get expandServerList => _en ? 'Expand server list' : '展开服务器列表';
  String get sftpEmptyTitle =>
      _en ? 'Select a server for SFTP' : '选择服务器使用 SFTP';
  String get sftpEmptyHint => _en
      ? 'Browse remote files using saved SSH connections.'
      : '桌面端和移动端使用同一套 SSH 连接来浏览远程文件。';
  String get parentDirectory => _en ? 'Parent directory' : '上级目录';
  String get pathHistory => _en ? 'Path history' : '路径记录';
  String get inputPath => _en ? 'Input path' : '输入路径';
  String get recentPaths => _en ? 'Recent paths' : '最近路径';
  String get favoritePaths => _en ? 'Favorite paths' : '收藏路径';
  String get addFavoritePath => _en ? 'Add favorite path' : '收藏当前路径';
  String get removeFavoritePath => _en ? 'Remove favorite path' : '取消收藏路径';
  String get noRecentPaths => _en ? 'No recent paths' : '暂无最近路径';
  String get noFavoritePaths => _en ? 'No favorite paths' : '暂无收藏路径';
  String get refresh => _en ? 'Refresh' : '刷新';
  String get retry => _en ? 'Retry' : '重试';
  String get disconnect => _en ? 'Disconnect' : '断开连接';
  String get emptyDirectory => _en ? 'This directory is empty' : '当前目录为空';
  String get emptyDirectoryHint =>
      _en ? 'Upload files or navigate to another path.' : '可以上传文件，或打开其他远程路径。';
  String get loadingDirectory =>
      _en ? 'Loading remote directory…' : '正在加载远程目录…';
  String get directoryLoadFailed =>
      _en ? 'Could not load this directory' : '无法加载此目录';
  String get directoryLoadFailedHint => _en
      ? 'Check the SFTP connection and permissions, then try again.'
      : '请检查 SFTP 连接和目录权限，然后重试。';
  String get openPath => _en ? 'Open path' : '打开路径';
  String entryActions(String name) => _en ? 'Actions for $name' : '$name 的操作';
  String get pathHistoryLoadFailed =>
      _en ? 'Could not load path history' : '无法加载路径记录';
  String get pathHistoryLoadFailedHint => _en
      ? 'Recent and favorite paths could not be read. Try again.'
      : '无法读取最近路径和收藏路径，请重试。';
  String get directory => _en ? 'Directory' : '文件夹';
  String get uploadFile => _en ? 'Upload file' : '上传文件';
  String get uploadComplete => _en ? 'Upload complete' : '上传完成';
  String uploadFailed(Object error) =>
      _en ? 'Upload failed: $error' : '上传失败：$error';
  String get viewFile => _en ? 'View file' : '查看文件';
  String get preview => _en ? 'Preview' : '预览';
  String get source => _en ? 'Source' : '源码';
  String get previewMode => _en ? 'Preview mode' : '预览模式';
  String get loadingFilePreview => _en ? 'Loading file preview…' : '正在加载文件预览…';
  String get filePreviewLoadFailed =>
      _en ? 'Could not load this preview' : '无法加载此文件预览';
  String get filePreviewLoadFailedHint => _en
      ? 'Check the SFTP connection and file permissions, then try again.'
      : '请检查 SFTP 连接和文件权限，然后重试。';
  String get filePreviewTooLarge =>
      _en ? 'This file is too large to preview' : '文件过大，无法预览';
  String filePreviewTooLargeHint(int maxBytes) {
    final limit = _fileSizeLimitLabel(maxBytes);
    return _en
        ? 'File exceeds $limit preview limit. Return and download file.'
        : '安全预览上限为 $limit。请返回文件列表，下载后再查看。';
  }

  String get filePreviewResourceLimit =>
      _en ? 'This file is too complex to preview safely' : '文件复杂度过高，无法安全预览';
  String get filePreviewResourceLimitHint => _en
      ? 'Complexity exceeds in-app rendering budget. Download to view.'
      : '图片尺寸或动画复杂度超出应用内渲染预算。请下载后使用其他应用查看。';
  String get closePreview => _en ? 'Back to files' : '返回文件列表';
  String get filePreviewRenderFailed =>
      _en ? 'Could not display this preview' : '无法显示此文件预览';
  String get filePreviewRenderFailedHint => _en
      ? 'The file may be damaged or use an unsupported format. Try loading it again.'
      : '文件可能已损坏或使用了不支持的格式，请重新加载。';
  String get unsupportedPreviewTitle => _en ? 'No preview available' : '暂不支持预览';
  String get unsupportedPreview => _en
      ? 'Unsupported preview file type. Download to open.'
      : '暂不支持预览这种文件类型。可以下载后用其他应用打开。';
  String get htmlPreviewUnavailable =>
      _en ? 'HTML preview is unavailable here' : '当前平台无法渲染 HTML';
  String get htmlPreviewUnavailableHint => _en
      ? 'Rendered HTML preview is available on Android, iOS, and macOS. You can still inspect the source safely.'
      : 'HTML 渲染预览支持 Android、iOS 和 macOS；你仍可安全查看源码。';
  String get pdfPreviewUnavailable =>
      _en ? 'Remote PDF preview is disabled' : '已禁用远程 PDF 预览';
  String get pdfPreviewUnavailableHint => _en
      ? 'Download PDF to open in a trusted reader.'
      : '为避免在应用内解析不受信任的文档，请下载后使用可信的 PDF 阅读器打开。';
  String get viewSource => _en ? 'View source' : '查看源码';
  String get externalPreviewContentBlocked =>
      _en ? 'External preview content is blocked' : '已阻止预览中的外部内容';
  String get previewKindImage => _en ? 'Image' : '图片';
  String get previewKindPdf => _en ? 'PDF document' : 'PDF 文档';
  String get previewKindMarkdown => _en ? 'Markdown' : 'Markdown';
  String get previewKindHtml => _en ? 'HTML document' : 'HTML 文档';
  String get previewKindText => _en ? 'Text file' : '文本文件';
  String get previewKindUnsupported => _en ? 'File' : '文件';
  String previewFileDetails(String kind, String size) => '$kind · $size';
  String get imagePreviewLabel => _en ? 'Image preview' : '图片预览';
  String get htmlPreviewLabel => _en ? 'HTML preview' : 'HTML 预览';
  String get zoomOut => _en ? 'Zoom out' : '缩小';
  String get zoomIn => _en ? 'Zoom in' : '放大';
  String get resetZoom => _en ? 'Reset zoom' : '重置缩放';
  String imageZoomLevel(int percent) => _en ? 'Zoom $percent%' : '缩放 $percent%';
  String get downloadFile => _en ? 'Download file' : '下载文件';
  String get downloadComplete => _en ? 'Download complete' : '下载完成';
  String downloadFailed(Object error) =>
      _en ? 'Download failed: $error' : '下载失败：$error';
  String get deleteRemoteEntry => _en ? 'Delete remote entry' : '删除远程项目';
  String deleteRemoteEntryContent(String name) =>
      _en ? 'Delete "$name" from the server?' : '从服务器删除 "$name"？';
  String get deleteComplete => _en ? 'Deleted' : '已删除';
  String editRemoteFile(String name) => _en ? 'Edit "$name"' : '编辑 "$name"';
  String get remoteFileContent => _en ? 'Remote file content' : '远程文件内容';
  String get loadingRemoteFile => _en ? 'Loading remote file…' : '正在加载远程文件…';
  String get remoteFileOpenFailed =>
      _en ? 'Could not open this file' : '无法打开此文件';
  String get remoteFileOpenFailedHint => _en
      ? 'Check the SFTP connection and file permissions, then try again.'
      : '请检查 SFTP 连接和文件权限，然后重试。';
  String openEditorFailed(Object error) =>
      _en ? 'Unable to open editor: $error' : '无法打开编辑器：$error';
  String get saveComplete => _en ? 'Saved' : '已保存';
  String get saveRemoteFile => _en ? 'Save remote file' : '保存远程文件';
  String get savingRemoteFile => _en ? 'Saving remote file…' : '正在保存远程文件…';
  String get remoteFileSaveFailed => _en
      ? 'Could not save this file. Check the connection and try again.'
      : '无法保存此文件，请检查连接后重试。';
  String remoteFileTooLarge(int maxBytes) {
    final limit = _fileSizeLimitLabel(maxBytes);
    return _en
        ? 'This file is larger than the $limit edit limit. Reduce its content before saving.'
        : '文件内容超过 $limit 的编辑上限，请缩减内容后再保存。';
  }

  String _fileSizeLimitLabel(int maxBytes) {
    const bytesPerMegabyte = 1024 * 1024;
    return maxBytes >= bytesPerMegabyte
        ? '${(maxBytes / bytesPerMegabyte).toStringAsFixed(maxBytes % bytesPerMegabyte == 0 ? 0 : 1)} MB'
        : '${(maxBytes / 1024).ceil()} KB';
  }

  String get remoteFileNewChangesRemain => _en
      ? 'Earlier changes were saved. New edits are still unsaved.'
      : '先前修改已保存，新的编辑仍未保存。';
  String get remoteFilePath => _en ? 'Remote path' : '远程路径';
  String get remoteFileSaved => _en ? 'All changes saved' : '所有修改均已保存';
  String get remoteFileUnsaved => _en ? 'Unsaved changes' : '有未保存的修改';
  String get editorControls => _en ? 'Editor controls' : '编辑器控制';
  String get editorFontSize => _en ? 'Font size' : '字号';
  String fontSizeValue(int value) => _en ? 'Font size $value' : '字号 $value';
  String get smallerFont => _en ? 'Smaller font' : '缩小字号';
  String get largerFont => _en ? 'Larger font' : '放大字号';
  String get enableLineWrap => _en ? 'Enable line wrap' : '开启自动换行';
  String get disableLineWrap => _en ? 'Disable line wrap' : '关闭自动换行';
  String get discardChangesTitle => _en ? 'Discard changes?' : '放弃修改？';
  String get discardChangesContent =>
      _en ? 'File has unsaved changes. Exit anyway?' : '当前文件有未保存的修改，确定不保存并离开吗？';
  String get discard => _en ? 'Discard' : '放弃';

  String connectionFailed(String message) =>
      _en ? 'Connection failed: $message' : '连接失败：$message';
  String tmuxMissingHint(String text) => _en
      ? 'Connection failed: $text\nPlease install tmux manually on the server and try again.'
      : '连接失败：$text\n请先在服务器上手动安装 tmux 后再重试。';

  String get systemAdmin => _en ? 'Admin' : '系统管理';
  String get selectConnectedServer =>
      _en ? 'Select a connected server' : '选择已连接的服务器';
  String get noConnectedServers =>
      _en ? 'No active server connections' : '暂无活跃的服务器连接';
  String get rootRequiredMsg => _en
      ? 'This page requires root privileges. Currently you are not logged in as root.'
      : '此功能需要 root 权限。当前登录账户不是 root 权限。';
  String get nonLinuxMsg => _en
      ? 'Only Linux servers are supported for system admin tools.'
      : '系统管理工具目前仅支持 Linux 服务器。';
  String get activeSessions => _en ? 'Active Sessions' : '活动会话';
  String get userAccounts => _en ? 'User Accounts' : '用户账号';
  String get systemServices => _en ? 'Services' : '系统服务';
  String get listeningPorts => _en ? 'Ports' : '监听端口';
  String get applications => _en ? 'Applications' : '应用/进程';
  String get systemPower => _en ? 'Power' : '系统电源';
  String get lockUser => _en ? 'Lock User' : '禁用账号';
  String get unlockUser => _en ? 'Unlock User' : '启用账号';
  String get statusLocked => _en ? 'Locked' : '已禁用';
  String get changePassword => _en ? 'Change Password' : '修改密码';
  String get viewHomeDir => _en ? 'Home Directory' : '主目录文件';
  String get usageStats => _en ? 'Resource Usage' : '资源占用';
  String get storageUsed => _en ? 'Storage Used' : '存储空间';
  String get memoryUsed => _en ? 'Memory Used' : '内存占用';
  String get activeProcesses => _en ? 'Active Processes' : '活跃进程';
  String get changePasswordTitle => _en ? 'Change Password' : '修改用户密码';
  String get enterNewPassword => _en ? 'Enter new password' : '输入新密码';
  String get passwordChangedSuccess =>
      _en ? 'Password updated successfully' : '密码更新成功';
  String get actionConfirm => _en ? 'Are you sure?' : '确定要执行此操作吗？';
  String get serviceStart => _en ? 'Start' : '启动';
  String get serviceStop => _en ? 'Stop' : '停止';
  String get serviceRestart => _en ? 'Restart' : '重启';
  String get serviceEnable => _en ? 'Enable' : '启用';
  String get serviceDisable => _en ? 'Disable' : '禁用';
  String get rebootServer => _en ? 'Reboot Server' : '重启服务器';
  String get shutdownServer => _en ? 'Shutdown Server' : '关闭服务器';
  String get powerConfirmContent => _en
      ? 'Are you absolutely sure? This will disconnect your terminal session and perform the operation.'
      : '你确定要执行此操作吗？这将断开所有的终端会话并执行此动作。';

  String get createUser => _en ? 'Create User' : '新建账号';
  String get grantSudo => _en ? 'Grant Admin (Sudo)' : '授予管理员权限 (Sudo)';
  String get revokeSudo => _en ? 'Revoke Admin (Sudo)' : '取消管理员权限 (Sudo)';
  String get loginShell => _en ? 'Login Shell' : '登录 Shell';
  String get userCreatedSuccess =>
      _en ? 'User account created successfully' : '用户账号创建成功';
  String get sudoStatus => _en ? 'Privilege Level' : '特权级别';
  String get normalUser => _en ? 'Normal User' : '普通用户';
  String get administrator => _en ? 'Administrator' : '管理员 (sudo/wheel)';

  String get refreshAll => _en ? 'Refresh All' : '刷新全部';
  String get verifyingPrivilege =>
      _en ? 'Connecting and verifying privilege level...' : '正在连接并验证权限级别...';
  String get reconnectAsRootMsg => _en
      ? 'Please reconnect as "root" user or with administrative authorization.'
      : '请以 root 账户重新连接，或确保连接的账户拥有完整的管理员权限。';
  String get systemOmAdmin => _en ? 'System O&M Administration' : '系统运维管理';
  String get adminRootAccess => _en ? 'Root access' : 'Root 权限';
  String get adminSnapshotAccess => _en ? 'Snapshot access' : '快照访问';
  String get adminConnectionFailed => _en ? 'Connection failed' : '连接失败';
  String get adminSelectServer => _en ? 'Select a server' : '选择服务器';
  String get adminLinuxManagementHint => _en
      ? 'Account, session, and power controls require a Linux server with root access.'
      : '账户、会话和电源操作需要已取得 Root 权限的 Linux 服务器。';
  String get adminConnectAsRoot => _en ? 'Connect as Root' : '以 Root 连接';
  String get selectServerToManage => _en
      ? 'Select a server from the list to connect and manage local accounts, services, ports, and power status.'
      : '请从列表中选择服务器进行连接，以管理本地账户、系统服务、监听端口和电源状态。';
  String get backToHome => _en ? 'Back to Home' : '返回主目录';
  String get systemPowerHint => _en
      ? 'Reboot or power down the remote server. Authenticated as root.'
      : '远程服务器系统控制，将直接向系统发送硬件关机或重启指令。';
  String get confirm => _en ? 'Confirm' : '确定';
  String get searchService => _en ? 'Search service...' : '搜索服务...';
  String get searchPort => _en ? 'Search port/service...' : '搜索端口/服务...';
  String get searchSessions => _en ? 'Search sessions...' : '搜索会话...';
  String get searchAccounts => _en ? 'Search accounts...' : '搜索账户...';
  String get killSession => _en ? 'Kill Session' : '断开会话';
  String get killAction => _en ? 'Disconnect' : '断开';
  String killSessionConfirm(String username, String tty) => _en
      ? 'Kill the active session of user "$username" on TTY "$tty"?'
      : '确定要强行断开用户 "$username" 在终端 "$tty" 的会话吗？';
  String get omServers => _en ? 'O&M Servers' : '运维服务器';
  String get notConnected => _en ? 'Not Connected' : '未连接';
  String get connectingEllipsis => _en ? 'Connecting...' : '连接中...';

  // ── Network Transfer (Formerly LAN Share) ──
  String get lanShare => _en ? 'Network Transfer' : '网络传输';
  String get networkIncomingTransferTitle =>
      _en ? 'Incoming network transfer' : '收到网络传输请求';
  String networkIncomingTransferDescription(
    String senderId,
    String fileName,
    String fileSize,
  ) => _en
      ? '$senderId wants to send “$fileName” ($fileSize). Accept this file?'
      : '设备 $senderId 希望发送“$fileName”（$fileSize）。是否接收？';
  String get accept => _en ? 'Accept' : '接收';
  String get reject => _en ? 'Reject' : '拒绝';
  String get clear => _en ? 'Clear' : '清空';
  String get lanShareScan => _en ? 'Scan for nearby devices' : '扫描附近设备';
  String get lanShareScanning =>
      _en ? 'Scanning for nearby devices' : '正在扫描附近设备';
  String get lanShareRadarHint =>
      _en ? 'Scanning nearby devices...' : '正在雷达扫描附近设备…';
  String get lanShareRadarStoppedHint => _en ? 'Scanning paused' : '扫描已暂停';
  String get lanShareNoDevices => _en ? 'No nearby devices found' : '未找到附近设备';
  String get lanShareNoDevicesRefreshHint => _en
      ? 'No devices found. Tap refresh icon to scan again.'
      : '未找到附近设备，请点击右上角图标重新刷新';
  String get lanShareInitializationFailed =>
      _en ? 'LAN Quick Share failed to initialize.' : '局域网快传初始化失败。';
  String get lanShareWebShare => _en ? 'Web Share' : '网页快传';
  String get lanShareWebShareHint => _en
      ? 'Scan QR code from any browser to transfer files'
      : '无须安装 App，任意浏览器扫码即可收发文件';
  String get lanSharePinPairing => _en ? 'PIN Verification' : 'PIN 码安全配对';
  String get lanSharePinPrompt => _en
      ? 'Enter the 6-digit PIN shown on target device:'
      : '请输入目标设备上显示的 6 位 PIN 码：';
  String get lanSharePinMismatch => _en ? 'Incorrect PIN code' : 'PIN 码不正确';
  String get lanSharePinLocked =>
      _en ? 'Too many failed attempts. Try again in 30s.' : '失败次数过多，请 30 秒后再试';
  String get lanShareTrustDevice => _en ? 'Trust this device' : '信任此设备';
  String get lanShareTrusted => _en ? 'Trusted' : '已信任';
  String get lanShareSendClipboard => _en ? 'Send Clipboard' : '发送剪贴板';
  String get lanShareSendFiles => _en ? 'Send Files' : '发送文件';
  String get lanShareSelectImage => _en ? 'Select Image' : '选择图片';
  String get lanShareSelectVideo => _en ? 'Select Video' : '选择视频';
  String get lanShareSelectFile => _en ? 'Select File' : '选择文件';
  String get lanShareClipboard => _en ? 'Clipboard' : '粘贴板';
  String get lanShareSendFolder => _en ? 'Send Folder' : '发送文件夹';
  String get lanShareSendText => _en ? 'Send Text' : '发送文本';
  String get lanShareSending => _en ? 'Sending...' : '正在发送…';
  String get lanShareReceiving => _en ? 'Receiving...' : '正在接收…';
  String get lanShareCompleted => _en ? 'Completed' : '已完成';
  String get lanShareFailed => _en ? 'Failed' : '失败';
  String get lanShareCancelled => _en ? 'Cancelled' : '已取消';
  String get lanShareRecall => _en ? 'Recall' : '撤回';
  String get lanShareRecalled => _en ? 'Recalled' : '已撤回';
  String get lanShareRecallSuccess => _en ? 'Transfer recalled' : '消息已撤回';
  String get lanShareSavedToGallery =>
      _en ? 'Saved to Photo Gallery' : '已保存至系统相册';
  String get lanShareSavedToDownloads =>
      _en ? 'Saved to Downloads' : '已保存至下载目录';
  String get lanShareSaveFailed => _en ? 'Failed to save file' : '保存文件失败';
  String get lanShareOpenBrowser => _en ? 'Open Link' : '打开链接';
  String get lanShareConnectServer => _en ? 'Connect Server' : '一键连接服务器';
  String get lanShareCopyText => _en ? 'Copy Text' : '复制文本';
  String get lanShareCopyAll => _en ? 'Copy All' : '全文复制';
  String get lanShareSelectToCopy => _en ? 'Select to Copy' : '选择复制';
  String get lanShareSendToNearby => _en ? 'Send to nearby device' : '发送至附近设备';
  String get lanShareTransferHistory => _en ? 'Transfer History' : '传输历史';
  String get lanShareNoHistory => _en ? 'No transfer history yet' : '暂无传输历史';
  String get lanShareClearHistory => _en ? 'Clear History' : '清空历史';
  String get lanShareFileExpired =>
      _en ? 'Expired (Auto-deleted after 7 days)' : '已过期 (7天自动销毁)';
  String get lanShareDragDropHint =>
      _en ? 'Drop files or folders here to send' : '拖拽文件或文件夹到此处直接发送';
  String get lanShareStorageFull =>
      _en ? 'Insufficient disk space' : '磁盘剩余空间不足';
  String get lanShareExport => _en ? 'Save to Device' : '保存到本地';
  String get lanShareOffline => _en ? 'Offline' : '离线';
  String get lanShareOnline => _en ? 'Online' : '在线';
  String get lanShareDeviceOfflineHint => _en
      ? 'Device is offline. You can view history, but cannot send new messages.'
      : '设备处于离线状态，可查看历史记录，但无法发送新消息。';
  String get lanShareClearChatHistory => _en ? 'Clear Chat History' : '清空聊天记录';
  String get lanShareForgetDevice => _en ? 'Forget Device' : '忘记设备';
  String get lanShareForgetConfirm => _en ? 'Unpair Device' : '解除配对';
  String get lanShareForgetConfirmMessage => _en
      ? 'Unpairing prevents sending new messages until re-authenticated. History is kept.'
      : '解除配对后将无法发消息直到重新认证。历史记录会保留。';
  String get lanShareReauthenticate => _en ? 'Re-authenticate' : '重新发起认证';
  String get lanShareOfflineReauthHint =>
      _en ? 'Offline. Re-authenticate when online.' : '对方已离线，恢复在线后可重新认证。';
  String get lanShareDeleteMessage => _en ? 'Delete Message' : '删除消息';
  String get lanShareChatInputHint => _en ? 'Type a message...' : '输入消息...';
  String get lanShareMessageSummaryRecalled => _en ? '[Recalled]' : '[已撤回]';
  String get lanShareMessageSummaryImage => _en ? '[Image]' : '[图片]';
  String get lanShareMessageSummaryVideo => _en ? '[Video]' : '[视频]';
  String get lanShareMessageSummaryAudio => _en ? '[Audio]' : '[音频]';
  String get lanShareMessageSummaryFile => _en ? '[File]' : '[文件]';
  String get lanShareScanOrAdd => _en ? 'Scan/Add Device' : '扫码/手动添加';
  String get lanShareManualConnect => _en ? 'Manual Connection' : '手动输入 IP 连接';
  String get lanShareInputIpPort => _en
      ? 'Enter IP:Port (e.g. 192.168.1.100:53317)'
      : '输入 IP:端口 (例如 192.168.1.100:53317)';
  String get lanShareConnect => _en ? 'Connect' : '连接';
  String get lanShareScanQrCode => _en ? 'Scan QR Code' : '扫码连接';
  String get lanShareInvalidAddress => _en ? 'Invalid IP address' : '无效的 IP 地址';
  String get lanShareAddressAmbiguous => _en
      ? 'Multiple LAN addresses are available. Select one manually.'
      : '检测到多个局域网地址，请手动选择。';
  String get lanShareAddressUnavailable =>
      _en ? 'No usable LAN address is currently available.' : '当前没有可用的局域网地址。';
  String get lanShareAddressOverrideStale => _en
      ? 'The selected IP is no longer assigned to this device.'
      : '所选 IP 已不属于本机网络接口，请重新选择。';
  String get lanShareCameraPermissionDenied =>
      _en ? 'Camera permission denied' : '无法访问相机，请授予相机权限';
  String get lanShareDeviceList => _en ? 'Devices' : '设备列表';

  // AI chat
  String get newChat => _en ? 'New chat' : '新对话';
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

  // Settings and feature configuration
  String get appearance => _en ? 'Appearance' : '外观';
  String get toolsAndAutomation => _en ? 'Tools & Automation' : '工具与自动化';
  String get aiSkillsHint => _en
      ? 'Manage custom AI prompts, workflows, and references'
      : '管理自定义 AI 提示词、工作流及规则说明';
  String get mcpServer => _en ? 'MCP Server' : 'MCP Server';
  String get mcpServerHint => _en
      ? 'Streamable HTTP server for CLI agent integrations.'
      : '供 Codex、Claude Code、Gemini CLI 使用的本地 Streamable HTTP 端点。';
  String get mcpHost => _en ? 'Host' : '主机';
  String get mcpPort => _en ? 'Port' : '端口';
  String get mcpServerToken => _en ? 'Token' : 'Token';
  String get mcpClientConfiguration => _en ? 'Client configuration' : '客户端配置';
  String get mcpCheckPort => _en ? 'Check port' : '检查端口';
  String get mcpRestart => _en ? 'Restart Server' : '重启 MCP Server';
  String get mcpRegenerateToken => _en ? 'Regenerate Token' : '重新生成 Token';
  String get mcpCopyCodex => _en ? 'Copy Codex' : '复制 Codex 配置';
  String get mcpCopyClaude => _en ? 'Copy Claude' : '复制 Claude 命令';
  String get mcpCopyGemini => _en ? 'Copy Gemini' : '复制 Gemini 配置';
  String get mcpApprovalMode =>
      _en ? 'External MCP approval mode' : '外部 MCP 审核模式';
  String get mcpReviewConfiguredTools =>
      _en ? 'Dangerous operations require review' : '危险操作二次审核';
  String get mcpReviewConfiguredToolsHint => _en
      ? 'Tools selected in the Local MCP Console enter the SSH Mobile approval queue when a call is risky.'
      : '在本地 MCP 控制台选中的 Tool，在本次调用确实有风险时进入 SSH Mobile 审批队列。';
  String get mcpTrustedAgent =>
      _en ? 'Full access (trusted Agent)' : '完整权限（信任 Agent）';
  String get mcpTrustedAgentHint => _en
      ? 'Selected exposed tools execute without interactive SSH Mobile review.'
      : '在本地 MCP 控制台选中的对外 Tool 不再进入 SSH Mobile 的交互式二次审核。';
  String get mcpTrustedAgentActive =>
      _en ? 'Automatic execution enabled' : '已启用自动执行';
  String get mcpTrustedAgentActiveHint => _en
      ? 'This setting applies immediately to new external MCP calls.'
      : '此设置立即作用于新的外部 MCP 调用。';
  String get mcpTrustedAgentSafetyBoundary => _en
      ? 'Loopback authentication, target binding, input validation, secret filtering, blocked paths, and destructive command restrictions remain active.'
      : '回环监听、身份验证、目标绑定、参数校验、秘密过滤、敏感路径和危险命令限制仍然有效。';
  String get mcpSecondaryReviewTools =>
      _en ? 'Tools requiring secondary review' : '需要二次审核的 Tools';
  String get mcpSecondaryReviewToolsHint => _en
      ? 'Configure external exposure and secondary review per Tool in the Local MCP Console.'
      : '请在本地 MCP 控制台按 Tool 配置对外暴露和二次审核。';
  String get mcpNoReviewTools =>
      _en ? 'No reviewable tools available.' : '当前没有可配置的审核 Tool。';
  String get mcpToolPolicyConsoleTitle => _en
      ? 'Configure Tool policy in Local MCP Console'
      : '在本地 MCP 控制台配置 Tool 策略';
  String get mcpToolPolicyConsoleHint => _en
      ? 'External exposure and secondary review are configured per Tool there.'
      : 'Tool 的对外暴露和二次审核统一在本地 MCP 控制台逐项配置。';
  String get mcpToolPolicyConsoleDetails => _en
      ? 'Hard hidden and blocked rules remain enforced and cannot be enabled here.'
      : '永久隐藏和阻断规则仍然有效，不能通过控制台绕过。';
  String get mcpToolPolicyTitle =>
      _en ? 'Tool exposure and review' : 'Tool 暴露与二次审核';
  String get mcpToolPolicyHint => _en
      ? 'Exposure is shared across modes; review settings apply only in review mode.'
      : '两种模式共用对外暴露配置；二次审核设置仅在审核模式生效。';
  String get mcpExposeExternally => _en ? 'Expose externally' : '对外暴露';
  String get mcpSecondaryReview => _en ? 'Secondary review' : '二次审核';
  String get mcpReviewRequired =>
      _en ? 'Review configuration required' : '需先配置二次审核';
  String get mcpExecutable => _en ? 'Executable' : '可直接执行';
  String get mcpNoConfigurableTools =>
      _en ? 'No configurable tools available.' : '当前没有可配置的 Tool。';
  String get mcpNotExposed => _en ? 'Not exposed' : '未对外暴露';
  String get mcpHidden => _en ? 'Hidden' : '隐藏';
  String get mcpHardHidden => _en ? 'Hidden by hard rule' : '硬规则隐藏';
  String get mcpBlocked => _en ? 'Blocked' : '已阻断';
  String get mcpReviewNotApplicable => _en ? 'No dynamic review' : '无需动态审核';
  String get mcpHardBoundaryHint => _en
      ? 'This Tool is hidden or blocked by a hard security rule and cannot be enabled.'
      : '该 Tool 由硬安全规则隐藏或阻断，不能通过配置启用。';
  String get mcpTrustedAgentWarningTitle =>
      _en ? 'Enable full access for external Agents?' : '启用外部 Agent 完整权限？';
  String get mcpTrustedAgentWarningBody => _en
      ? 'External Agents may execute write and deletion tools continuously. Codex, Claude Code, or another MCP client may enable automatic approval. SSH Mobile still blocks hidden tools, sensitive paths, invalid targets, and other hard-prohibited operations. Existing pending approvals will be rejected. This takes effect immediately.'
      : '外部 Agent 可能连续执行写入和删除类 Tool。Codex、Claude Code 或其他 MCP Client 可能启用自动批准。SSH Mobile 仍会阻止隐藏 Tool、敏感路径、无效目标和其他硬性禁止操作。当前待审批请求会被拒绝。本设置立即生效。';
  String get mcpEnableTrustedAgent => _en ? 'Enable full access' : '启用完整权限';
  String get mcpPortAvailable => _en ? 'Port is available' : '端口可用';
  String get mcpPortOccupied =>
      _en ? 'Port in use. Choose another.' : '端口已被占用，请选择其他端口。';
  String get mcpPortInvalidMessage =>
      _en ? 'Port must be between 1024 and 65535.' : '端口必须在 1024 到 65535 之间。';
  String get mcpPortRestartNeeded =>
      _en ? 'Port changes require restart.' : '端口变更需要重启 MCP Server。';
  String get mcpStopped => _en ? 'MCP Server stopped' : 'MCP Server 已停止';
  String get mcpCheckingPort => _en ? 'Checking port...' : '正在检查端口...';
  String get mcpStarting =>
      _en ? 'Starting MCP Server...' : '正在启动 MCP Server...';
  String mcpRunningAt(String url) => _en ? 'Running at $url' : '运行中：$url';
  String get mcpFailed => _en ? 'MCP Server failed' : 'MCP Server 启动失败';
  String get mcpTokenRegenerated =>
      _en ? 'MCP token regenerated' : 'MCP Token 已重新生成';
  String get mcpCopied => _en ? 'MCP config copied' : 'MCP 配置已复制';
  String get mcpApprovalQueueTitle => _en ? 'MCP approvals' : 'MCP 审批队列';
  String get mcpApprovalQueueSubtitle =>
      _en ? 'Review external MCP actions before execution' : '执行外部 MCP 操作前进行审核';
  String get mcpNoPendingApprovals => _en ? 'No pending approvals' : '暂无待审批操作';
  String get mcpApprovalQueueEmptyMessage => _en
      ? 'Write-capable MCP calls will appear here before they run.'
      : '需要写入或改变状态的 MCP 请求会在执行前显示在这里。';
  String get mcpApprovalTarget => _en ? 'Target' : '目标';
  String get mcpApprovalReason => _en ? 'Reason' : '原因';
  String get mcpApprovalRequested => _en ? 'Requested' : '请求时间';
  String get mcpApprovalPath => _en ? 'Path' : '路径';
  String get mcpApprovalBytes => _en ? 'Bytes' : '字节';
  String get mcpApprovalCommand => _en ? 'Command' : '命令';
  String get mcpApprovalPreview => _en ? 'Preview' : '预览';
  String get mcpApprovalApprove => _en ? 'Approve' : '批准';
  String get mcpApprovalExecuting => _en ? 'Executing…' : '执行中…';
  String get mcpApprovalWaiting => _en ? 'Waiting for review' : '等待审核';
  String get mcpRecentActivity => _en ? 'Recent activity' : '最近活动';
  String get mcpActivitySubtitle =>
      _en ? 'Redacted MCP server activity' : '已脱敏的 MCP Server 活动记录';
  String get mcpActivityAll => _en ? 'All' : '全部';
  String get mcpActivityClear => _en ? 'Clear activity' : '清空活动';
  String get mcpActivityEmpty => _en ? 'No activity recorded.' : '暂无活动记录。';
  String get mcpActivityClearTitle =>
      _en ? 'Clear MCP activity?' : '清空 MCP 活动记录？';
  String get mcpActivityClearMessage => _en
      ? 'This only removes local, redacted activity metadata.'
      : '这只会移除本机保存的脱敏活动元数据。';
  String get mcpActivitySuccess => _en ? 'Success' : '成功';
  String get mcpActivityDenied => _en ? 'Denied' : '已拒绝';
  String get mcpActivityFailed => _en ? 'Failed' : '失败';
  String get security => _en ? 'Security & privacy' : '安全与隐私';
  String get credentialCache => _en ? 'Cache SSH credentials' : '缓存 SSH 凭证到内存';
  String get credentialCacheHint => _en
      ? 'Cache credentials this session to reduce keychain prompts.'
      : '在本次会话内缓存密码、私钥和 API Key，可减少重复的密钥链弹窗。';
  String get credentialCacheTimeout => _en ? 'Cache timeout' : '缓存时长';
  String get notificationServerNames =>
      _en ? 'Show server names in background notifications' : '后台通知显示服务器名';
  String get notificationServerNamesHint => _en
      ? 'Off by default to prevent server exposure on lock screen.'
      : '默认关闭。保持关闭可避免在锁屏通知中暴露服务器名称。';
  String get dataBackup => _en ? 'Data backup' : '数据备份';
  String get sftpLimits => _en ? 'SFTP file limits' : 'SFTP 文件限制';
  String get sftpSettings => _en ? 'SFTP settings' : 'SFTP 设置';
  String get sftpLimitsHint => _en
      ? 'Client limits for file download, preview, and edit.'
      : '用于客户端下载、预览和编辑的内存保护限制。';
  String get sftpDownloadLimit => _en ? 'Download Limit' : '下载限制';
  String get sftpTextPreviewLimit => _en ? 'Text Preview' : '文本预览限制';
  String get sftpRichPreviewLimit => _en ? 'Image/PDF Preview' : '图片/PDF 预览限制';
  String get sftpEditLimit => _en ? 'Text Edit' : '文本编辑限制';
  String get sftpLimitDialogHint => _en
      ? 'Enter a size in MB. Decimal values are allowed.'
      : '请输入 MB 单位大小，支持小数。';
  String get sftpLimitInvalid =>
      _en ? 'Enter a value greater than 0.' : '请输入大于 0 的数值。';
  String sftpLimitRange(String min, String max) =>
      _en ? 'Allowed range: $min - $max' : '允许范围：$min - $max';
  String get terminalAppearance => _en ? 'Terminal appearance' : '终端外观';
  String get terminalAppearanceHint =>
      _en ? 'Theme and font used by terminal sessions.' : '终端会话使用的配色和字体。';
  String get lanShareSettings => _en ? 'LAN Share Settings' : '局域网共享设置';
  String get lanDeviceAlias => _en ? 'Device alias / name' : '设备昵称 / 名称';
  String get lanDeviceId => _en ? 'Persistent device identifier' : '固定设备标识符';
  String get lanRelayServer => _en ? 'Public relay server' : '公网中继服务器';
  String get lanRelayClear => _en ? 'Clear enrollment' : '清除注册';
  String get lanRelayConnect => _en ? 'Connect' : '连接';
  String get lanRelayConnecting => _en ? 'Connecting…' : '连接中…';
  String get lanRelayDisconnect => _en ? 'Disconnect' : '断开连接';
  String get lanRelayEnrollmentRequired => _en ? 'Enrollment required' : '需要注册';
  String get lanRelayEnrollmentToken =>
      _en ? 'Temporary enrollment token' : '临时注册 Token';
  String get lanRelayEnrollmentTokenHint =>
      _en ? 'Required for first enrollment; never saved' : '首次注册需要；不会保存';
  String get lanRelayFailed => _en ? 'Connection failed' : '连接失败';
  String get lanRouteDirect => _en ? 'Direct' : '直连';
  String get lanRouteRelay => _en ? 'Relay' : '中继';
  String get lanRouteUnknown => _en ? 'Route pending' : '路线待定';
  String get lanPermissions => _en ? 'Permissions' : '权限';
  String get lanNotificationPermission =>
      _en ? 'Background notification permission' : '后台通知权限';
  String get lanCameraPermission =>
      _en ? 'Camera permission (scan QR code)' : '相机权限（扫描二维码）';
  String get openMcpSettings => _en ? 'MCP settings' : 'MCP 设置';
  String get openMcpConsole => _en ? 'Open console' : '打开控制台';
  String get openAiSkills => _en ? 'AI Skills' : 'AI Skills';
  String get moreActions => _en ? 'More actions' : '更多操作';
  String get featureSettings => _en ? 'Feature settings' : '功能设置';
  String get exportAppData => _en ? 'Export app data' : '导出应用数据';
  String get importAppData => _en ? 'Import app data' : '导入应用数据';
  String get exportComplete => _en ? 'Export complete' : '导出完成';
  String get importComplete => _en ? 'Import complete' : '导入完成';
  String get importAction => _en ? 'Import' : '导入';
  String get importAppDataWarning => _en
      ? 'Importing replaces servers, window history, AI chats, settings, and skills. Keys must be reconfigured. Continue?'
      : '导入会替换当前设备上的服务器、窗口历史、AI 聊天、AI 设置和自定义 Skills。密码、私钥和 API Key 需要重新配置。是否继续？';
  String get backupContainsSecrets => _en
      ? 'Passwords, keys, and API tokens are not exported. Reconfigure after import.'
      : '密码、私钥和 API Key 不会导出，导入后需要重新配置。';
  String exportFailed(Object error) =>
      _en ? 'Export failed: $error' : '导出失败：$error';
  String importFailed(Object error) =>
      _en ? 'Import failed: $error' : '导入失败：$error';
  String get developerMode => _en ? 'Developer Mode' : '开发者模式';
  String get developerModeHint => _en
      ? 'Show performance metrics and debugging information.'
      : '显示性能指标和调试信息。';
  String get developerPanel => _en ? 'Developer Panel' : '开发者面板';
  String get developerPanelFloating =>
      _en ? 'Show as floating ball' : '浮窗显示开发者面板';
  String get developerPanelFloatingHint => _en
      ? 'View the developer panel as a floating ball on every page.'
      : '在各页面以悬浮球形式查看开发者面板。';
}

class TerminalStrings {
  final AppLanguage language;

  const TerminalStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get connected => _en ? 'Connected' : '已连接';
  String get connecting => _en ? 'Connecting' : '连接中';
  String get disconnected => _en ? 'Disconnected' : '已断开';
  String get fontSize => _en ? 'Font' : '字号';
  String get defaultTerminal => _en ? 'SSH Terminal' : 'SSH 终端';
  String get currentServer => _en ? 'current server' : '当前服务器';
  String get unknown => _en ? 'unknown' : '未知错误';
  String get smallerFont => _en ? 'Smaller Font' : '缩小字号';
  String get largerFont => _en ? 'Larger Font' : '放大字号';
  String get switchToLightMode => _en ? 'Light Mode' : '切换到浅色主题';
  String get switchToDarkMode => _en ? 'Dark Mode' : '切换到深色主题';
  String get newWindow => _en ? 'New Window' : '新建终端窗口';
  String get renameWindow => _en ? 'Rename Window' : '重命名窗口';
  String get switchWindow => _en ? 'Switch Window' : '切换终端窗口';
  String get disconnect => _en ? 'Disconnect' : '断开连接';
  String get reconnect => _en ? 'Reconnect' : '重连';
  String get reconnecting => _en ? 'Reconnecting...' : '正在重连...';
  String get connectingSession => _en ? 'Connecting to the terminal' : '正在连接终端';
  String get connectingSessionHint =>
      _en ? 'Negotiating secure session. Please wait.' : '正在协商安全会话，通常只需片刻。';
  String get connectionInterrupted =>
      _en ? 'Terminal connection interrupted' : '终端连接已中断';
  String get connectionInterruptedHint => _en
      ? 'Terminal output preserved. Reconnect to resume.'
      : '终端输出已保留，可重新连接后继续当前会话。';
  String get terminalConnectionError =>
      _en ? 'Could not connect to the terminal' : '无法连接终端';
  String get terminalConnectionErrorStatus => _en ? 'Error' : '错误';
  String get terminalConnectionErrorHint => _en
      ? 'Check server and network status, then retry.'
      : '请检查服务器和网络状态，然后重试连接。';
  String get manageWindows => _en ? 'Manage Windows' : '管理窗口';
  String get closeWindow => _en ? 'Close window' : '关闭窗口';
  String get restoringTerminalOutput =>
      _en ? 'Restoring terminal output…' : '正在恢复终端输出…';
  String get closeDisconnected => _en ? 'Close Disconnected' : '关闭已断开的窗口';
  String get openNewWindow => _en ? 'Open New Window' : '打开新窗口';
  String createFrom(String name) =>
      _en ? 'Create new window from "$name"?' : '使用 "$name" 创建新的 SSH 窗口？';
  String get cancel => _en ? 'Cancel' : '取消';
  String get editServer => _en ? 'Edit server' : '编辑服务器';
  String get addServer => _en ? 'Add server' : '新增服务器';
  String get create => _en ? 'Create' : '创建';
  String connectingTo(String name) =>
      _en ? 'Connecting to $name' : '正在连接 $name';
  String get openingNewWindow =>
      _en ? 'Opening new window...' : '正在打开新的 SSH 窗口...';
  String connectionFailed(String message) =>
      _en ? 'Connection failed: $message' : '连接失败：$message';
  String tmuxMissingHint(String text) => _en
      ? 'Connection failed: $text\nPlease install tmux manually on the server and try again.'
      : '连接失败：$text\n请先在服务器上手动安装 tmux 后再重试。';
  String get currentWindow => _en ? 'Current window' : '当前窗口';
  String get save => _en ? 'Save' : '保存';
  String get windowName => _en ? 'Window name' : '窗口名称';
  String get duplicateWindowName =>
      _en ? 'Window name already exists' : '窗口名称已存在';
  String get addShortcut => _en ? 'Add Command' : '添加快捷命令';
  String get complexKeyboard => _en ? 'Advanced Keyboard' : '复杂键盘';
  String get advancedKeyboardHint => _en
      ? 'Navigation, controls, function keys, and multiline.'
      : '集中使用导航键、控制键、功能键和多行输入。';
  String get windowsKeyboard => _en ? 'Windows Keyboard' : 'Windows 键盘';
  String get windowsKeyboardHint => _en
      ? 'Full PC layout with F1-F12, modifiers, symbols, and multiline commands.'
      : '包含 F1-F12、修饰键、Shell 特殊符号与复杂命令编辑。';
  String get keyboardComposeMode => _en ? 'Compose' : '编辑输入';
  String get keyboardDirectMode => _en ? 'Direct' : '直接发送';
  String get customizeQuickKeys => _en ? 'Customize quick keys' : '自定义快捷键';
  String get keyboardLetters => _en ? 'Letters' : '字母';
  String get keyboardNavigation => _en ? 'Navigation' : '导航';
  String get keyboardSpace => _en ? 'Space' : '空格';
  String get keyboardBackspace => _en ? 'Backspace' : '退格';
  String get keyboardEnter => _en ? 'Enter' : '回车';
  String get quickKeysTitle => _en ? 'Customize Quick Keys' : '自定义快捷栏';
  String get quickKeysHint => _en
      ? 'Choose built-in keys shown beside Ctrl and Alt. Custom commands remain visible.'
      : '选择显示在 Ctrl、Alt 旁的内置键；自定义命令始终保留。';
  String get quickKeysAtLeastOne =>
      _en ? 'Keep at least one built-in quick key.' : '至少保留一个内置快捷键。';
  String get resetQuickKeys => _en ? 'Reset defaults' : '恢复默认';
  String get done => _en ? 'Done' : '完成';
  String get shellSymbols => _en ? 'Shell Symbols' : 'Shell 符号';
  String get controlShortcuts => _en ? 'Control Keys' : '控制快捷键';
  String get moreKeys => _en ? 'More Shortcuts' : '更多快捷键';
  String get moreKeysHint =>
      _en ? 'Shell navigation and control keys.' : '常用的 Shell 导航键与控制键。';
  String get multilineHint =>
      _en ? 'Paste or type multiline input' : '粘贴或输入多行文本';
  String get commandComposer => _en ? 'Command composer' : '命令编辑器';
  String get commandComposerHint => _en
      ? 'Enter sends · Shift+Enter adds a line · Up/Down recalls sent commands'
      : 'Enter 发送 · Shift+Enter 换行 · 上下方向键浏览已发送命令';
  String get pasteIntoCommand => _en ? 'Paste into command' : '粘贴到命令编辑器';
  String get clearCommand => _en ? 'Clear command' : '清空命令';
  String get send => _en ? 'Send' : '发送';
  String get label => _en ? 'Label' : '标签';
  String get command => _en ? 'Command' : '命令';
  String get add => _en ? 'Add' : '添加';
  String get removeShortcut => _en ? 'Remove Shortcut' : '删除快捷命令';
  String removeShortcutContent(String label) =>
      _en ? 'Remove "$label"?' : '删除 "$label"？';
  String get remove => _en ? 'Remove' : '删除';
  String get selectCopy => _en ? 'Select Copy' : '选择复制';
  String get copy => _en ? 'Copy' : '复制';
  String get paste => _en ? 'Paste' : '粘贴';
  String get closeDisconnectedTitle =>
      _en ? 'Close disconnected window' : '关闭已断开的窗口';
  String disconnectContent(String name) =>
      _en ? 'Disconnect "$name"?' : '断开 "$name"？';
  String closeDisconnectedContent(String name) => _en
      ? '"$name" is already disconnected. Close this window?'
      : '"$name" 已经断开。关闭这个窗口吗？';
  String get copyAll => _en ? 'Copy all' : '复制全部';
  String get terminalOutput => _en ? 'Terminal output' : '终端输出';
  String get terminalOutputSnapshot => _en ? 'Output Snapshot' : '终端输出快照';
  String get terminalOutputSelectionHint =>
      _en ? 'Select text to copy output.' : '选择任意文本可复制部分输出。';
  String get readOnly => _en ? 'Read-only' : '只读';
  String get copyingTerminalOutput => _en ? 'Copying output...' : '正在复制终端输出…';
  String get copyTerminalOutputFailed =>
      _en ? 'Failed to copy output. Retry.' : '无法复制终端输出，请重试。';
  String terminalOutputSummary(int lineCount, int characterCount) {
    if (!_en) return '$lineCount 行 · $characterCount 个字符';
    final lines = lineCount == 1 ? 'line' : 'lines';
    final characters = characterCount == 1 ? 'character' : 'characters';
    return '$lineCount $lines · $characterCount $characters';
  }

  String get moreActions => _en ? 'More Actions' : '更多操作';
  String get terminalAppearance => _en ? 'Terminal appearance' : '终端外观';
  String get navigationShell => _en ? 'Navigation' : '导航与 Shell';
  String get editControl => _en ? 'Edit/Control' : '编辑与控制';
  String get functionKeys => _en ? 'Function Keys' : '功能键';
}
