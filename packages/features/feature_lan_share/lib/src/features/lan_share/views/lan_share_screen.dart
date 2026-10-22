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
import 'package:feature_lan_share/src/features/lan_share/viewmodels/lan_ui_outcome.dart';
import 'package:feature_lan_share/src/services/lan_share/lan_share_models.dart';
import 'package:feature_lan_share/src/services/lan_share/lan_web_share_url.dart';
import '../lan_share_feature_scope.dart';
import 'lan_chat_screen.dart';
import 'lan_qr_scanner_screen.dart';
import 'lan_share_settings_screen.dart';
import 'widgets/lan_manual_add_dialog.dart';
import 'widgets/lan_peer_device_card.dart';
import 'widgets/lan_share_self_info.dart';
import '../../../domain/lan_device_strings.dart';

part 'widgets/lan_share_dialogs.dart';

part 'widgets/lan_share_devices.dart';
part 'widgets/lan_share_history.dart';

class LanShareScreen extends StatefulWidget {
  const LanShareScreen({super.key});

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
  bool _ipsInitialized = false;
  void _refreshView(VoidCallback change) => setState(change);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _localIpsFuture = Future<Map<String, String>>.value(const {});
    unawaited(_initShareHandler());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final vm = context.read<LanShareViewModel>();
    if (!_ipsInitialized) {
      _ipsInitialized = true;
      _localIpsFuture = vm.localIpInterfaces();
    }
    if (!_scanningInitialized) {
      _scanningInitialized = true;
      if (!vm.isScanning) {
        unawaited(vm.startScanning());
      }
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
  ) => LanSelfDeviceInfoBar(
    alias: vm.discoveryService.currentDeviceAlias,
    strings: strings,
    interfaces: _localIpsFuture,
    customIp: vm.customIp,
    selection: vm.webShareAddressSelectionResult,
    refreshing: _isRefreshingIps,
    onSelect: () async {
      final interfaces = await _localIpsFuture;
      if (interfaces.isNotEmpty && context.mounted) {
        _showIpSelectorDialog(context, interfaces, vm);
      }
    },
    onRefresh: () async {
      _refreshView(() {
        _isRefreshingIps = true;
        _localIpsFuture = vm.localIpInterfaces();
      });
      await _localIpsFuture;
      if (mounted) _refreshView(() => _isRefreshingIps = false);
    },
  );
}
