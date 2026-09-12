import 'dart:async';
import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_handler/share_handler.dart';

import '../../../domain/lan_share_ports.dart';
import 'package:app_ui/app_ui.dart';
import 'package:feature_lan_share/src/features/lan_share/viewmodels/lan_share_viewmodel.dart';
import 'package:feature_lan_share/src/services/lan_share/lan_share_models.dart';
import 'package:feature_lan_share/src/services/lan_share/lan_discovery_service.dart';
import 'package:network_sdk/network_sdk.dart';
import '../lan_share_feature_scope.dart';
import 'lan_chat_screen.dart';
import 'lan_qr_scanner_screen.dart';
import 'lan_share_settings_screen.dart';

part 'widgets/lan_share_dialogs.dart';

class LanShareScreen extends StatefulWidget {
  const LanShareScreen({this.screenSharePort, super.key});

  final LanShareScreenSharePort? screenSharePort;

  @override
  State<LanShareScreen> createState() => _LanShareScreenState();
}

class _LanShareScreenState extends State<LanShareScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _isDragging = false;
  StreamSubscription? _intentSubscription;
  String? _activeDeleteDeviceId;
  late Future<Map<String, String>> _localIpsFuture;
  bool _isRefreshingIps = false;
  bool _scanningInitialized = false;
  LanShareScreenSharePort? _screenSharePort;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _localIpsFuture = LanDiscoveryService.getLocalIpInterfaces();
    unawaited(_initShareHandler());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _screenSharePort ??= widget.screenSharePort ?? _tryReadScreenSharePort();
    if (!_scanningInitialized) {
      _scanningInitialized = true;
      final vm = context.read<LanShareViewModel>();
      if (!vm.isScanning) {
        unawaited(vm.startScanning());
      }
    }
  }

  LanShareScreenSharePort? _tryReadScreenSharePort() {
    try {
      return context.read<LanShareScreenSharePort>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _initShareHandler() async {
    if (kIsWeb || Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return;
    }
    try {
      final handler = ShareHandlerPlatform.instance;
      final media = await handler.getInitialSharedMedia();
      if (!mounted) return;
      if (media != null && media.attachments != null) {
        _handleSharedMedia(media.attachments!);
      }

      _intentSubscription = handler.sharedMediaStream.listen((
        SharedMedia media,
      ) {
        if (media.attachments != null) {
          _handleSharedMedia(media.attachments!);
        }
      });
    } catch (e) {
      debugPrint('[LanShareScreen] Share handler init error: $e');
    }
  }

  void _handleSharedMedia(List<SharedAttachment?> attachments) {
    final paths = attachments
        .where((a) => a != null && a.path.isNotEmpty)
        .map((a) => a!.path)
        .toList();
    if (paths.isNotEmpty) {
      _showTargetDevicePickerAndSend(paths);
    }
  }

  @override
  void dispose() {
    _intentSubscription?.cancel();
    _tabController.dispose();
    try {
      unawaited(context.read<LanShareViewModel>().stopScanning());
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<LanShareSettingsPort>();
    final strings = settings.strings;
    final vm = context.watch<LanShareViewModel>();

    return Scaffold(
      body: DropTarget(
        onDragEntered: (details) => setState(() => _isDragging = true),
        onDragExited: (details) => setState(() => _isDragging = false),
        onDragDone: (details) async {
          setState(() => _isDragging = false);
          final paths = details.files.map((f) => f.path).toList();
          if (paths.isNotEmpty) {
            _showTargetDevicePickerAndSend(paths);
          }
        },
        child: AppPageSurface(
          child: Stack(
            children: [
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: AppPageHeader(
                        title: strings.lanShare,
                        subtitleWidget: OverflowScrollText(
                          vm.isScanning
                              ? strings.lanShareRadarHint
                              : (vm.peerStates.isEmpty
                                    ? strings.lanShareNoDevicesRefreshHint
                                    : strings.lanShareRadarStoppedHint),
                          selectable: false,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        icon: Icons.radar_rounded,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.qr_code_scanner_rounded),
                              tooltip: strings.lanShareScanOrAdd,
                              onPressed: () async {
                                String? scanned;
                                if (Platform.isAndroid || Platform.isIOS) {
                                  final isEn = vm.appSettings.isEnglish;
                                  final option =
                                      await showModalBottomSheet<String>(
                                        context: context,
                                        builder: (ctx) => SafeArea(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              ListTile(
                                                leading: const Icon(
                                                  Icons.qr_code_scanner_rounded,
                                                ),
                                                title: Text(
                                                  isEn
                                                      ? 'Scan QR Code'
                                                      : '扫码连接',
                                                ),
                                                onTap: () =>
                                                    Navigator.pop(ctx, 'scan'),
                                              ),
                                              ListTile(
                                                leading: const Icon(
                                                  Icons.keyboard_rounded,
                                                ),
                                                title: Text(
                                                  isEn
                                                      ? 'Manually Enter Address'
                                                      : '手动输入地址',
                                                ),
                                                onTap: () => Navigator.pop(
                                                  ctx,
                                                  'manual',
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                  if (option == 'scan' && context.mounted) {
                                    scanned = await Navigator.push<String>(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const LanQrScannerScreen(),
                                      ),
                                    );
                                  } else if (option == 'manual' &&
                                      context.mounted) {
                                    scanned = await _showManualAddDialog(
                                      context,
                                      strings,
                                    );
                                  }
                                } else {
                                  if (context.mounted) {
                                    scanned = await _showManualAddDialog(
                                      context,
                                      strings,
                                    );
                                  }
                                }

                                if (scanned != null &&
                                    scanned.isNotEmpty &&
                                    context.mounted) {
                                  _connectToScannedOrInput(
                                    context,
                                    scanned,
                                    vm,
                                    strings,
                                  );
                                }
                              },
                            ),
                            IconButton(
                              icon: Icon(
                                vm.isWebShareActive
                                    ? Icons.qr_code_2_rounded
                                    : Icons.qr_code_outlined,
                                color: vm.isWebShareActive
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              tooltip: strings.lanShareWebShare,
                              onPressed: () =>
                                  _toggleWebShareDialog(context, strings, vm),
                            ),
                            IconButton(
                              icon: Icon(
                                vm.isScanning
                                    ? Icons.sync_rounded
                                    : Icons.sync_disabled_rounded,
                                color: vm.isScanning
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              tooltip: vm.isScanning
                                  ? strings.lanShareScanning
                                  : strings.lanShareScan,
                              onPressed: () {
                                if (vm.isScanning) {
                                  vm.stopScanning();
                                } else {
                                  vm.startScanning();
                                }
                              },
                            ),
                            PopupMenuButton<String>(
                              tooltip: strings.moreActions,
                              icon: const Icon(Icons.more_vert_rounded),
                              onSelected: (value) {
                                if (value == 'settings') {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          const LanShareFeatureScope(
                                            child: LanShareSettingsScreen(),
                                          ),
                                    ),
                                  );
                                }
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'settings',
                                  child: Text(strings.lanShareSettings),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Self device info bar
                    _buildSelfInfoBar(context, vm, strings),
                    TabBar(
                      controller: _tabController,
                      tabs: [
                        Tab(text: strings.lanShareDeviceList),
                        Tab(text: strings.lanShareTransferHistory),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildRadarView(context, strings, vm),
                          _buildHistoryView(context, strings, vm),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (_isDragging)
                Container(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.15),
                  alignment: Alignment.center,
                  child: AppSectionCard(
                    title: strings.lanShareDragDropHint,
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.cloud_upload_rounded,
                          size: 64,
                          color: Colors.blue,
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

  Widget _buildSelfInfoBar(
    BuildContext context,
    LanShareViewModel vm,
    LanShareStrings strings,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final alias = vm.discoveryService.currentDeviceAlias;
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
                onTap: () async {
                  final ipMap = await _localIpsFuture;
                  if (ipMap.isEmpty) return;
                  if (context.mounted) {
                    _showIpSelectorDialog(context, ipMap, vm);
                  }
                },
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 4,
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: FutureBuilder<Map<String, String>>(
                      future: _localIpsFuture,
                      builder: (context, snapshot) {
                        final ipMap = snapshot.data ?? {};
                        final ips = ipMap.keys.toList();
                        final customIp = vm.customIp;
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
                                customIp == ip || (customIp == null && i == 0);
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
              onTap: _isRefreshingIps
                  ? null
                  : () async {
                      setState(() {
                        _isRefreshingIps = true;
                        _localIpsFuture =
                            LanDiscoveryService.getLocalIpInterfaces();
                      });
                      await _localIpsFuture;
                      if (mounted) setState(() => _isRefreshingIps = false);
                    },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: _isRefreshingIps
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

  Widget _buildRadarView(
    BuildContext context,
    LanShareStrings strings,
    LanShareViewModel vm,
  ) {
    final peers = vm.peerStates;
    if (peers.isEmpty) {
      if (vm.isScanning) {
        return AppEmptyState(
          icon: Icons.radar_rounded,
          title: strings.lanShareNoDevices,
          message: strings.lanShareRadarHint,
        );
      } else if (vm.lastScanError != null) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.wifi_off_rounded,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    strings.lanShareNoDevices,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2.0),
                        child: Icon(
                          Icons.error_rounded,
                          color: Colors.red,
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          strings.lanShareNoDevicesRefreshHint,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.red, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => vm.startScanning(),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(strings.isEnglish ? 'Rescan' : '重新搜索'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      } else {
        return AppEmptyState(
          icon: Icons.radar_rounded,
          title: strings.lanShareNoDevices,
          message: strings.lanShareRadarStoppedHint,
        );
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: peers.length,
      itemBuilder: (context, index) {
        final state = peers[index];
        final device = state.discovery;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: AppSectionCard(
            title: state.displayAlias,
            subtitle: device == null
                ? strings.lanShareOffline
                : '${device.ip} · ${device.os}',
            icon: device?.deviceType == LanDeviceType.mobile
                ? Icons.smartphone_rounded
                : Icons.desktop_windows_rounded,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state.isTrusted) ...[
                  const Icon(
                    Icons.shield_rounded,
                    color: Colors.green,
                    size: 14,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    state.isTrustedOffline ? '已配对 · 离线' : '已配对',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ] else ...[
                  const Icon(Icons.lock_rounded, color: Colors.grey, size: 14),
                  const SizedBox(width: 4),
                  const Text(
                    '未配对',
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
                if (_screenSharePort?.canShareWith(state.peerId) == true) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: strings.isEnglish ? 'Share screen' : '共享屏幕',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.screen_share_outlined, size: 18),
                    onPressed: () async {
                      try {
                        await _screenSharePort!.startScreenShare(state.peerId);
                      } catch (error) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text('$error')));
                      }
                    },
                  ),
                ],
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            onHeaderTap: () async {
              if (device == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(strings.lanShareOffline)),
                );
                return;
              }
              if (!context.mounted) return;
              if (state.isTrusted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LanShareFeatureScope(
                      child: LanChatScreen(
                        targetDeviceId: state.peerId,
                        initialAlias: state.displayAlias,
                      ),
                    ),
                  ),
                );
              } else {
                await _requestPairingWithFeedback(context, vm, device, strings);
              }
            },
            expanded: false,
          ),
        );
      },
    );
  }

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
                        setState(() {
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
                          setState(() {
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
                        setState(() {
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
