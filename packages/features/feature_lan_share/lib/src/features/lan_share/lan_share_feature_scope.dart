import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:app_ui/app_ui.dart';

import '../../domain/lan_share_ports.dart';
import 'services/lan_receiver_coordinator.dart';
import 'viewmodels/lan_share_viewmodel.dart';

/// Provides the shared, lazily-created LAN page runtime to LAN routes.
///
/// The receiver coordinator owns the HTTPS/mDNS runtime for the application
/// lifetime. This scope only exposes its single page ViewModel, so routes do
/// not bind a second listener or dispose the shared receiver.
class LanShareFeatureScope extends StatefulWidget {
  final Widget child;

  const LanShareFeatureScope({super.key, required this.child});

  @override
  State<LanShareFeatureScope> createState() => _LanShareFeatureScopeState();
}

class _LanShareFeatureScopeState extends State<LanShareFeatureScope> {
  LanShareViewModel? _inheritedViewModel;
  LanReceiverCoordinator? _coordinator;
  Future<LanShareViewModel>? _viewModelFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    try {
      _inheritedViewModel = context.read<LanShareViewModel>();
      return;
    } on ProviderNotFoundException {
      _inheritedViewModel = null;
    }

    final coordinator = context.read<LanReceiverCoordinator>();
    if (!identical(_coordinator, coordinator)) {
      _coordinator = coordinator;
      _viewModelFuture = _activate(coordinator);
    }
  }

  void _retry() {
    setState(() {
      _viewModelFuture = _activate(_coordinator!);
    });
  }

  Future<LanShareViewModel> _activate(
    LanReceiverCoordinator coordinator,
  ) async {
    await coordinator.activateReceiver();
    return coordinator.ensureViewModel();
  }

  @override
  Widget build(BuildContext context) {
    final currentVm = _inheritedViewModel ?? _coordinator?.viewModel;
    if (currentVm != null) {
      return ChangeNotifierProvider<LanShareViewModel>.value(
        value: currentVm,
        child: widget.child,
      );
    }
    final strings = context.select<LanShareSettingsPort, LanShareStrings>(
      (settings) => settings.strings,
    );

    return FutureBuilder<LanShareViewModel>(
      future: _viewModelFuture,
      initialData: _coordinator?.viewModel,
      builder: (context, snapshot) {
        final viewModel = snapshot.data;
        if (viewModel != null) {
          return ChangeNotifierProvider<LanShareViewModel>.value(
            value: viewModel,
            child: widget.child,
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi_off_rounded, size: 40),
                      const SizedBox(height: 12),
                      Text(
                        strings.lanShareInitializationFailed,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _retry,
                        child: Text(strings.retry),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        return Scaffold(body: _LanShareScreenSkeleton(strings: strings));
      },
    );
  }
}

class _LanShareScreenSkeleton extends StatelessWidget {
  const _LanShareScreenSkeleton({required this.strings});

  final LanShareStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final label = strings.isEnglish ? 'This Device: ' : '本机设备：';

    return AppSkeletonizer.zone(
      enabled: true,
      semanticsLabel: strings.lanShare,
      child: AppPageSurface(
        child: SafeArea(
          child: Column(
            children: [
              // Page Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: AppPageHeader(
                  title: strings.lanShare,
                  subtitleWidget: Text(
                    strings.lanShareRadarHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  icon: Icons.radar_rounded,
                  trailing: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.qr_code_scanner_rounded, size: 22),
                      SizedBox(width: 14),
                      Icon(Icons.qr_code_outlined, size: 22),
                      SizedBox(width: 14),
                      Icon(Icons.sync_rounded, size: 22),
                      SizedBox(width: 14),
                      Icon(Icons.more_vert_rounded, size: 22),
                    ],
                  ),
                ),
              ),

              // Self info bar
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: colorScheme.primary.withValues(alpha: 0.18),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.perm_device_info_rounded,
                        size: 16,
                        color: colorScheme.primary.withValues(alpha: 0.75),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Row(
                          children: [
                            Text(
                              label,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              'Local Device',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_drop_down_rounded,
                        size: 18,
                        color: colorScheme.primary.withValues(alpha: 0.8),
                      ),
                    ],
                  ),
                ),
              ),

              // Tabs
              DefaultTabController(
                length: 2,
                child: TabBar(
                  tabs: [
                    Tab(text: strings.lanShareDeviceList),
                    Tab(text: strings.lanShareTransferHistory),
                  ],
                ),
              ),

              // Body: Radar Scanning state
              Expanded(
                child: AppEmptyState(
                  icon: Icons.radar_rounded,
                  title: strings.lanShareNoDevices,
                  message: strings.lanShareRadarHint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
