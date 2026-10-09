// SSH-only App 的 Host Key 确认对话框。
//
// 未知主机默认拒绝。对话框只展示非敏感指纹，不接收或回显密码。

import 'package:flutter/material.dart';
import 'package:ssh_core/ssh_core.dart';

/// 没有页面绑定时保持失败关闭的 Host Key 提示入口。
final class SshHostKeyPromptGateway {
  /// 当前页面提供的确认回调。
  Future<bool> Function(SshHostKeyPromptRequest request)? prompt;

  /// 请求用户确认；没有页面回调时拒绝。
  Future<bool> confirm(SshHostKeyPromptRequest request) {
    final callback = prompt;
    if (callback == null) return Future<bool>.value(false);
    return callback(request);
  }
}

/// 展示一次 Host Key 信任确认。关闭对话框或拒绝都返回 false。
Future<bool> showSshHostKeyDialog({
  required BuildContext context,
  required String name,
  required String host,
  required int port,
  required String username,
  required String algorithm,
  required String fingerprint,
}) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      return AlertDialog(
        title: const Text('信任主机密钥'),
        content: Text('$name\n$username@$host:$port\n$algorithm\n$fingerprint'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('信任'),
          ),
        ],
      );
    },
  );
  return accepted ?? false;
}
