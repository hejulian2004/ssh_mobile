part of '../lan_share_screen.dart';

extension _LanShareHistory on _LanShareScreenState {
  Widget _buildHistoryView(
    BuildContext context,
    LanShareStrings strings,
    LanShareViewModel vm,
  ) {
    if (vm.history.isEmpty) {
      return AppEmptyState(
        icon: Icons.history_rounded,
        title: strings.lanShareTransferHistory,
        message: strings.lanShareNoHistory,
      );
    }

    final Map<String, List<LanMessage>> grouped = {};

    for (final msg in vm.history) {
      final otherId = msg.isIncoming ? msg.senderId : msg.receiverId;
      if (otherId.isEmpty) continue;
      grouped.putIfAbsent(otherId, () => []).add(msg);
    }

    final sessions = grouped.entries.map((entry) {
      final otherId = entry.key;
      final msgs = entry.value;
      final lastMsg = msgs.first;

      final peerState = vm.peerStateFor(otherId);
      final onlineDev = peerState?.discovery;
      final isOnline = vm.isDeviceConnected(otherId);

      String alias = 'Unknown Device';
      String osName = 'Unknown OS';
      if (peerState != null) {
        alias = peerState.displayAlias;
        osName = onlineDev?.os ?? osName;
      } else {
        var foundIncoming = false;
        for (final m in msgs) {
          if (m.isIncoming) {
            alias = m.senderAlias;
            foundIncoming = true;
            break;
          }
        }
        if (!foundIncoming) {
          alias = lastMsg.senderAlias != vm.discoveryService.currentDeviceAlias
              ? lastMsg.senderAlias
              : 'Device';
        }
      }

      return _ChatSession(
        deviceId: otherId,
        alias: alias,
        osName: osName,
        lastMessage: lastMsg,
        isOnline: isOnline,
      );
    }).toList();

    sessions.sort(
      (a, b) => b.lastMessage.createdAt.compareTo(a.lastMessage.createdAt),
    );

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sessions.length,
      itemBuilder: (context, index) {
        final session = sessions[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: GestureDetector(
            onTap: () async {
              final paired = await vm.isDevicePaired(session.deviceId);
              if (!context.mounted) return;
              if (paired) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LanShareFeatureScope(
                      child: LanChatScreen(
                        targetDeviceId: session.deviceId,
                        initialAlias: session.alias,
                      ),
                    ),
                  ),
                );
              } else {
                final targetDevice = vm
                    .peerStateFor(session.deviceId)
                    ?.discovery;
                if (targetDevice == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(strings.lanShareOffline)),
                  );
                } else {
                  await _requestPairingWithFeedback(
                    context,
                    vm,
                    targetDevice,
                    strings,
                  );
                }
              }
            },
            child: AppSectionCard(
              title: session.alias,
              subtitle:
                  '${_formatDateTime(session.lastMessage.createdAt)}${_routeSuffix(strings, session.lastMessage.routeType)}',
              icon: session.isOnline
                  ? Icons.online_prediction_rounded
                  : Icons.devices_other_rounded,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: session.isOnline ? Colors.green : Colors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    session.isOnline ? '在线' : '离线',
                    style: TextStyle(
                      color: session.isOnline ? Colors.green : Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (_activeDeleteDeviceId == session.deviceId) ...[
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        _refreshView(() {
                          _activeDeleteDeviceId = null;
                        });
                      },
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_forever_rounded,
                        color: Colors.red,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(strings.lanShareClearChatHistory),
                            content: Text(strings.deleteConnectionConfirm),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: Text(strings.cancel),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: Text(strings.delete),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          await vm.clearChatHistory(session.deviceId);
                          if (!mounted) return;
                          _refreshView(() {
                            _activeDeleteDeviceId = null;
                          });
                        }
                      },
                    ),
                  ] else ...[
                    IconButton(
                      icon: const Icon(Icons.expand_more_rounded),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        _refreshView(() {
                          _activeDeleteDeviceId = session.deviceId;
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final year = dateTime.year;
    final month = dateTime.month.toString().padLeft(2, '0');
    final day = dateTime.day.toString().padLeft(2, '0');
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute';
  }

  String _routeSuffix(LanShareStrings strings, NetworkRouteType? routeType) {
    final label = switch (routeType) {
      NetworkRouteType.quicDirect => strings.lanRouteDirect,
      NetworkRouteType.relay => strings.lanRouteRelay,
      _ => null,
    };
    return label == null ? '' : ' · $label';
  }
}
