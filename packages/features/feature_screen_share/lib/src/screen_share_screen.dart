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
        return Row(
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
        );
      }
      return Text(_label(snapshot.state));
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
