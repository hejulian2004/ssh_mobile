// 将类型化原生传入传输申请呈现给 Flutter UI 的 V2 宿主。

import 'dart:async';

import 'package:app_ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/lan_share_ports.dart';
import '../notifications/lan_system_notification.dart';
import '../services/lan_receiver_coordinator.dart';
import '../viewmodels/lan_ui_outcome.dart';

/// UI state for the incoming transfer approval dialog.
enum IncomingApprovalUiState {
  idle,
  accepting,
  rejecting,
  retryableFailure,
  retryableRejectFailure,
}

/// Presents one root-level approval dialog at a time for current-protocol
/// QUIC or Relay offers, independently of the selected application route.
class NetworkIncomingTransferHost extends StatefulWidget {
  /// 在 [child] 外创建根宿主。
  const NetworkIncomingTransferHost({super.key, required this.child});

  final Widget child;

  /// 创建根级传入申请状态。
  @override
  State<NetworkIncomingTransferHost> createState() =>
      _NetworkIncomingTransferHostState();
}

class _NetworkIncomingTransferHostState
    extends State<NetworkIncomingTransferHost> {
  final List<IncomingApprovalRequest> _pending = [];
  StreamSubscription<LanPageIncomingOffer>? _nativeSubscription;
  bool _showingDialog = false;

  /// 订阅协调器的类型化传入申请流。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_nativeSubscription != null) return;
    final coordinator = context.read<LanReceiverCoordinator>();
    _nativeSubscription = coordinator.pageIncomingOffers.listen((offer) {
      _handleRequest(
        IncomingApprovalRequest(
          sessionId: offer.transferId,
          senderId: offer.peerId,
          fileName: offer.fileName,
          totalBytes: offer.fileSize,
          expiresAt: DateTime.now().add(coordinator.incomingOfferTimeout),
          accept: offer.accept,
          reject: offer.reject,
        ),
      );
    });
  }

  /// 将不重复的传入审批请求加入队列。
  void _handleRequest(IncomingApprovalRequest request) {
    if (!mounted) return;
    final decision = decideIncomingTransferNotification(_pending, request);
    if (!decision.queued) return;
    final event = decision.event;
    final port = _readNotificationPort(context);
    if (event != null && port != null) unawaited(port.present(event));
    unawaited(_showNext());
  }

  /// 显示下一个审批对话框并应用用户决定。
  Future<void> _showNext() async {
    if (!mounted || _showingDialog || _pending.isEmpty) return;
    _showingDialog = true;
    final request = _pending.removeAt(0);
    if (request.isExpired) {
      await _rejectExpired(request);
      _showingDialog = false;
      if (mounted) unawaited(_showNext());
      return;
    }

    if (!mounted) {
      _showingDialog = false;
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => IncomingApprovalDialog(request: request),
    );

    _showingDialog = false;
    if (mounted) unawaited(_showNext());
  }

  /// 拒绝在对话框显示前已过期的申请。
  Future<void> _rejectExpired(IncomingApprovalRequest request) async {
    final logger = context.read<LanShareLoggerPort>();
    try {
      final result = await request.reject();
      final failure = result.failure;
      if (failure != null) {
        logger.warning(
          'Expired network offer rejection returned failure',
          details: failure.detail,
        );
      }
    } on Object catch (error, stackTrace) {
      logger.warning(
        'Expired network offer rejection failed',
        details: '$error\n$stackTrace',
      );
    }
  }

  /// 取消协调器申请订阅。
  @override
  void dispose() {
    _nativeSubscription?.cancel();
    super.dispose();
  }

  /// 构建被包装的应用子树。
  @override
  Widget build(BuildContext context) => widget.child;
}

/// Dialog presenting one incoming transfer request with retry and error states.
class IncomingApprovalDialog extends StatefulWidget {
  const IncomingApprovalDialog({super.key, required this.request});

  final IncomingApprovalRequest request;

  @override
  State<IncomingApprovalDialog> createState() => _IncomingApprovalDialogState();
}

