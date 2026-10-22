import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../../domain/lan_share_ports.dart';
import 'package:app_ui/app_ui.dart';
import '../services/lan_receiver_coordinator.dart';
import '../utils/lan_platform_capabilities.dart';
import '../viewmodels/lan_relay_settings_viewmodel.dart';
import '../viewmodels/lan_ui_outcome.dart';
import '../viewmodels/lan_share_viewmodel.dart';

class LanShareSettingsScreen extends StatefulWidget {
  const LanShareSettingsScreen({super.key, this.coordinator});

  /// 可选的显式 Coordinator，主要用于路由测试和嵌入式调用方。
  final LanReceiverCoordinator? coordinator;

  @override
  State<LanShareSettingsScreen> createState() => _LanShareSettingsScreenState();
}

class _LanShareSettingsScreenState extends State<LanShareSettingsScreen> {
  bool _notificationGranted = false;
  bool _cameraGranted = false;
  LanRelaySettingsViewModel? _relayViewModel;

  bool get _supportsRuntimePermissions => supportsLanShareRuntimePermissions(
    platform: defaultTargetPlatform,
    isWeb: kIsWeb,
  );

  @override
  void initState() {
    super.initState();
    _refreshPermissions();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_relayViewModel != null) return;
    final coordinator = widget.coordinator ?? _readCoordinator(context);
    if (coordinator != null) {
      _relayViewModel = LanRelaySettingsViewModel(coordinator);
    }
  }

  LanReceiverCoordinator? _readCoordinator(BuildContext context) {
    try {
      return context.read<LanReceiverCoordinator>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  void dispose() {
    _relayViewModel?.dispose();
    super.dispose();
  }

  Future<void> _refreshPermissions() async {
    if (!_supportsRuntimePermissions) return;
    final notification = await Permission.notification.status;
    final camera = await Permission.camera.status;
    if (!mounted) return;
    setState(() {
      _notificationGranted = notification.isGranted;
      _cameraGranted = camera.isGranted;
    });
  }

  Future<void> _requestPermission(Permission permission) async {
    final status = await permission.request();
    if (!mounted) return;
    setState(() {
      if (permission == Permission.notification) {
        _notificationGranted = status.isGranted;
      } else {
        _cameraGranted = status.isGranted;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<LanShareViewModel>();
    final settings = vm.appSettings;
    final strings = settings.strings;
    final alias = settings.lanDeviceAlias;
    final deviceId = settings.lanDeviceId;

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.lanShareSettings),
        leading: IconButton(
          tooltip: strings.close,
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: AppPageSurface(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppTheme.compactPagePadding),
            children: [
              AppSectionCard(
                title: strings.lanShareSettings,
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(
                        Icons.drive_file_rename_outline_rounded,
                      ),
                      title: Text(strings.lanDeviceAlias),
                      subtitle: Text(alias.isEmpty ? strings.unknown : alias),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _rename(context, settings, alias, strings),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.fingerprint_rounded),
                      title: Text(strings.lanDeviceId),
                      subtitle: Text(
                        deviceId.isEmpty ? strings.unknown : deviceId,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      trailing: IconButton(
                        tooltip: strings.copy,
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: deviceId.isEmpty
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: deviceId),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(strings.copy)),
                                  );
                                }
                              },
                      ),
                    ),
                    _buildRelayTile(context, settings, strings),
                  ],
                ),
              ),
              if (_supportsRuntimePermissions) ...[
                const SizedBox(height: 14),
                AppSectionCard(
                  title: strings.lanPermissions,
                  child: Column(
                    children: [
                      _PermissionTile(
                        title: strings.lanNotificationPermission,
                        granted: _notificationGranted,
                        onTap: _notificationGranted
                            ? null
                            : () => _requestPermission(Permission.notification),
                        strings: strings,
                      ),
                      _PermissionTile(
                        title: strings.lanCameraPermission,
                        granted: _cameraGranted,
                        onTap: _cameraGranted
                            ? null
                            : () => _requestPermission(Permission.camera),
                        strings: strings,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRelayTile(
    BuildContext context,
    LanShareSettingsPort settings,
    LanShareStrings strings,
  ) {
    final relayViewModel = _relayViewModel;
    if (relayViewModel == null) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.hub_outlined),
        title: Text(strings.lanRelayServer),
        subtitle: Text(
          settings.relayHost.isEmpty
              ? strings.unknown
              : '${settings.relayHost}:${settings.relayPort}',
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _editRelay(context, settings, strings),
      );
    }
    return AnimatedBuilder(
      animation: relayViewModel,
      builder: (context, _) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          relayViewModel.status.isConnected
              ? Icons.cloud_done_outlined
              : Icons.hub_outlined,
          color: relayViewModel.status.isConnected
              ? Theme.of(context).colorScheme.primary
              : null,
        ),
        title: Text(strings.lanRelayServer),
        subtitle: Text(_relaySubtitle(settings, strings, relayViewModel)),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: relayViewModel.busy
            ? null
            : () => _editRelay(context, settings, strings),
      ),
    );
  }

  String _relaySubtitle(
    LanShareSettingsPort settings,
    LanShareStrings strings,
    LanRelaySettingsViewModel relayViewModel,
  ) {
    final endpoint = settings.relayHost.isEmpty
        ? strings.unknown
        : '${settings.relayHost}:${settings.relayPort}';
    final status = relayViewModel.status;
    final statusText = switch (status.linkState) {
      LanRelayLinkState.connected => strings.connected,
      LanRelayLinkState.connecting => strings.lanRelayConnecting,
      LanRelayLinkState.failed => strings.lanRelayFailed,
      LanRelayLinkState.idle =>
        status.enrolled
            ? strings.disconnected
            : strings.lanRelayEnrollmentRequired,
    };
    return '$endpoint · $statusText';
  }

  Future<void> _rename(
    BuildContext context,
    LanShareSettingsPort settings,
    String current,
    LanShareStrings strings,
  ) async {
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) =>
          _AliasEditorDialog(current: current, strings: strings),
    );
    if (value != null && value.isNotEmpty) {
      await settings.setLanDeviceAlias(value);
    }
  }

  Future<void> _editRelay(
    BuildContext context,
    LanShareSettingsPort settings,
    LanShareStrings strings,
  ) async {
    final relayViewModel = _relayViewModel;
    if (relayViewModel != null) {
      await showDialog<void>(
        context: context,
        builder: (_) => _RelayEditorDialog(
          viewModel: relayViewModel,
          settings: settings,
          strings: strings,
        ),
      );
      return;
    }

    final value = await showDialog<(String, int)>(
      context: context,
      builder: (dialogContext) =>
          _FallbackRelayEditorDialog(settings: settings, strings: strings),
    );
    if (value == null || !context.mounted) return;
    try {
      await settings.setRelayServer(host: value.$1, port: value.$2);
    } on ArgumentError {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(strings.invalidPort)));
      }
    }
  }
}

