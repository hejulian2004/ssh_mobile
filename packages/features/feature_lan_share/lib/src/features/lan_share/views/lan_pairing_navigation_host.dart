import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/lan_share/lan_share_models.dart';
import '../lan_share_feature_scope.dart';
import '../services/lan_receiver_coordinator.dart';
import '../viewmodels/lan_share_viewmodel.dart';
import 'lan_pairing_screen.dart';

@visibleForTesting
enum LanPairingNavigationDecision { ignored, open, updateActive, queued }

/// Owns the active pairing request and a FIFO queue for other devices.
/// Requests for the active peer are merged so an incoming role transition is
/// retained even when it arrives before the pairing screen subscribes.
@visibleForTesting
class LanPairingNavigationQueue {
  LanPairingRequest? _activeRequest;
  final List<LanPairingRequest> _pendingRequests = [];

  LanPairingRequest? get activeRequest => _activeRequest;
  int get pendingCount => _pendingRequests.length;

  LanPairingNavigationDecision add(LanPairingRequest request) {
    _removeExpiredPendingRequests();
    if (request.isExpired) return LanPairingNavigationDecision.ignored;

    final activeRequest = _activeRequest;
    if (activeRequest == null) {
      _activeRequest = request;
      return LanPairingNavigationDecision.open;
    }

    if (_matches(activeRequest, request)) {
      _activeRequest = _merge(activeRequest, request);
      return LanPairingNavigationDecision.updateActive;
    }

    final pendingIndex = _pendingRequests.indexWhere(
      (pending) => _matches(pending, request),
    );
    if (pendingIndex >= 0) {
      _pendingRequests[pendingIndex] = _merge(
        _pendingRequests[pendingIndex],
        request,
      );
    } else {
      _pendingRequests.add(request);
    }
    return LanPairingNavigationDecision.queued;
  }

  LanPairingRequest? completeActive() {
    _activeRequest = null;
    _removeExpiredPendingRequests();
    if (_pendingRequests.isEmpty) return null;
    _activeRequest = _pendingRequests.removeAt(0);
    return _activeRequest;
  }

  static bool _matches(LanPairingRequest current, LanPairingRequest incoming) {
    return current.sessionId == incoming.sessionId ||
        current.peer.peerId == incoming.peer.peerId;
  }

  static LanPairingRequest _merge(
    LanPairingRequest current,
    LanPairingRequest incoming,
  ) {
    return LanPairingRequest(
      peer: incoming.peer,
      // Keep one route identity while allowing a different-session request
      // from the same peer to change the active protocol role.
      sessionId: current.sessionId,
      isIncoming: current.isIncoming || incoming.isIncoming,
      expiresAt: incoming.expiresAt.isAfter(current.expiresAt)
          ? incoming.expiresAt
          : current.expiresAt,
    );
  }

  void _removeExpiredPendingRequests() {
    _pendingRequests.removeWhere((request) => request.isExpired);
  }
}

/// Keeps LAN pairing invitations active independently of the selected home tab
/// and owns the single root pairing route.
class LanPairingNavigationHost extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const LanPairingNavigationHost({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  @override
  State<LanPairingNavigationHost> createState() =>
      _LanPairingNavigationHostState();
}

class _LanPairingNavigationHostState extends State<LanPairingNavigationHost> {
  StreamSubscription<LanPairingRequest>? _subscription;
  final LanPairingNavigationQueue _requests = LanPairingNavigationQueue();
  ValueNotifier<LanPairingRequest>? _routeRequest;
  bool _routeOpen = false;
  bool _navigationScheduled = false;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    final coordinator = _findCoordinator(context);
    if (coordinator is LanReceiverCoordinator) {
      _subscription = coordinator.pairingRequestStream.listen(_handleRequest);
    } else if (coordinator is LanShareViewModel) {
      _subscription = coordinator.pairingRequestStream.listen(_handleRequest);
    }
    if (coordinator != null) {
      unawaited(
        _ensureCoordinatorInitialized(coordinator).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          debugPrint(
            '[LanPairingNavigationHost] Initialization failed: $error',
          );
        }),
      );
    }
  }

  static Object? _findCoordinator(BuildContext context) {
    try {
      return context.read<LanReceiverCoordinator>();
    } catch (_) {
      try {
        return context.read<LanShareViewModel>();
      } catch (_) {
        return null;
      }
    }
  }

  static Future<void> _ensureCoordinatorInitialized(Object? coordinator) async {
    if (coordinator is LanReceiverCoordinator) {
      await coordinator.ensureInitialized();
    } else if (coordinator is LanShareViewModel) {
      await coordinator.initialize();
    }
  }

  void _handleRequest(LanPairingRequest request) {
    if (!mounted) return;

    final decision = _requests.add(request);
    if (decision == LanPairingNavigationDecision.updateActive) {
      final mergedRequest = _requests.activeRequest;
      final routeRequest = _routeRequest;
      if (mergedRequest != null && routeRequest != null) {
        routeRequest.value = mergedRequest;
      }
      return;
    }
    if (decision == LanPairingNavigationDecision.open) {
      _scheduleOpenActivePairing();
    }
  }

  void _scheduleOpenActivePairing() {
    if (_navigationScheduled) return;
    _navigationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigationScheduled = false;
      if (!mounted || _routeOpen || _requests.activeRequest == null) return;
      if (widget.navigatorKey.currentState == null) return;
      _openActivePairing();
    });
    // Stream events can arrive while the app is idle; registering a post-frame
    // callback alone does not guarantee that another frame will be scheduled.
    WidgetsBinding.instance.scheduleFrame();
  }

  void _openActivePairing() {
    if (!mounted || _routeOpen) return;
    final request = _requests.activeRequest;
    if (request == null) return;

    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;

    _routeOpen = true;
    final routeRequest = ValueNotifier<LanPairingRequest>(request);
    _routeRequest = routeRequest;
    navigator
        .push<void>(
          MaterialPageRoute(
            builder: (_) => LanShareFeatureScope(
              child: ValueListenableBuilder<LanPairingRequest>(
                valueListenable: routeRequest,
                builder: (_, currentRequest, _) => LanPairingScreen(
                  // Keep the State (and any PIN already typed) when a reciprocal
                  // invitation upgrades the active request's role or endpoint.
                  key: ValueKey(currentRequest.sessionId),
                  targetDeviceId: currentRequest.peer.peerId,
                  initialAlias: currentRequest.peer.displayAlias,
                  sessionId: currentRequest.sessionId,
                  isIncomingRequest: currentRequest.isIncoming,
                ),
              ),
            ),
          ),
        )
        .whenComplete(() {
          routeRequest.dispose();
          if (!mounted) return;
          if (identical(_routeRequest, routeRequest)) {
            _routeRequest = null;
          }
          _routeOpen = false;
          final nextRequest = _requests.completeActive();
          if (nextRequest != null) _scheduleOpenActivePairing();
        });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
