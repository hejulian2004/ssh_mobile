part of 'terminal_session_viewmodel.dart';

extension TerminalSessionWindowDirectory on TerminalSessionViewModel {
  /// 最近一次 Capability 级错误。Capability 缺失时为空。
  String? get capabilityError =>
      _sshSessionManager.terminalCapability?.errorMessage;

  /// 当前全部终端窗口。
  List<TerminalWindowSnapshot> get windows {
    final capability = _sshSessionManager.terminalCapability;
    if (capability == null) return const [];
    return [
      for (final session in capability.sessions)
        terminalWindowSnapshotOf(session),
    ];
  }

  /// 按会话 ID 查找窗口。
  TerminalWindowSnapshot? windowById(String id) {
    final session = _sshSessionManager.terminalCapability?.getSession(id);
    if (session == null) return null;
    return terminalWindowSnapshotOf(session);
  }

  /// 关闭一个窗口。Capability 缺失时不操作。
  Future<void> disconnectWindow(String id) async {
    final capability = _sshSessionManager.terminalCapability;
    if (capability == null) return;
    await capability.disconnectSession(id);
  }

  /// 关闭 [closedSessionId] 后应切换到的窗口。
  TerminalWindowSnapshot? nextWindowAfter(String closedSessionId) {
    return terminalNextWindowAfter(
      _sshSessionManager.terminalCapability,
      closedSessionId,
    );
  }
}
