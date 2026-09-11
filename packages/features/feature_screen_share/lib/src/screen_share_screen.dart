import 'package:flutter/material.dart';

import 'screen_share_controller.dart';
import 'screen_share_models.dart';

/// Small, dependency-free consent surface. Product navigation and theming are
/// owned by the App Shell; this widget only invokes Feature operations.
final class ScreenShareConsentView extends StatelessWidget {
  const ScreenShareConsentView({required this.controller, super.key});

  final ScreenShareController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final snapshot = controller.snapshot;
      if (snapshot.state == ScreenShareOperationState.incomingPending) {
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
