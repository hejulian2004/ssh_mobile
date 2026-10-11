import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/features/startup/viewmodels/startup_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:app_ui/app_ui.dart';
import 'package:ssh_mobile/features/home/views/home_screen.dart';
import 'package:ssh_mobile/app/startup_branding.dart';

class StartupScreen extends StatefulWidget {
  final WidgetBuilder? homeBuilder;
  final VoidCallback? onReady;

  const StartupScreen({super.key, this.homeBuilder, this.onReady});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  bool _readyReported = false;

  void _reportReady() {
    if (_readyReported || widget.onReady == null) return;
    _readyReported = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onReady?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<StartupViewModel>();

    if (!viewModel.storageInitialized || !viewModel.settingsInitialized) {
      return const _StartupLoadingScreen();
    }

    if (!viewModel.isAndroidTarget) {
      return _buildHome(context);
    }

    viewModel.schedulePowerGuideCheck(() {
      if (mounted) {
        viewModel.checkPowerGuideStatus();
      }
    });

    if (!viewModel.powerStatusChecked) {
      return const _StartupLoadingScreen();
    }

    if (viewModel.shouldShowPowerGuide) {
      _reportReady();
      return PowerGuideScreen(viewModel: viewModel);
    }

    return _buildHome(context);
  }

  Widget _buildHome(BuildContext context) {
    _reportReady();
    return widget.homeBuilder?.call(context) ?? const HomeScreen();
  }
}

class _StartupLoadingScreen extends StatelessWidget {
  const _StartupLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.white,
      body: StartupBranding(),
    );
  }
}

class PowerGuideScreen extends StatelessWidget {
  final StartupViewModel viewModel;

  const PowerGuideScreen({super.key, required this.viewModel});

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(viewModel.language);

    return Scaffold(
      body: AppPageSurface(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < 480 || constraints.maxHeight < 480;
              final horizontalPadding = compact
                  ? AppTheme.compactPagePadding
                  : AppTheme.pagePadding;

              return ListView(
                key: const ValueKey('power-guide-scroll'),
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  compact ? 16 : 24,
                  horizontalPadding,
                  24,
                ),
                children: [
                  Center(
                    child: ConstrainedBox(
                      key: const ValueKey('power-guide-content'),
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _GuideHero(strings: strings, compact: compact),
                          const SizedBox(height: 16),
                          _PowerStatusCard(
                            isExempt: viewModel.isExempt,
                            strings: strings,
                          ),
                          const SizedBox(height: 20),
                          _GuideActions(
                            isExempt: viewModel.isExempt,
                            strings: strings,
                            onAdjustPower: viewModel.requestBatteryExemption,
                            onOpenSettings: viewModel.openAppSettings,
                            onContinue: viewModel.enterAppForThisLaunch,
                          ),
                          const SizedBox(height: 16),
                          _GuideNote(strings: strings),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _GuideHero extends StatelessWidget {
  final AppStrings strings;
  final bool compact;

  const _GuideHero({required this.strings, required this.compact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(compact ? 18 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const ExcludeSemantics(
                  child: AppIconBadge(
                    icon: Icons.battery_saver_rounded,
                    size: 52,
                    iconSize: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    strings.backgroundConnectionSettings,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Semantics(
              key: const ValueKey('power-guide-title'),
              container: true,
              header: true,
              label: strings.enableBackgroundPermission,
              child: ExcludeSemantics(
                child: Text(
                  strings.enableBackgroundPermission,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              strings.backgroundPermissionGuide,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 22),
            Divider(color: colorScheme.outlineVariant),
            const SizedBox(height: 18),
            Semantics(
              container: true,
              header: true,
              label: strings.backgroundChecklistTitle,
              child: ExcludeSemantics(
                child: Text(
                  strings.backgroundChecklistTitle,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ),
            const SizedBox(height: 10),
            _GuideRequirement(
              icon: Icons.sync_rounded,
              label: strings.allowBackgroundActivity,
            ),
            const SizedBox(height: 8),
            _GuideRequirement(
              icon: Icons.notifications_active_outlined,
              label: strings.allowNotifications,
            ),
            const SizedBox(height: 8),
            _GuideRequirement(
              icon: Icons.battery_5_bar_rounded,
              label: strings.relaxBatteryRestrictions,
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideRequirement extends StatelessWidget {
  final IconData icon;
  final String label;

  const _GuideRequirement({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 19, color: colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PowerStatusCard extends StatelessWidget {
  final bool isExempt;
  final AppStrings strings;

  const _PowerStatusCard({required this.isExempt, required this.strings});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final ext = Theme.of(context).extension<ExtendedColors>();
    final statusColor = isExempt
        ? (ext?.success ?? colorScheme.secondary)
        : (ext?.warning ?? colorScheme.tertiary);
    final statusForeground = theme.brightness == Brightness.light
        ? Color.alphaBlend(
            colorScheme.onSurface.withValues(alpha: 0.36),
            statusColor,
          )
        : statusColor;
    final status = isExempt
        ? strings.powerLimitExempt
        : strings.powerLimitUnknown;

    return Semantics(
      key: const ValueKey('power-guide-status'),
      container: true,
      liveRegion: true,
      label: status,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              statusColor.withValues(alpha: 0.08),
              colorScheme.surface,
            ),
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
            border: Border.all(color: statusForeground.withValues(alpha: 0.46)),
          ),
          child: Row(
            children: [
              Icon(
                isExempt
                    ? Icons.check_circle_rounded
                    : Icons.info_outline_rounded,
                color: statusForeground,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  status,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuideActions extends StatelessWidget {
  final bool isExempt;
  final AppStrings strings;
  final Future<void> Function() onAdjustPower;
  final VoidCallback onOpenSettings;
  final VoidCallback onContinue;

  const _GuideActions({
    required this.isExempt,
    required this.strings,
    required this.onAdjustPower,
    required this.onOpenSettings,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final fullWidthStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isExempt)
          FilledButton.icon(
            key: const ValueKey('power-guide-continue-action'),
            onPressed: onContinue,
            style: fullWidthStyle,
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(strings.continueToApp, textAlign: TextAlign.center),
          )
        else
          FilledButton.icon(
            key: const ValueKey('power-guide-battery-action'),
            onPressed: onAdjustPower,
            style: fullWidthStyle,
            icon: const Icon(Icons.battery_saver_rounded),
            label: Text(strings.adjustPowerLimit, textAlign: TextAlign.center),
          ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const ValueKey('power-guide-settings-action'),
          onPressed: onOpenSettings,
          style: fullWidthStyle,
          icon: const Icon(Icons.settings_outlined),
          label: Text(strings.openAppSettings, textAlign: TextAlign.center),
        ),
        if (!isExempt) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            key: const ValueKey('power-guide-continue-action'),
            onPressed: onContinue,
            style: fullWidthStyle,
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(strings.enterApp, textAlign: TextAlign.center),
          ),
        ],
      ],
    );
  }
}

class _GuideNote extends StatelessWidget {
  final AppStrings strings;

  const _GuideNote({required this.strings});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      key: const ValueKey('power-guide-note'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.lightbulb_outline_rounded,
              size: 20,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              strings.backgroundGuideNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
