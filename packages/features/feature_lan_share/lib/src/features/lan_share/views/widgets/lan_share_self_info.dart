import 'package:app_ui/app_ui.dart';
import 'package:flutter/material.dart';

import '../../../../domain/lan_share_ports.dart';

class LanSelfDeviceInfoBar extends StatelessWidget {
  const LanSelfDeviceInfoBar({
    super.key,
    required this.alias,
    required this.strings,
    required this.interfaces,
    required this.onSelect,
    required this.onRefresh,
    this.customIp,
    this.selection,
    this.refreshing = false,
  });
  final String alias;
  final LanShareStrings strings;
  final Future<Map<String, String>> interfaces;
  final String? customIp;
  final LanShareLocalAddressSelectionResult? selection;
  final bool refreshing;
  final VoidCallback onSelect;
  final VoidCallback onRefresh;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = strings.isEnglish ? 'This Device: ' : '本机设备：';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: colors.primaryContainer.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.primary.withValues(alpha: 0.18)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.perm_device_info_rounded,
              size: 16,
              color: colors.primary.withValues(alpha: 0.75),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: onSelect,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 4,
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: FutureBuilder<Map<String, String>>(
                      future: interfaces,
                      builder: (context, snapshot) {
                        final ipMap = snapshot.data ?? {};
                        final ips = ipMap.keys.toList();
                        final addressSelection = selection;
                        final automaticIp =
                            addressSelection is LanShareLocalAddressSelected
                            ? addressSelection.candidate.address
                            : null;
                        final List<InlineSpan> spans = [
                          TextSpan(
                            text: label,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.primary.withValues(alpha: 0.7),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          TextSpan(
                            text: alias,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colors.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ];

                        if (ips.isEmpty) {
                          spans.add(
                            TextSpan(
                              text:
                                  '  ${strings.isEnglish ? "Loading…" : "获取中…"}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          );
                        } else {
                          spans.add(const TextSpan(text: '  '));
                          for (int i = 0; i < ips.length; i++) {
                            final ip = ips[i];
                            final isSelected =
                                customIp == ip ||
                                (customIp == null && automaticIp == ip);
                            spans.add(
                              TextSpan(
                                text: ip,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: isSelected
                                      ? colors.primary
                                      : colors.onSurfaceVariant,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            );
                            if (isSelected) {
                              spans.add(
                                TextSpan(
                                  text:
                                      '(${strings.isEnglish ? "active" : "使用中"})',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: colors.primary,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              );
                            }
                            if (i < ips.length - 1) {
                              spans.add(
                                TextSpan(
                                  text: ' · ',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: colors.onSurfaceVariant.withValues(
                                      alpha: 0.5,
                                    ),
                                  ),
                                ),
                              );
                            }
                          }
                        }
                        return RichText(
                          maxLines: 1,
                          text: TextSpan(children: spans),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: refreshing ? null : onRefresh,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: refreshing
                    ? AppLoadingIndicator(
                        size: 14,
                        strokeWidth: 1.5,
                        color: colors.primary.withValues(alpha: 0.7),
                      )
                    : Icon(
                        Icons.refresh_rounded,
                        size: 16,
                        color: colors.primary.withValues(alpha: 0.6),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
