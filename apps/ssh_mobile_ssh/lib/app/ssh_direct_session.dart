// 直接 TCP SSH 会话的 App 边界。
//
// Capability 只依赖这个契约。dartssh2 的 Client 和 Shell 留在直接连接
// 适配器里，测试可以注入不打开真实网络的实现。

import 'package:connection_core/connection_core.dart';
import 'package:ssh_core/ssh_core.dart';

/// 已认证的直接 TCP SSH 连接。调用方负责关闭。
abstract interface class SshDirectSession {
  /// 打开交互 Shell。
  Future<SshDirectShell> openShell({
    required int width,
    required int height,
    required String terminalType,
  });

  /// 关闭底层 Client。重复调用必须幂等。
  Future<void> close();
}

/// 一个交互 Shell 通道。
abstract interface class SshDirectShell {
  /// 远端标准输出。
  Stream<List<int>> get stdout;

  /// 远端标准错误。
  Stream<List<int>> get stderr;

  /// Shell 结束时完成。
  Future<void> get done;

  /// 写入终端输入。
  void write(List<int> data);

  /// 更新远端 PTY 尺寸。
  void resizeTerminal(int width, int height);

  /// 关闭 Shell。
  Future<void> close();
}

/// 建立一条直接 TCP SSH 连接。
///
/// [persistHostKeyTrust] 为 false 时只返回候选信任，由保存编排统一提交。
typedef SshDirectConnector =
    Future<SshDirectSession> Function(
      ConnectionConfig config, {
      required SshHostKeyConfirmation? onUnknownHostKey,
      required bool persistHostKeyTrust,
      SshCredentials? credentials,
    });

/// 把可能含有凭据的异常收成可展示的非敏感文本。
String sshPublicError(Object error) {
  final text = error.toString();
  final lower = text.toLowerCase();
  if (lower.contains('password') ||
      lower.contains('passphrase') ||
      lower.contains('private key') ||
      lower.contains('privatekey')) {
    return 'SSH connection failed.';
  }
  return text;
}
