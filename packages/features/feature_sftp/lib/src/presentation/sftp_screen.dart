import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:animations/animations.dart';

import 'package:app_ui/app_ui.dart';

import '../application/sftp_viewmodel.dart';
import '../data/sftp_service.dart';
import '../domain/sftp_document.dart';
import '../domain/sftp_models.dart';
import '../domain/sftp_ports.dart';
import '../domain/sftp_strings.dart';
import 'sftp_editor_screen.dart';
import 'sftp_file_viewer_screen.dart';
import 'sftp_server_selector.dart';
import 'sftp_settings_screen.dart';

part 'sftp_server_pane.dart';
part 'sftp_file_pane.dart';
part 'sftp_file_toolbar.dart';
part 'sftp_file_actions.dart';
part 'sftp_path_history_sheet.dart';
part 'sftp_entry_list.dart';
part 'sftp_models.dart';

class SftpScreen extends StatefulWidget {
  const SftpScreen({super.key});

  @override
  State<SftpScreen> createState() => _SftpScreenState();
}

class _SftpScreenState extends State<SftpScreen> {
  static const _serversCollapsedStorageKey = 'sftp_servers_collapsed';

  bool _serversCollapsed = false;
  bool _restoredServersCollapsed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredServersCollapsed) return;
    _restoredServersCollapsed = true;
    final stored = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: _serversCollapsedStorageKey);
    if (stored is bool) _serversCollapsed = stored;
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<SftpSettingsPort, SftpLanguage>(
      (settings) => settings.language,
    );
    final strings = SftpStrings(language);
    final storageReady = context.select<SftpConnectionCatalogPort, bool>(
      (catalog) => !catalog.isLoading,
    );
    final connections = context
        .select<SftpConnectionCatalogPort, List<SftpConnectionInfo>>(
          (catalog) => catalog.connections,
        );
    final sftp = context.read<SftpViewModel>();
    final selectedConnectionId = context.select<SftpViewModel, String?>(
      (vm) => vm.connectionId,
    );
    final windowClass = WindowSizeClass.of(context);
    final isDesktopPlatform = isDesktopTargetPlatform();
    final useTwoColumnWorkspace =
        isDesktopPlatform || windowClass.isExpandedOrLarger;
    final selectedConnection = _selectedConnection(
      connections,
      selectedConnectionId,
    );
    final isNarrowDesktop = isDesktopPlatform && windowClass.isCompact;
    final serversCollapsed =
        (_serversCollapsed || isNarrowDesktop) && connections.isNotEmpty;

    if (!storageReady) {
      return AppPageSurface(
        child: AppSkeletonizer.zone(
          enabled: true,
          semanticsLabel: strings.loadingServerCatalog,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Bone(
                  width: double.infinity,
                  height: 48,
                  borderRadius: BorderRadius.circular(8),
                ),
                const SizedBox(height: 12),
                Bone(
                  width: double.infinity,
                  height: 48,
                  borderRadius: BorderRadius.circular(8),
                ),
                const SizedBox(height: 12),
                Bone(
                  width: double.infinity,
                  height: 48,
                  borderRadius: BorderRadius.circular(8),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (connections.isEmpty) {
      return AppPageSurface(
        child: AppEmptyState(
          icon: Icons.folder_open_rounded,
          title: strings.sftpEmptyTitle,
          message: strings.sftpEmptyHint,
          action: FilledButton.icon(
            onPressed: () => Navigator.pushNamed(context, '/add'),
            icon: const Icon(Icons.add_rounded),
            label: Text(strings.addConnection),
          ),
        ),
      );
    }

    return AppPageSurface(
      child: useTwoColumnWorkspace
          ? Row(
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.centerLeft,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: serversCollapsed
                        ? (isDesktopPlatform ? 56 : 64)
                        : (windowClass.isMedium ? 240 : 300),
                    child: serversCollapsed
                        ? Selector<
                            SftpViewModel,
                            _SftpConnectionStatusSnapshot
                          >(
                            selector: (_, service) =>
                                _SftpConnectionStatusSnapshot.from(
                                  service,
                                  selectedConnection?.id,
                                ),
                            builder: (context, status, _) =>
                                _CollapsedDesktopServerRail(
                                  selectedConnection: selectedConnection,
                                  busy: status.busy,
                                  connected: status.connected,
                                  strings: strings,
                                  onExpand: _expandServers,
                                ),
                          )
                        : _ServerPane(
                            connections: connections,
                            strings: strings,
                            onCollapse: _collapseServers,
                            onSelect: _connectServer,
                          ),
                  ),
                ),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Expanded(
                  child: _FilePane(strings: strings, sftp: sftp),
                ),
              ],
            )
          : Column(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: serversCollapsed
                      ? Selector<SftpViewModel, _SftpConnectionStatusSnapshot>(
                          key: const ValueKey('sftp-server-collapsed'),
                          selector: (_, service) =>
                              _SftpConnectionStatusSnapshot.from(
                                service,
                                selectedConnection?.id,
                              ),
                          builder: (context, status, _) =>
                              _CollapsedMobileServerBar(
                                selectedConnection: selectedConnection,
                                busy: status.busy,
                                connected: status.connected,
                                strings: strings,
                                onExpand: _expandServers,
                              ),
                        )
                      : _MobileServerStrip(
                          key: const ValueKey('sftp-server-expanded'),
                          connections: connections,
                          strings: strings,
                          onCollapse: _collapseServers,
                          onSelect: _connectServer,
                        ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Expanded(
                  child: _FilePane(strings: strings, sftp: sftp),
                ),
              ],
            ),
    );
  }

  void _collapseServers() {
    _setServersCollapsed(true);
  }

  void _expandServers() {
    _setServersCollapsed(false);
  }

  Future<void> _connectServer(String connectionId) async {
    final sftp = context.read<SftpViewModel>();
    _collapseServers();
    await sftp.connect(
      connectionId,
      onUnknownHostKey: (request) =>
          context.read<SftpHostKeyConfirmationPort>().confirm(request),
    );
  }

  void _setServersCollapsed(bool collapsed) {
    if (_serversCollapsed == collapsed) return;
    setState(() => _serversCollapsed = collapsed);
    PageStorage.maybeOf(
      context,
    )?.writeState(context, collapsed, identifier: _serversCollapsedStorageKey);
  }

  SftpConnectionInfo? _selectedConnection(
    List<SftpConnectionInfo> connections,
    String? activeConnectionId,
  ) {
    if (activeConnectionId == null) return null;
    for (final connection in connections) {
      if (connection.id == activeConnectionId) return connection;
    }
    return null;
  }
}
