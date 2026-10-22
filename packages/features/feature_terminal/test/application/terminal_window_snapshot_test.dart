import 'package:feature_terminal/src/application/terminal_window_snapshot.dart';
import 'package:feature_terminal/src/domain/terminal_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

import '../fakes/terminal_test_fakes.dart';

void main() {
  test('window snapshot keeps page fields and shell-quoted tmux command', () {
    final session = buildTerminalSession(
      id: 'session-1',
      connectionId: 'connection-1',
      connectionName: 'Production',
      displayName: 'shell',
      state: SshConnectionState.error,
      errorMessage: 'timeout',
      tmuxSessionName: "bob's session",
    );

    final snapshot = terminalWindowSnapshotOf(session);

    expect(snapshot.id, 'session-1');
    expect(snapshot.connectionId, 'connection-1');
    expect(snapshot.connectionName, 'Production');
    expect(snapshot.displayName, 'shell');
    expect(snapshot.state, TerminalLinkState.error);
    expect(snapshot.isConnected, isFalse);
    expect(snapshot.errorMessage, 'timeout');
    expect(snapshot.tmuxAutoDeleteSeconds, 600);
    expect(
      snapshot.tmuxKillCommand,
      "tmux kill-session -t 'bob'\"'\"'s session'",
    );
  });

  test('next window prefers a still-connected session', () async {
    final capability = FakeTerminalCapability(
      sessions: [
        buildTerminalSession(
          id: 'closed',
          connectionId: 'connection-1',
          connectionName: 'Production',
          displayName: 'closed',
          state: SshConnectionState.disconnected,
        ),
        buildTerminalSession(
          id: 'idle',
          connectionId: 'connection-1',
          connectionName: 'Production',
          displayName: 'idle',
          state: SshConnectionState.disconnected,
        ),
        buildTerminalSession(
          id: 'live',
          connectionId: 'connection-1',
          connectionName: 'Production',
          displayName: 'live',
          state: SshConnectionState.connected,
        ),
      ],
    );

    final next = terminalNextWindowAfter(capability, 'closed');
    await capability.close();

    expect(next?.id, 'live');
  });
}
