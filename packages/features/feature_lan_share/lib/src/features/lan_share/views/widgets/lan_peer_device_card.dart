import 'package:app_ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../domain/lan_device_strings.dart';
import '../../../../domain/lan_share_ports.dart';
import '../../../../services/lan_share/lan_share_models.dart';

/// A shared phone/desktop card with independent presence and pairing labels.
class LanPeerDeviceCard extends StatefulWidget {
  const LanPeerDeviceCard({
    super.key,
    required this.peer,
    required this.strings,
    required this.onTap,
    this.onUnpair,
    this.isConnecting = false,
    this.onCancel,
  });
  final LanPeerViewState peer;
  final LanShareStrings strings;
  final VoidCallback? onTap;
  final VoidCallback? onUnpair;
  final bool isConnecting;
  final VoidCallback? onCancel;

  @override
  State<LanPeerDeviceCard> createState() => _LanPeerDeviceCardState();
}

class _LanPeerDeviceCardState extends State<LanPeerDeviceCard> {
  bool _focusVisible = false;

  @override
  Widget build(BuildContext context) {
    final peer = widget.peer;
    final strings = widget.strings;
    final onTap = widget.isConnecting ? null : widget.onTap;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final status = switch (peer.reachability) {
      LanPeerReachability.online => strings.lanShareOnline,
      LanPeerReachability.offline => strings.lanShareOffline,
      LanPeerReachability.unknown => strings.lanDeviceUnknown,
    };
    final color = peer.isOnline ? colors.primary : colors.onSurfaceVariant;
    final seen = peer.lastOnlineAt?.toLocal();
    final time = seen == null ? strings.lanDeviceUnknown : _formatTime(seen);
    final unpair = peer.isTrusted ? widget.onUnpair : null;
    return FocusableActionDetector(
      enabled: onTap != null,
      mouseCursor: SystemMouseCursors.click,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap?.call();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (value) => setState(() => _focusVisible = value),
      child: Container(
        foregroundDecoration: _focusVisible
            ? BoxDecoration(
                border: Border.all(color: colors.primary, width: 2),
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              )
            : null,
        child: Semantics(
          button: true,
          enabled: onTap != null,
          onLongPress: unpair,
          child: GestureDetector(
            onTap: onTap,
            onLongPress: unpair,
            onSecondaryTap: unpair,
            child: AppSectionCard(
              title: peer.displayAlias,
              subtitle: peer.discovery == null
                  ? null
                  : '${peer.discovery!.ip} · ${peer.discovery!.os}',
              icon: switch (peer.deviceType) {
                LanDeviceType.mobile => Icons.smartphone_rounded,
                LanDeviceType.webBrowser => Icons.language_rounded,
                LanDeviceType.desktop => Icons.desktop_windows_rounded,
              },
              trailing: unpair == null
                  ? null
                  : IconButton(
                      tooltip: strings.lanDeviceUnpair,
                      onPressed: unpair,
                      icon: const Icon(Icons.more_horiz_rounded),
                    ),
              contentGap: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.isConnecting)
                    Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(strings.lanDeviceConnecting)),
                        TextButton(
                          onPressed: widget.onCancel,
                          child: Text(strings.lanDeviceTerminate),
                        ),
                      ],
                    ),
                  Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            status,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            peer.isTrusted
                                ? Icons.verified_user_outlined
                                : Icons.lock_outline_rounded,
                            size: 14,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            peer.isTrusted
                                ? strings.lanDevicePaired
                                : strings.lanDeviceUnpaired,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${strings.lanDeviceLastOnline}: $time',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _formatTime(DateTime value) {
  String padded(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${padded(value.month)}-${padded(value.day)} ${padded(value.hour)}:${padded(value.minute)}';
}

Future<bool> confirmLanPeerUnpair(
  BuildContext context,
  LanPeerViewState peer,
  LanShareStrings strings,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.lanDeviceUnpairTitle),
        content: Text('${peer.displayAlias}\n\n${strings.lanDeviceUnpairHint}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.lanDeviceUnpair),
          ),
        ],
      ),
    ) ??
    false;