class _AliasEditorDialog extends StatefulWidget {
  final String current;
  final LanShareStrings strings;

  const _AliasEditorDialog({required this.current, required this.strings});

  @override
  State<_AliasEditorDialog> createState() => _AliasEditorDialogState();
}

class _AliasEditorDialogState extends State<_AliasEditorDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.current);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.strings.lanDeviceAlias),
      content: TextField(
        controller: _controller,
        maxLength: 32,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.strings.lanDeviceAlias),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.strings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(widget.strings.save),
        ),
      ],
    );
  }
}

class _FallbackRelayEditorDialog extends StatefulWidget {
  final LanShareSettingsPort settings;
  final LanShareStrings strings;

  const _FallbackRelayEditorDialog({
    required this.settings,
    required this.strings,
  });

  @override
  State<_FallbackRelayEditorDialog> createState() =>
      _FallbackRelayEditorDialogState();
}

class _FallbackRelayEditorDialogState
    extends State<_FallbackRelayEditorDialog> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  String? _error;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.settings.relayHost);
    _port = TextEditingController(text: '${widget.settings.relayPort}');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      title: Text(strings.lanRelayServer),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _host,
            decoration: InputDecoration(labelText: strings.hostAddress),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: strings.port),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed: () {
            final parsed = int.tryParse(_port.text.trim());
            if (_host.text.trim().isEmpty ||
                parsed == null ||
                parsed < 1 ||
                parsed > 65535) {
              setState(() => _error = strings.invalidPort);
              return;
            }
            Navigator.pop(context, (_host.text.trim(), parsed));
          },
          child: Text(strings.save),
        ),
      ],
    );
  }
}

class _RelayEditorDialog extends StatefulWidget {
  const _RelayEditorDialog({
    required this.viewModel,
    required this.settings,
    required this.strings,
  });

