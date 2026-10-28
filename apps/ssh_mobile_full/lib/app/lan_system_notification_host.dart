import 'package:app_notifications/app_notifications.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Connects LAN events to the full app's system notification center.
class LanSystemNotificationHost extends StatefulWidget {
  const LanSystemNotificationHost({
    super.key,
    required this.navigatorKey,
    required this.english,
    required this.child,
    this.center,
    this.diagnostic,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final bool Function() english;
  final Widget child;
  final AppNotificationCenter? center;
  final AppNotificationDiagnostic? diagnostic;

  @override
  State<LanSystemNotificationHost> createState() =>
      _LanSystemNotificationHostState();
}

class _LanSystemNotificationHostState extends State<LanSystemNotificationHost> {
  final LanVisibleChat _visibleChat = LanVisibleChat();

  Future<void> _activate(AppNotificationPayload payload) {
    if (!mounted) return Future<void>.value();
    final coordinator = _readCoordinator(context);
    final clickContext = readLanNotificationClickContext(
      coordinator?.viewModel,
      payload.peerId,
    );
    final decision = decideLanNotificationClick(
      kind: _kind(payload.kind),
      peerId: payload.peerId,
      businessId: payload.businessId,
      history: clickContext.history,
      visiblePeerId: _visibleChat.peerId,
    );
    openLanNotificationChat(
      navigator: widget.navigatorKey.currentState,
      decision: decision,
      initialAlias: clickContext.alias,
    );
    return Future<void>.value();
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = _readCoordinator(context);
    return SystemNotificationScope(
      identity: AppNotificationIdentity.full,
      center: widget.center,
      diagnostic: widget.diagnostic,
      onActivate: _activate,
      child: Builder(
        builder: (context) {
          final presenter = SystemNotificationScope.maybeOf(context);
          return MultiProvider(
            providers: [
              Provider<LanVisibleChat>.value(value: _visibleChat),
              if (presenter != null)
                Provider<LanSystemNotificationPort>.value(
                  value: _LanNotificationPort(presenter, widget.english),
                ),
            ],
            child: coordinator == null
                ? widget.child
                : LanNotificationBinder(
                    listenable: coordinator,
                    events: () => _events(coordinator),
                    child: widget.child,
                  ),
          );
        },
      ),
    );
  }
}

LanReceiverCoordinator? _readCoordinator(BuildContext context) {
  try {
    return Provider.of<LanReceiverCoordinator>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

Stream<LanNotificationEvent>? _events(LanReceiverCoordinator coordinator) {
  return coordinator.viewModel?.notificationEvents;
}

LanNotificationKind _kind(AppNotificationKind kind) {
  return switch (kind) {
    AppNotificationKind.message => LanNotificationKind.message,
    AppNotificationKind.transferRequest => LanNotificationKind.transferRequest,
    AppNotificationKind.transferSucceeded =>
      LanNotificationKind.transferSucceeded,
    AppNotificationKind.transferFailed => LanNotificationKind.transferFailed,
  };
}

final class _LanNotificationPort implements LanSystemNotificationPort {
  _LanNotificationPort(this._presenter, this._english);

  final SystemNotificationPresenter _presenter;
  final bool Function() _english;

  @override
  Future<void> present(LanNotificationEvent event) {
    return _presenter.present(
      AppNotificationRequest(
        kind: switch (event.kind) {
          LanNotificationKind.message => AppNotificationKind.message,
          LanNotificationKind.transferRequest =>
            AppNotificationKind.transferRequest,
          LanNotificationKind.transferSucceeded =>
            AppNotificationKind.transferSucceeded,
          LanNotificationKind.transferFailed =>
            AppNotificationKind.transferFailed,
        },
        peerId: event.peerId,
        businessId: event.businessId,
        displayName: event.displayName,
        english: _english(),
      ),
    );
  }
}
