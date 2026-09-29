import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../domain/lan_share_ports.dart';
import '../../../services/lan_share/lan_share_models.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:app_ui/app_ui.dart';
import '../viewmodels/lan_share_viewmodel.dart';
import 'lan_preview_viewer_screen.dart';
import 'lan_text_selection_screen.dart';

class LanChatScreen extends StatefulWidget {
  final String targetDeviceId;
  final String initialAlias;
  final LanShareScreenSharePort? screenSharePort;

  const LanChatScreen({
    super.key,
    required this.targetDeviceId,
    required this.initialAlias,
    this.screenSharePort,
  });

  @override
  State<LanChatScreen> createState() => _LanChatScreenState();
}

class _LanChatScreenState extends State<LanChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _isPaired = false;
  bool _isCheckingPairing = true;
  LanShareScreenSharePort? _screenSharePort;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshPairing(context.read<LanShareViewModel>());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _screenSharePort ??= widget.screenSharePort ?? _tryReadScreenSharePort();
  }

  LanShareScreenSharePort? _tryReadScreenSharePort() {
    try {
      return context.read<LanShareScreenSharePort>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _refreshPairing(LanShareViewModel vm) async {
    final paired = await vm.isDevicePaired(widget.targetDeviceId);
    if (!mounted) return;
    setState(() {
      _isPaired = paired;
      _isCheckingPairing = false;
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _formatBytes(int bytes) {
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

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  void _showAttachmentOptions(
    BuildContext context,
    LanShareStrings strings,
    LanShareViewModel vm,
    String peerId,
    LanDiscoveredPeer? device,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: Text(strings.lanShareSelectImage),
              onTap: () async {
                Navigator.pop(ctx);
                final file = await FilePicker.pickFile(type: FileType.image);
                if (file != null && file.path != null) {
                  final result = await vm.sendFile(
                    peerId: peerId,
                    filePath: file.path!,
                    discovery: device,
                  );
                  if (result is NetworkFailure<TransferSession> &&
                      context.mounted) {
                    if (result.error.code ==
                        NetworkErrorCode.authenticationFailed) {
                      _showE2ENotSupportedError(context, strings);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            strings.isEnglish
                                ? 'Failed to send image: ${result.error.message}'
                                : '发送图片失败：${result.error.message}',
                          ),
                        ),
                      );
                    }
                  }
                }
              },
            ),

            ListTile(
              leading: const Icon(Icons.video_library_rounded),
              title: Text(strings.lanShareSelectVideo),
              onTap: () async {
                Navigator.pop(ctx);
                final file = await FilePicker.pickFile(type: FileType.video);
                if (file != null && file.path != null) {
                  final result = await vm.sendFile(
                    peerId: peerId,
                    filePath: file.path!,
                    discovery: device,
                  );
                  if (result is NetworkFailure<TransferSession> &&
                      context.mounted) {
                    if (result.error.code ==
                        NetworkErrorCode.authenticationFailed) {
                      _showE2ENotSupportedError(context, strings);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            strings.isEnglish
                                ? 'Failed to send video: ${result.error.message}'
                                : '发送视频失败：${result.error.message}',
                          ),
                        ),
                      );
                    }
                  }
                }
              },
            ),

            ListTile(
              leading: const Icon(Icons.insert_drive_file_rounded),
              title: Text(strings.lanShareSelectFile),
              onTap: () async {
                Navigator.pop(ctx);
                final file = await FilePicker.pickFile();
                if (file != null && file.path != null) {
                  final result = await vm.sendFile(
                    peerId: peerId,
                    filePath: file.path!,
                    discovery: device,
                  );
                  if (result is NetworkFailure<TransferSession> &&
                      context.mounted) {
                    if (result.error.code ==
                        NetworkErrorCode.authenticationFailed) {
                      _showE2ENotSupportedError(context, strings);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            strings.isEnglish
                                ? 'Failed to send file: ${result.error.message}'
                                : '发送文件失败：${result.error.message}',
                          ),
                        ),
                      );
                    }
                  }
                }
              },
            ),

            ListTile(
              leading: const Icon(Icons.content_paste_rounded),
              title: Text(strings.lanShareClipboard),
              onTap: () async {
                Navigator.pop(ctx);
                if (device == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        strings.isEnglish
                            ? 'Clipboard sync requires direct local network.'
                            : '剪贴板同步暂不支持中继传输，需处于同一局域网。',
                      ),
                    ),
                  );
                  return;
                }
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data != null &&
                    data.text != null &&
                    data.text!.isNotEmpty) {
                  final result = await vm.sendClipboard(device, data.text!);
                  if (result is NetworkFailure<void> &&
                      result.error.code ==
                          NetworkErrorCode.authenticationFailed &&
                      context.mounted) {
                    _showE2ENotSupportedError(context, strings);
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget? _screenShareAction(BuildContext context, LanShareStrings strings) {
    final port = _screenSharePort;
    if (port == null || !port.canShareWith(widget.targetDeviceId)) {
      return null;
    }
    return IconButton(
      tooltip: strings.isEnglish ? 'Share screen' : '共享屏幕',
      icon: const Icon(Icons.screen_share_outlined),
      onPressed: () => _startScreenShare(context, port),
    );
  }

  Future<void> _startScreenShare(
    BuildContext context,
    LanShareScreenSharePort port,
  ) async {
    try {
      await port.startScreenShare(widget.targetDeviceId);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  void _showE2ENotSupportedError(
    BuildContext context,
    LanShareStrings strings,
  ) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.lock_open_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            const Expanded(child: Text('对方不支持端对端加密，已拒绝发送')),
          ],
        ),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<LanShareSettingsPort>();
    final strings = settings.strings;
    final vm = context.watch<LanShareViewModel>();

    final currentDeviceId = vm.discoveryService.currentDeviceId;
    final chatMessages = vm.history
        .where(
          (msg) =>
              (msg.senderId == widget.targetDeviceId &&
                  msg.receiverId == currentDeviceId) ||
              (msg.senderId == currentDeviceId &&
                  msg.receiverId == widget.targetDeviceId),
        )
        .toList(); // sorted DESC from vm.history, perfect for ListView reverse: true

    final peerState = vm.peerStateFor(widget.targetDeviceId);
    final onlineDevice = peerState?.discovery;
    final isOnline = peerState?.isOnline == true;
    final isConnected = vm.isDeviceConnected(widget.targetDeviceId);
    final deviceAlias = peerState?.displayAlias ?? widget.initialAlias;
    final deviceSub = onlineDevice != null
        ? (isConnected
              ? '${strings.lanShareOnline} · ${onlineDevice.os}'
              : (strings.isEnglish ? 'Connecting…' : '连接中…'))
        : strings.lanShareOffline;

    return Scaffold(
      body: AppPageSurface(
        child: SafeArea(
          child: _isCheckingPairing
              ? _LanChatConversationSkeleton(
                  strings: strings,
                  deviceAlias: deviceAlias,
                )
              : Column(
                  children: [
                    // Custom Top Header
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                        vertical: 4.0,
                      ),
                      child: Row(
                        children: [
                          const BackButton(),
                          const SizedBox(width: 4),
                          AppIconBadge(
                            icon:
                                onlineDevice?.deviceType == LanDeviceType.mobile
                                ? Icons.smartphone_rounded
                                : Icons.desktop_windows_rounded,
                            size: 40,
                            iconSize: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  deviceAlias,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.shield_rounded,
                                      size: 12,
                                      color: Color(0xFF29B6F6),
                                    ),
                                    const SizedBox(width: 3),
                                    Flexible(
                                      child: Text(
                                        deviceSub,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: isConnected
                                                  ? Theme.of(
                                                      context,
                                                    ).colorScheme.primary
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                            ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (_screenShareAction(context, strings)
                              case final action?)
                            action,
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert_rounded),
                            onSelected: (action) async {
                              final messenger = ScaffoldMessenger.of(context);
                              if (action == 'toggle_relay') {
                                final peerState = vm.peerStateFor(
                                  widget.targetDeviceId,
                                );
                                final isRelayAllowed =
                                    peerState?.trust?.authorization.relay ??
                                    false;
                                final result = await vm.setRelayAuthorization(
                                  widget.targetDeviceId,
                                  !isRelayAllowed,
                                );
                                if (context.mounted &&
                                    result is NetworkFailure<void>) {
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        strings.isEnglish
                                            ? 'Failed to update Relay authorization: ${result.error.message}'
                                            : '更新中继授权失败：${result.error.message}',
                                      ),
                                    ),
                                  );
                                }
                              } else if (action == 'forget') {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(strings.lanShareForgetConfirm),
                                    content: Text(
                                      strings.lanShareForgetConfirmMessage,
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: Text(strings.cancel),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: Text(
                                          strings.lanShareForgetConfirm,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  final result = await vm.forgetDevice(
                                    widget.targetDeviceId,
                                  );
                                  if (context.mounted) {
                                    if (result is NetworkFailure<void>) {
                                      messenger.showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            strings.isEnglish
                                                ? 'Failed to forget device: ${result.error.message}'
                                                : '解除设备配对失败：${result.error.message}',
                                          ),
                                        ),
                                      );
                                    } else {
                                      _refreshPairing(vm);
                                    }
                                  }
                                }
                              } else if (action == 'clear') {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(
                                      strings.lanShareClearChatHistory,
                                    ),
                                    content: Text(
                                      strings.deleteConnectionConfirm,
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: Text(strings.cancel),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: Text(strings.delete),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  await vm.clearChatHistory(
                                    widget.targetDeviceId,
                                  );
                                }
                              }
                            },
                            itemBuilder: (context) {
                              final peerState = vm.peerStateFor(
                                widget.targetDeviceId,
                              );
                              final isRelayAllowed =
                                  peerState?.trust?.authorization.relay ??
                                  false;
                              return [
                                if (peerState?.isTrusted == true)
                                  CheckedPopupMenuItem<String>(
                                    value: 'toggle_relay',
                                    checked: isRelayAllowed,
                                    child: Text(
                                      strings.isEnglish
                                          ? 'Allow Relay for this device'
                                          : '允许中继传输',
                                    ),
                                  ),
                                PopupMenuItem(
                                  value: 'forget',
                                  child: Text(strings.lanShareForgetDevice),
                                ),
                                PopupMenuItem(
                                  value: 'clear',
                                  child: Text(strings.lanShareClearChatHistory),
                                ),
                              ];
                            },
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),

                    // Chat Messages List
                    Expanded(
                      child: chatMessages.isEmpty
                          ? Center(
                              child: Text(
                                strings.lanShareNoDevices,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: _scrollController,
                              reverse: true,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                                vertical: 12.0,
                              ),
                              itemCount: chatMessages.length,
                              itemBuilder: (context, index) {
                                final msg = chatMessages[index];
                                final isMe = !msg.isIncoming;
                                return _buildMessageBubble(
                                  context,
                                  strings,
                                  vm,
                                  msg,
                                  isMe,
                                  onlineDevice,
                                );
                              },
                            ),
                    ),

                    // Offline Warn Banner
                    if (!isOnline)
                      () {
                        final relayAuthorized =
                            peerState?.trust?.authorization.relay == true;
                        final relayAvailable =
                            peerState?.route.relayAvailable == true;
                        final String offlineMessage;
                        final IconData offlineIcon;
                        if (relayAvailable) {
                          offlineIcon = Icons.cloud_done_rounded;
                          offlineMessage = strings.isEnglish
                              ? 'Device is offline on LAN. Relay is currently available.'
                              : '设备当前不在局域网，Relay 当前可用。';
                        } else if (relayAuthorized) {
                          offlineIcon = Icons.cloud_queue_rounded;
                          offlineMessage = strings.isEnglish
                              ? 'Device is offline on LAN. Relay authorized, will attempt on send.'
                              : '设备当前不在局域网，已授权中继，发送时将尝试 Relay。';
                        } else {
                          offlineIcon = Icons.info_outline_rounded;
                          offlineMessage = strings.lanShareDeviceOfflineHint;
                        }

                        return Container(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16.0,
                            vertical: 8.0,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                offlineIcon,
                                size: 18,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  offlineMessage,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }(),

                    // Bottom Input Bar
                    if (!_isPaired)
                      Container(
                        padding: const EdgeInsets.all(16.0),
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 4,
                              offset: const Offset(0, -2),
                            ),
                          ],
                        ),
                        child: SafeArea(
                          top: false,
                          child: SizedBox(
                            width: double.infinity,
                            child: isOnline
                                ? ElevatedButton.icon(
                                    onPressed: () async {
                                      if (onlineDevice != null) {
                                        await vm.requestPairing(onlineDevice);
                                        if (mounted) {
                                          _refreshPairing(vm);
                                        }
                                      }
                                    },
                                    icon: const Icon(Icons.lock_open_rounded),
                                    label: Text(strings.lanShareReauthenticate),
                                  )
                                : ElevatedButton.icon(
                                    onPressed: null, // Disabled when offline
                                    icon: const Icon(Icons.cloud_off_rounded),
                                    label: Text(
                                      strings.lanShareOfflineReauthHint,
                                    ),
                                  ),
                          ),
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8.0,
                          vertical: 8.0,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 4,
                              offset: const Offset(0, -2),
                            ),
                          ],
                        ),
                        child: SafeArea(
                          top: false,
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.add_circle_outline_rounded,
                                ),
                                color: Theme.of(context).colorScheme.primary,
                                onPressed:
                                    (isOnline ||
                                        (peerState
                                                ?.trust
                                                ?.authorization
                                                .relay ==
                                            true))
                                    ? () => _showAttachmentOptions(
                                        context,
                                        strings,
                                        vm,
                                        widget.targetDeviceId,
                                        onlineDevice,
                                      )
                                    : null,
                              ),
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest
                                        .withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(24.0),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16.0,
                                  ),
                                  child: TextField(
                                    controller: _textController,
                                    enabled: isOnline,
                                    minLines: 1,
                                    maxLines: 4,
                                    keyboardType: TextInputType.multiline,
                                    textInputAction: TextInputAction.newline,
                                    decoration: InputDecoration(
                                      hintText: isOnline
                                          ? strings.lanShareChatInputHint
                                          : (strings.isEnglish
                                                ? 'Text unavailable offline'
                                                : '文本消息仅局域网内可用'),
                                      filled: false,
                                      fillColor: Colors.transparent,
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      isDense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            vertical: 8.0,
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.send_rounded),
                                color: isOnline
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).disabledColor,
                                onPressed: isOnline && onlineDevice != null
                                    ? () async {
                                        final val = _textController.text.trim();
                                        if (val.isNotEmpty) {
                                          _textController.clear();
                                          final result = await vm.sendText(
                                            onlineDevice,
                                            val,
                                          );
                                          if (result is NetworkFailure<void> &&
                                              result.error.code ==
                                                  NetworkErrorCode
                                                      .authenticationFailed &&
                                              context.mounted) {
                                            _showE2ENotSupportedError(
                                              context,
                                              strings,
                                            );
                                          }
                                        }
                                      }
                                    : null,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(
    BuildContext context,
    LanShareStrings strings,
    LanShareViewModel vm,
    LanMessage msg,
    bool isMe,
    LanDiscoveredPeer? device,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    Widget bubbleContent;
    if (msg.isRecalled) {
      bubbleContent = Text(
        strings.lanShareRecalled,
        style: TextStyle(
          fontStyle: FontStyle.italic,
          color: colors.onSurfaceVariant,
        ),
      );
    } else {
      switch (msg.payloadType) {
        case LanPayloadType.text:
        case LanPayloadType.clipboard:
          bubbleContent = Text(
            msg.textContent ?? '',
            style: TextStyle(color: isMe ? colors.onPrimary : colors.onSurface),
          );
          break;
        case LanPayloadType.image:
        case LanPayloadType.video:
        case LanPayloadType.audio:
        case LanPayloadType.file:
        case LanPayloadType.directory:
        case LanPayloadType.sftpRelay:
          bubbleContent = _buildFileBubbleContent(
            context,
            strings,
            vm,
            msg,
            isMe,
            device,
          );
          break;
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Column(
        crossAxisAlignment: isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: isMe
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isMe) ...[const SizedBox(width: 4)],
              Flexible(
                child: GestureDetector(
                  onLongPress: () => _showMessageContextMenu(
                    context,
                    strings,
                    vm,
                    msg,
                    isMe,
                    device,
                  ),
                  child: Container(
                    padding: msg.isRecalled
                        ? const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          )
                        : (msg.payloadType == LanPayloadType.text ||
                                  msg.payloadType == LanPayloadType.clipboard
                              ? const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                )
                              : const EdgeInsets.all(12)),
                    decoration: BoxDecoration(
                      color: msg.isRecalled
                          ? Colors.transparent
                          : (isMe
                                ? colors.primary
                                : colors.surfaceContainerHighest),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.circular(isMe ? 16 : 4),
                        bottomRight: Radius.circular(isMe ? 4 : 16),
                      ),
                      border: msg.isRecalled
                          ? Border.all(color: colors.outlineVariant)
                          : null,
                    ),
                    child: bubbleContent,
                  ),
                ),
              ),
              if (isMe) ...[const SizedBox(width: 4)],
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: EdgeInsets.only(left: isMe ? 0 : 8, right: isMe ? 8 : 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(msg.createdAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 10,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (msg.routeType == NetworkRouteType.quicDirect ||
                    msg.routeType == NetworkRouteType.relay) ...[
                  const SizedBox(width: 6),
                  Icon(
                    msg.routeType == NetworkRouteType.relay
                        ? Icons.hub_outlined
                        : Icons.swap_calls_rounded,
                    size: 12,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    msg.routeType == NetworkRouteType.relay
                        ? strings.lanRouteRelay
                        : strings.lanRouteDirect,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 10,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
                if (isMe && !msg.isRecalled) ...[
                  const SizedBox(width: 4),
                  _buildStatusIndicator(context, msg),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileBubbleContent(
    BuildContext context,
    LanShareStrings strings,
    LanShareViewModel vm,
    LanMessage msg,
    bool isMe,
    LanDiscoveredPeer? device,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final titleColor = isMe ? colors.onPrimary : colors.onSurface;
    final subColor = isMe
        ? colors.onPrimary.withValues(alpha: 0.7)
        : colors.onSurfaceVariant;

    final isTransferring =
        msg.status == LanTransferStatus.transferring ||
        msg.status == LanTransferStatus.connecting ||
        msg.status == LanTransferStatus.pending;

    return InkWell(
      onTap: () {
        if (msg.status == LanTransferStatus.completed) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => LanPreviewViewerScreen(message: msg),
            ),
          );
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                msg.payloadType == LanPayloadType.image
                    ? Icons.image_rounded
                    : Icons.insert_drive_file_rounded,
                color: titleColor,
                size: 32,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      msg.fileName ?? strings.unknown,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: titleColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatBytes(msg.fileSize),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: subColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (isTransferring) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: msg.progress,
              color: isMe ? colors.onPrimary : colors.primary,
              backgroundColor: isMe
                  ? colors.onPrimary.withValues(alpha: 0.2)
                  : colors.primary.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 4),
            Text(
              '${(msg.progress * 100).toStringAsFixed(0)}% · ${msg.status.name}',
              style: TextStyle(fontSize: 10, color: subColor),
            ),
          ] else if (msg.status == LanTransferStatus.completed) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Icon(Icons.visibility_rounded, size: 14, color: subColor),
                const SizedBox(width: 4),
                Text(
                  strings.lanShareOpenBrowser, // Open Link -> View File
                  style: TextStyle(fontSize: 11, color: subColor),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusIndicator(BuildContext context, LanMessage msg) {
    switch (msg.status) {
      case LanTransferStatus.pending:
      case LanTransferStatus.connecting:
      case LanTransferStatus.transferring:
        return AppLoadingIndicator(
          size: 8,
          strokeWidth: 1.2,
          color: Theme.of(context).colorScheme.primary,
        );
      case LanTransferStatus.completed:
        return Icon(
          Icons.check_circle_rounded,
          size: 10,
          color: Theme.of(context).colorScheme.primary,
        );
      case LanTransferStatus.failed:
      case LanTransferStatus.cancelled:
        return const Icon(Icons.error_rounded, size: 10, color: Colors.red);
      default:
        return const SizedBox.shrink();
    }
  }

  void _showMessageContextMenu(
    BuildContext context,
    LanShareStrings strings,
    LanShareViewModel vm,
    LanMessage msg,
    bool isMe,
    LanDiscoveredPeer? device,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!msg.isRecalled &&
                (msg.payloadType == LanPayloadType.text ||
                    msg.payloadType == LanPayloadType.clipboard)) ...[
              ListTile(
                leading: const Icon(Icons.copy_all_rounded),
                title: Text(strings.lanShareCopyAll),
                onTap: () {
                  Navigator.pop(ctx);
                  if (msg.textContent != null) {
                    Clipboard.setData(ClipboardData(text: msg.textContent!));
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.text_fields_rounded),
                title: Text(strings.lanShareSelectToCopy),
                onTap: () {
                  Navigator.pop(ctx);
                  if (msg.textContent != null) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            LanTextSelectionScreen(text: msg.textContent!),
                      ),
                    );
                  }
                },
              ),
            ],
            if (!msg.isRecalled && isMe && device != null)
              ListTile(
                leading: const Icon(Icons.undo_rounded),
                title: Text(strings.lanShareRecall),
                onTap: () async {
                  Navigator.pop(ctx);
                  await vm.recallMessage(msg, device);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: Text(strings.lanShareDeleteMessage),
              onTap: () async {
                Navigator.pop(ctx);
                await vm.deleteMessage(msg.id);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _LanChatConversationSkeleton extends StatelessWidget {
  const _LanChatConversationSkeleton({
    required this.strings,
    required this.deviceAlias,
  });

  final LanShareStrings strings;
  final String deviceAlias;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AppSkeletonizer.zone(
      enabled: true,
      semanticsLabel: strings.lanRelayConnecting,
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Row(
              children: [
                const BackButton(),
                const SizedBox(width: 4),
                const AppIconBadge(
                  icon: Icons.smartphone_rounded,
                  size: 40,
                  iconSize: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        deviceAlias,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(
                            Icons.shield_rounded,
                            size: 12,
                            color: Color(0xFF29B6F6),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            strings.lanShareOnline,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const IconButton(
                  icon: Icon(Icons.more_vert_rounded),
                  onPressed: null,
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Messages
          Expanded(
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 12.0,
              ),
              children: [
                // Incoming message with file attachment card
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        constraints: const BoxConstraints(maxWidth: 280),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(16),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.insert_drive_file_rounded,
                              color: colorScheme.primary,
                              size: 28,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'document_archive.tar.gz',
                                    maxLines: 1,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    '14.8 MB',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          '10:42',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 10,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),

                // Outgoing text message
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        constraints: const BoxConstraints(maxWidth: 260),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(4),
                          ),
                        ),
                        child: const Text(
                          'Received, thank you! Sending you the updated configuration file.',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          '10:43',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 10,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),

                // Incoming short text message
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        constraints: const BoxConstraints(maxWidth: 240),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(16),
                          ),
                        ),
                        child: const Text(
                          'Sounds good, let me know when it arrives.',
                        ),
                      ),
                      const SizedBox(height: 2),
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          '10:44',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 10,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Bottom Input Composer
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    color: colorScheme.primary,
                    onPressed: null,
                  ),
                  Expanded(
                    child: TextField(
                      enabled: false,
                      decoration: InputDecoration(
                        hintText: strings.lanShareChatInputHint,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24.0),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16.0,
                          vertical: 10.0,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const IconButton(
                    icon: Icon(Icons.send_rounded),
                    onPressed: null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
