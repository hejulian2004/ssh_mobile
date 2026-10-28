import 'package:flutter/material.dart';

import 'screen_share_controller.dart';
import 'screen_share_models.dart';

/// Small, dependency-free consent surface. Product navigation and theming are
/// owned by the App Shell; this widget only invokes Feature operations.
final class ScreenShareConsentView extends StatelessWidget {
  const ScreenShareConsentView({
    required this.controller,
    this.showIncomingActions = true,
    super.key,
  });

  final ScreenShareController controller;
  final bool showIncomingActions;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final snapshot = controller.snapshot;
      if (snapshot.state == ScreenShareOperationState.incomingPending &&
          showIncomingActions) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(screenShareMarkConsent(context, drawing: true)),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FilledButton(
                  onPressed: controller.acceptIncoming,
                  child: const Text('Accept screen share'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: controller.rejectIncoming,
                  child: const Text('Reject'),
                ),
              ],
            ),
          ],
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_label(snapshot.state)),
          if (snapshot.role == ScreenShareRole.sender) ...[
            const SizedBox(height: 8),
            Text(screenShareMarkConsent(context, drawing: false)),
          ],
        ],
      );
    },
  );
}

/// Pure source-selection surface for the App-owned source catalog.
///
/// The Feature owns the selection interaction and presentation of bounded
/// metadata. The App remains responsible for enumerating native sources and
/// resolving the selected route-scoped token back to its native descriptor.
final class ScreenShareSourcePicker extends StatelessWidget {
  const ScreenShareSourcePicker({
    required this.options,
    required this.onSelected,
    super.key,
  });

  final List<ScreenShareSourceOption> options;
  final ValueChanged<ScreenShareSourceOption> onSelected;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      children: <Widget>[
        const ListTile(
          title: Text('Choose what to share'),
          subtitle: Text('Only the selected display or window is shared.'),
        ),
        for (final option in options)
          ListTile(
            leading: Icon(
              option.kind == ScreenShareSourceKind.display
                  ? Icons.desktop_windows_outlined
                  : Icons.web_asset_outlined,
            ),
            title: Text(option.label),
            subtitle: Text(_sourceDimensions(option)),
            onTap: () => onSelected(option),
          ),
      ],
    ),
  );
}

String _sourceDimensions(ScreenShareSourceOption option) {
  if (option.width == 0 || option.height == 0) return 'Screen source';
  return '${option.width} × ${option.height}';
}

/// Consent copy for marks. Drawing is allowed; tapping for the other person is not.
String screenShareMarkConsent(BuildContext context, {required bool drawing}) {
  final chinese = Localizations.localeOf(context).languageCode == 'zh';
  if (drawing) {
    return chinese
        ? '你可以在对方屏幕上画标记，不能代替对方点击。'
        : 'You can draw marks on their screen. You cannot tap for them.';
  }
  return chinese
      ? '对方可以在屏幕上画标记，不能代替你点击。'
      : 'The other person can draw marks on your screen. They cannot tap for you.';
}

String _label(ScreenShareOperationState state) => switch (state) {
  ScreenShareOperationState.idle => 'Screen sharing idle',
  ScreenShareOperationState.outgoingPending => 'Waiting for acceptance',
  ScreenShareOperationState.incomingPending => 'Incoming screen-share request',
  ScreenShareOperationState.accepted => 'Screen share accepted',
  ScreenShareOperationState.active => 'Screen sharing active',
  ScreenShareOperationState.rejected => 'Screen-share request rejected',
  ScreenShareOperationState.cancelled => 'Screen sharing cancelled',
  ScreenShareOperationState.expired => 'Screen-share request expired',
  ScreenShareOperationState.failed => 'Screen sharing failed',
};
