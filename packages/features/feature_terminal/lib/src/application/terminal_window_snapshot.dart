// 把 SSH 终端快照映射成页面使用的窗口模型。

import 'package:ssh_core/ssh_core.dart';

import '../domain/terminal_models.dart';

/// 映射连接状态。
TerminalLinkState terminalLinkStateOf(SshConnectionState state) =>
    switch (state) {
      SshConnectionState.disconnected => TerminalLinkState.disconnected,
      SshConnectionState.connecting => TerminalLinkState.connecting,
      SshConnectionState.connected => TerminalLinkState.connected,
      SshConnectionState.error => TerminalLinkState.error,
    };

/// 映射一个终端窗口。输出流留在 SSH Capability。
TerminalWindowSnapshot terminalWindowSnapshotOf(SshTerminalSession session) {
  return TerminalWindowSnapshot(
    id: session.id,
    connectionId: session.connectionId,
    connectionName: session.connectionName,
    displayName: session.displayName,
    tmuxSessionName: session.tmuxSessionName,
    tmuxAutoDeleteSeconds: session.tmuxAutoDeleteSeconds,
    fontSize: session.fontSize,
    state: terminalLinkStateOf(session.state),
    errorMessage: session.errorMessage,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    estimatedMemoryBytes: session.estimatedMemoryBytes,
  );
}

/// 关闭当前窗口后，优先返回仍连接的其他窗口。
TerminalWindowSnapshot? terminalNextWindowAfter(
  SshTerminalCapability? capability,
  String closedSessionId,
) {
  if (capability == null) return null;
  final otherSessions = capability.sessions
      .where((session) => session.id != closedSessionId)
      .toList()
      .reversed;
  for (final session in otherSessions) {
    if (session.isConnected) return terminalWindowSnapshotOf(session);
  }
  if (otherSessions.isEmpty) return null;
  return terminalWindowSnapshotOf(otherSessions.first);
}
