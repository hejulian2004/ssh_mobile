// 直接 TCP SSH 的生产连接器。
//
// 不注入 native ReliableStream，因此连接只走原始 TCP。跳板主机在这个
// App 里没有独立转发实现，必须在打开 Socket 前失败，避免用户以为走了跳板。

import 'dart:typed_data';

import 'package:connection_core/connection_core.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:ssh_core/ssh_core.dart';

import 'ssh_direct_session.dart';

/// 使用 [SshClientFactory] 打开已认证 Client。
typedef SshClientOpener =
    Future<SSHClient> Function(
      ConnectionConfig config, {
      required SshHostKeyConfirmation? onUnknownHostKey,
      required bool persistHostKeyTrust,
      SshCredentials? credentials,
    });

/// 把公共 Client 工厂适配成直接 TCP 打开器。
SshClientOpener sshCoreClientOpener(SshClientFactory factory) {
  return (
    config, {
    required onUnknownHostKey,
    required persistHostKeyTrust,
    credentials,
  }) {
    return factory.connectClient(
      config,
      credentials: credentials,
      onUnknownHostKey: onUnknownHostKey,
      persistHostKeyTrust: persistHostKeyTrust,
    );
  };
}

/// 创建不使用网络传输运行时的 SSH 连接器。
SshDirectConnector directTcpConnector({required SshClientOpener openClient}) {
  return (
    config, {
    required onUnknownHostKey,
    required persistHostKeyTrust,
    credentials,
  }) async {
    final jumpHost = config.jumpHost?.trim();
    if (jumpHost != null && jumpHost.isNotEmpty) {
      throw StateError(
        'This SSH app connects directly and does not use a jump host.',
      );
    }
    final client = await openClient(
      config,
      onUnknownHostKey: onUnknownHostKey,
      persistHostKeyTrust: persistHostKeyTrust,
      credentials: credentials,
    );
    return _DartSshDirectSession(client);
  };
}

final class _DartSshDirectSession implements SshDirectSession {
  _DartSshDirectSession(this._client);

  final SSHClient _client;
  bool _closed = false;

  @override
  Future<SshDirectShell> openShell({
    required int width,
    required int height,
    required String terminalType,
  }) async {
    final shell = await _client
        .shell(
          pty: SSHPtyConfig(width: width, height: height, type: terminalType),
        )
        .timeout(const Duration(seconds: 15));
    return _DartSshShell(shell);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // dartssh2 的 close() 是同步的，并在返回前完成 transport.done。
    _client.close();
    await _client.done;
  }
}

final class _DartSshShell implements SshDirectShell {
  _DartSshShell(this._shell);

  final SSHSession _shell;

  @override
  Stream<List<int>> get stdout => _shell.stdout;

  @override
  Stream<List<int>> get stderr => _shell.stderr;

  @override
  Future<void> get done async {
    await _shell.done;
  }

  @override
  void write(List<int> data) {
    _shell.write(Uint8List.fromList(data));
  }

  @override
  void resizeTerminal(int width, int height) {
    _shell.resizeTerminal(width, height);
  }

  @override
  Future<void> close() async {
    // Session.close() 只同步发起通道关闭。done 要等对端回 Close，
    // 不能在这里等待，否则后续 Client.close() 无法销毁传输。
    _shell.close();
  }
}
