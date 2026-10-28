import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../domain/lan_share_ports.dart';
import '../../../../services/lan_share/lan_share_models.dart';
import '../../viewmodels/lan_share_viewmodel.dart';
import '../../viewmodels/lan_ui_outcome.dart';

/// 本机媒体发送失败或取消时，显示失败状态和可重试操作。
class LanOutgoingFileStatus extends StatelessWidget {
  const LanOutgoingFileStatus({
    super.key,
    required this.message,
    required this.strings,
    required this.foreground,
    required this.onRetry,
  });

  final LanMessage message;
  final LanShareStrings strings;
  final Color foreground;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (!showsOutgoingFileFailure(message)) return const SizedBox.shrink();
    final path = message.localPath;
    final sourceExists =
        path != null && path.isNotEmpty && File(path).existsSync();
    final canRetry = canRetryOutgoingLanFile(
      message,
      sourceExists: sourceExists,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_rounded, size: 14, color: foreground),
          const SizedBox(width: 4),
          Text(
            strings.lanShareFailed,
            style: TextStyle(fontSize: 11, color: foreground),
          ),
          if (canRetry) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: foreground,
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(strings.retry),
            ),
          ],
        ],
      ),
    );
  }
}

/// 重发一条已经结束的本机媒体消息，并把即时失败显示出来。
Future<void> retryOutgoingLanFile({
  required BuildContext context,
  required LanShareStrings strings,
  required LanShareViewModel viewModel,
  required LanMessage message,
  LanDiscoveredPeer? discovery,
}) async {
  final result = await lanUiIgnored(
    viewModel.retryOutgoingFile(message, discovery: discovery),
  );
  if (!context.mounted || result.failure == null) return;
  final failure = result.failure!;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('${strings.lanShareFailed}: ${failure.message}')),
  );
}