class _IncomingApprovalDialogState extends State<IncomingApprovalDialog> {
  IncomingApprovalUiState _state = IncomingApprovalUiState.idle;
  String? _errorMessage;
  Timer? _expiryTimer;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    final expiresIn = widget.request.expiresAt.difference(DateTime.now());
    _expiryTimer = Timer(
      expiresIn.isNegative ? Duration.zero : expiresIn,
      _handleTimeout,
    );
  }

  void _handleTimeout() {
    if (!mounted) return;
    _expired = true;
    if (_state == IncomingApprovalUiState.accepting ||
        _state == IncomingApprovalUiState.rejecting) {
      return;
    }
    unawaited(_reject(isTimeout: true));
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  Future<void> _accept() async {
    if (_state == IncomingApprovalUiState.accepting ||
        _state == IncomingApprovalUiState.rejecting) {
      return;
    }
    if (widget.request.isExpired || _expired) {
      await _reject(isTimeout: true);
      return;
    }
    setState(() {
      _state = IncomingApprovalUiState.accepting;
      _errorMessage = null;
    });

    final logger = context.read<LanShareLoggerPort>();
    try {
      final result = await widget.request.accept();
      if (!mounted) return;
      if (result.succeeded) {
        Navigator.of(context).pop();
        return;
      }

      final failure = result.failure!;
      final isExpiredNow = widget.request.isExpired || _expired;
      if (isExpiredNow) {
        await _reject(isTimeout: true);
      } else if (failure.retryable) {
        setState(() {
          _state = IncomingApprovalUiState.retryableFailure;
          _errorMessage = failure.message;
        });
      } else {
        final messenger = ScaffoldMessenger.of(context);
        final strings = context.read<LanShareSettingsPort>().strings;
        Navigator.of(context).pop();
        _showTerminalFailureSnackBar(messenger, strings, failure);
      }
    } on Object catch (error, stackTrace) {
      logger.warning(
        'Incoming transfer approval failed',
        details: '$error\n$stackTrace',
      );
      if (!mounted) return;
      if (widget.request.isExpired || _expired) {
        await _reject(isTimeout: true);
      } else {
        setState(() {
          _state = IncomingApprovalUiState.retryableFailure;
          _errorMessage = error.toString();
        });
      }
    }
  }

  Future<void> _reject({bool isTimeout = false}) async {
    if (_state == IncomingApprovalUiState.rejecting) return;
    setState(() {
      _state = IncomingApprovalUiState.rejecting;
      _errorMessage = null;
    });

    final logger = context.read<LanShareLoggerPort>();
    try {
      final result = await widget.request.reject();
      if (!mounted) return;
      final failure = result.failure;
      if (failure != null) {
        logger.warning(
          'Incoming transfer rejection returned failure',
          details: failure.detail,
        );
        setState(() {
          _state = IncomingApprovalUiState.retryableRejectFailure;
          _errorMessage = failure.message;
        });
        return;
      }
      Navigator.of(context).pop();
    } on Object catch (error, stackTrace) {
      logger.warning(
        'Incoming transfer rejection failed',
        details: '$error\n$stackTrace',
      );
      if (mounted) {
        setState(() {
          _state = IncomingApprovalUiState.retryableRejectFailure;
          _errorMessage = error.toString();
        });
      }
    }
  }

  void _showTerminalFailureSnackBar(
    ScaffoldMessengerState messenger,
    LanShareStrings strings,
    LanUiFailure failure,
  ) {
    final message = switch (failure.kind) {
      LanUiFailureKind.resourceLimit =>
        strings.isEnglish
            ? 'Insufficient storage space for incoming transfer.'
            : '存储空间不足，无法接收文件。',
      LanUiFailureKind.authenticationFailed =>
        strings.isEnglish
            ? 'Transfer peer is not trusted or route unauthorized.'
            : '设备未通过信任校验或未授权传输路由。',
      _ =>
        strings.isEnglish
            ? 'Incoming transfer failed: ${failure.message}'
            : '接收文件失败：${failure.message}',
    };
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.watch<LanShareSettingsPort>().strings;
    final theme = Theme.of(context);
    final inProgress =
        _state == IncomingApprovalUiState.accepting ||
        _state == IncomingApprovalUiState.rejecting;

    return AlertDialog(
      title: Text(strings.networkIncomingTransferTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.networkIncomingTransferDescription(
              widget.request.senderId,
              widget.request.fileName,
              _formatByteCount(widget.request.totalBytes),
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
            ),
          ],
          if (inProgress) ...[
            const SizedBox(height: 12),
            const AppLoadingIndicator(size: 24, strokeWidth: 2.5),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: inProgress ? null : () => _reject(),
          child: Text(
            _state == IncomingApprovalUiState.retryableRejectFailure
                ? (strings.isEnglish ? 'Retry Reject' : '重试拒绝')
                : strings.reject,
          ),
        ),
        if (_state == IncomingApprovalUiState.retryableFailure)
          FilledButton(
            onPressed: inProgress ? null : _accept,
            child: Text(strings.isEnglish ? 'Retry' : '重试'),
          )
        else
          FilledButton(
            onPressed: inProgress ? null : _accept,
            child: Text(strings.accept),
          ),
      ],
    );
  }
}

/// 保存一个传入申请及其审批回调。
class IncomingApprovalRequest {
  /// 创建带过期时间的传入审批请求。
  const IncomingApprovalRequest({
    required this.sessionId,
    required this.senderId,
    required this.fileName,
    required this.totalBytes,
    required this.expiresAt,
    required this.accept,
    required this.reject,
  });

  final String sessionId;
  final String senderId;
  final String fileName;
  final int totalBytes;
  final DateTime expiresAt;
  final Future<LanUiOutcome<void>> Function() accept;
  final Future<LanUiOutcome<void>> Function() reject;

  /// 此审批请求是否已过期。
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// 新的传入审批是否入队，以及对应的脱敏通知。
final class IncomingTransferNotificationDecision {
  const IncomingTransferNotificationDecision._({
    required this.queued,
    this.event,
  });

  final bool queued;
  final LanNotificationEvent? event;
}

/// 将 [request] 入队一次，并返回不含文件名的通知。
///
/// 已过期的申请和重复的 session id 不会入队。调用方仍需自行展示原有审批界面。
IncomingTransferNotificationDecision decideIncomingTransferNotification(
  List<IncomingApprovalRequest> pending,
  IncomingApprovalRequest request,
) {
  if (request.isExpired ||
      pending.any((item) => item.sessionId == request.sessionId)) {
    return const IncomingTransferNotificationDecision._(queued: false);
  }
  pending.add(request);
  return IncomingTransferNotificationDecision._(
    queued: true,
    event: transferRequestNotification(
      sessionId: request.sessionId,
      peerId: request.senderId,
      expired: request.isExpired,
    ),
  );
}

LanSystemNotificationPort? _readNotificationPort(BuildContext context) {
  try {
    return Provider.of<LanSystemNotificationPort>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

String _formatByteCount(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  double doubleBytes = bytes.toDouble();
  while (doubleBytes >= 1024 && i < suffixes.length - 1) {
    doubleBytes /= 1024;
    i++;
  }
  return '${doubleBytes.toStringAsFixed(1)} ${suffixes[i]}';
}