  final LanRelaySettingsViewModel viewModel;
  final LanShareSettingsPort settings;
  final LanShareStrings strings;

  @override
  State<_RelayEditorDialog> createState() => _RelayEditorDialogState();
}

class _RelayEditorDialogState extends State<_RelayEditorDialog> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _tokenController;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.settings.relayHost);
    _portController = TextEditingController(
      text: '${widget.settings.relayPort}',
    );
    _tokenController = TextEditingController();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        final status = widget.viewModel.status;
        final busy = widget.viewModel.busy;
        return AlertDialog(
          title: Text(strings.lanRelayServer),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _RelayStatusBanner(status: status, strings: strings),
                const SizedBox(height: 14),
                TextField(
                  controller: _hostController,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: strings.hostAddress),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _portController,
                  enabled: !busy,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(labelText: strings.port),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _tokenController,
                  enabled: !busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: strings.lanRelayEnrollmentToken,
                    helperText: strings.lanRelayEnrollmentTokenHint,
                  ),
                ),
                if (widget.viewModel.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    widget.viewModel.error!.message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (status.enrolled && !status.isConnected)
              TextButton(
                onPressed: busy ? null : _connect,
                child: Text(strings.lanRelayConnect),
              ),
            if (status.isConnected || status.isConnecting)
              TextButton(
                onPressed: busy ? null : _disconnect,
                child: Text(strings.lanRelayDisconnect),
              ),
            if (status.enrolled || status.endpoint.isNotEmpty)
              TextButton(
                onPressed: busy ? null : _clear,
                child: Text(strings.lanRelayClear),
              ),
            TextButton(
              onPressed: busy ? null : () => Navigator.maybePop(context),
              child: Text(strings.cancel),
            ),
            FilledButton(
              onPressed: busy ? null : _save,
              child: busy
                  ? const AppLoadingIndicator(size: 18, strokeWidth: 2)
                  : Text(strings.save),
            ),
          ],
        );
      },
    );
  }

  Future<void> _save() async {
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < 1 || port > 65535) {
      _showError(widget.strings.invalidPort);
      return;
    }
    final result = await lanUiIgnored(
      widget.viewModel.save(
        host: _hostController.text,
        port: port,
        enrollmentToken: _tokenController.text,
      ),
    );
    if (!mounted) return;
    if (result.succeeded) {
      _tokenController.clear();
      Navigator.maybePop(context);
    }
  }

  Future<void> _connect() async {
    final result = await lanUiIgnored(widget.viewModel.connect());
    if (!mounted) return;
    if (result.succeeded) Navigator.maybePop(context);
  }

  Future<void> _disconnect() async {
    await widget.viewModel.disconnect();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(widget.strings.lanRelayClear),
        content: Text(widget.strings.deleteConnectionConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(widget.strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(widget.strings.lanRelayClear),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await lanUiIgnored(widget.viewModel.clear());
    if (!mounted) return;
    if (result.succeeded) Navigator.maybePop(context);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _RelayStatusBanner extends StatelessWidget {
  const _RelayStatusBanner({required this.status, required this.strings});

  final LanRelayStatus status;
  final LanShareStrings strings;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status.linkState) {
      LanRelayLinkState.connected => (
        strings.connected,
        Colors.green,
        Icons.cloud_done_outlined,
      ),
      LanRelayLinkState.connecting => (
        strings.lanRelayConnecting,
        Colors.orange,
        Icons.sync_rounded,
      ),
      LanRelayLinkState.failed => (
        strings.lanRelayFailed,
        Theme.of(context).colorScheme.error,
        Icons.error_outline_rounded,
      ),
      LanRelayLinkState.idle => (
        status.enrolled
            ? strings.disconnected
            : strings.lanRelayEnrollmentRequired,
        Theme.of(context).colorScheme.onSurfaceVariant,
        Icons.cloud_off_outlined,
      ),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          if (status.reconnectAttempt > 0 && !status.isConnected)
            Text(
              '${status.reconnectAttempt}/6',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  final String title;
  final bool granted;
  final VoidCallback? onTap;
  final LanShareStrings strings;

  const _PermissionTile({
    required this.title,
    required this.granted,
    required this.onTap,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        granted
            ? Icons.check_circle_outline_rounded
            : Icons.warning_amber_rounded,
        color: granted ? Colors.green : Colors.orange,
      ),
      title: Text(title),
      subtitle: Text(granted ? strings.connected : strings.unknown),
      onTap: onTap,
    );
  }
}
