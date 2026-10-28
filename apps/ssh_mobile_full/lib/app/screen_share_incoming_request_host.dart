import 'dart:async';

import 'package:feature_lan_share/feature_lan_share.dart' as lan;
import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/material.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:realtime_media/realtime_media.dart';

import 'app_runtime.dart';
import 'navigation/app_route_contributions.dart';
import 'screen_share_peer_arbitration.dart';
import 'screen_share_route_scope.dart';
import 'screen_share_session_lease.dart';

/// App-global host for incoming screen-share requests. It is mounted around
/// the MaterialApp child so a request is visible while the user is in any
/// feature route, not only LAN Share.
final class AppScreenShareIncomingRequestHost extends StatefulWidget {
  const AppScreenShareIncomingRequestHost({
    required this.runtime,
    required this.navigatorKey,
    required this.screenSharePort,
    required this.arbitration,
    required this.sessions,
    required this.child,
    super.key,
  });

  final AppRuntime runtime;
  final GlobalKey<NavigatorState> navigatorKey;
  final lan.LanShareScreenSharePort screenSharePort;
  final AppScreenSharePeerArbitrationRegistry arbitration;
  final AppScreenShareSessions sessions;
  final Widget child;

  @override
  State<AppScreenShareIncomingRequestHost> createState() =>
      _AppScreenShareIncomingRequestHostState();
}

enum _IncomingOfferState { pending, resolving, handedOff, terminal }

final class _AppScreenShareIncomingRequestHostState
    extends State<AppScreenShareIncomingRequestHost> {
  StreamSubscription<RealtimeIncomingSessionOffer>? _subscription;
  RealtimeIncomingSessionOffer? _offer;
  RealtimeIncomingSessionOffer? _activeOffer;
  final Map<String, DateTime> _seenOffers = <String, DateTime>{};
  Timer? _offerExpiryTimer;
  _IncomingOfferState _offerState = _IncomingOfferState.terminal;
  int _hostEpoch = 0;
  int? _activeOfferEpoch;
  final Completer<void> _disposedSignal = Completer<void>();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.runtime.realtimeClient.incomingOffers.listen(
      _onOffer,
    );
    widget.arbitration.addListener(_onBusyChanged);
  }

  void _onBusyChanged() {
    final pending = _offer;
    if (mounted &&
        widget.arbitration.isBusy &&
        pending != null &&
        _offerState == _IncomingOfferState.pending) {
      unawaited(
        _reject(pending).catchError((_) => _discardBestEffort(pending)),
      );
    }
  }

  void _onOffer(RealtimeIncomingSessionOffer offer) {
    final now = DateTime.now().toUtc();
    if (!mounted ||
        !widget.screenSharePort.canReceiveScreenShareFrom(
          offer.authenticatedPeerId,
        )) {
      _discardBestEffort(offer);
      return;
    }
    _pruneSeenOffers(now);
    final effectiveExpiry = _effectiveExpiry(offer);
    if (!effectiveExpiry.isAfter(now)) {
      _discardBestEffort(offer);
      return;
    }
    final key = _offerKey(offer);
    if (_seenOffers.containsKey(key)) {
      _discardBestEffort(offer);
      return;
    }
    if (widget.arbitration.isBusy) {
      _rememberOffer(key, effectiveExpiry, now);
      _rejectBusyBestEffort(offer);
      return;
    }
    if (_offer != null) {
      // Keep one user decision at a time, including while claim/reject awaits
      // native completion. An extra request always gets a formal response.
      _rememberOffer(key, effectiveExpiry, now);
      _rejectBusyBestEffort(offer);
      return;
    }
    _rememberOffer(key, effectiveExpiry, now);
    // Keep this epoch tentative until arbitration accepts the candidate. A
    // losing intent must not invalidate the current owner's expiry callback.
    final candidateEpoch = _hostEpoch + 1;
    final acquired = widget.arbitration.acquire(
      remotePeerId: offer.authenticatedPeerId,
      initiatorPeerId: offer.request.senderPeerId,
      operationId: offer.request.operationId,
      onReplaced: () async {
        if (_isExactPending(offer, candidateEpoch)) {
          await _reject(offer);
        }
      },
    );
    if (!acquired) {
      _rejectBusyBestEffort(offer);
      return;
    }
    _hostEpoch = candidateEpoch;
    _offer = offer;
    _offerState = _IncomingOfferState.pending;
    _busy = false;
    _armExpiryTimer(offer, candidateEpoch, effectiveExpiry);
    setState(() {});
  }

  @override
  void dispose() {
    _disposedSignal.complete();
    widget.arbitration.removeListener(_onBusyChanged);
    _offerExpiryTimer?.cancel();
    _offerExpiryTimer = null;
    unawaited(_subscription?.cancel());
    final pending = _offer;
    if (pending != null && _offerState == _IncomingOfferState.pending) {
      _discardBestEffort(pending);
    }
    for (final offer in <RealtimeIncomingSessionOffer>{?pending}) {
      widget.arbitration.release(
        remotePeerId: offer.authenticatedPeerId,
        initiatorPeerId: offer.request.senderPeerId,
        operationId: offer.request.operationId,
      );
    }
    _offerState = _IncomingOfferState.terminal;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: <Widget>[
      widget.child,
      if (_offer != null) _buildRequestCard(context, _offer!),
    ],
  );

  Widget _buildRequestCard(
    BuildContext context,
    RealtimeIncomingSessionOffer offer,
  ) => Positioned(
    left: 16,
    right: 16,
    bottom: 16,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Incoming screen-share request',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text('Peer ${offer.authenticatedPeerId} wants to share a screen.'),
            const SizedBox(height: 8),
            Text(screenShareMarkConsent(context, drawing: true)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: _busy ? null : () => _reject(offer),
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : () => _accept(offer),
                  child: const Text('Accept'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _reject(RealtimeIncomingSessionOffer offer) async {
    if (!_beginResolving(offer)) return;
    final ownerEpoch = _hostEpoch;
    try {
      await widget.runtime.realtimeClient.rejectIncomingOffer(offer);
    } finally {
      _finish(offer, ownerEpoch);
    }
  }

  Future<void> _accept(RealtimeIncomingSessionOffer offer) async {
    if (!_beginResolving(offer)) return;
    final ownerEpoch = _hostEpoch;
    AppScreenShareSessionLease? lease;
    const codecMode = RealtimeMediaCodecMode.automatic;
    RealtimeSession? session;
    var handedOff = false;
    try {
      if (!widget.arbitration.activate(
        remotePeerId: offer.authenticatedPeerId,
        initiatorPeerId: offer.request.senderPeerId,
        operationId: offer.request.operationId,
      )) {
        await widget.runtime.realtimeClient.rejectIncomingOffer(offer);
        return;
      }
      final result = await widget.runtime.realtimeClient.claimIncomingSession(
        offer,
      );
      if (result is SdkFailure<RealtimeSession>) {
        throw StateError(result.error.message);
      }
      session = (result as SdkSuccess<RealtimeSession>).data;
      if (!_isExactPendingOwner(offer, ownerEpoch)) return;
      await waitForScreenShareSessionIdentity(
        session,
        cancelled: _disposedSignal.future,
      );
      if (!_isExactPendingOwner(offer, ownerEpoch)) return;
      lease = AppScreenShareSessionLease(
        client: widget.runtime.realtimeClient,
        session: session,
      );
      final arguments = AppScreenShareRouteArguments(
        session: session,
        sessionLease: lease,
        localPeerId: widget.runtime.lanShareSettingsAdapter.lanDeviceId,
        operationId: offer.request.operationId,
        initialIncomingRequest: offer.request,
        mode: AppScreenShareRouteMode.receive,
        acceptIncomingOnOpen: true,
        codecMode: codecMode,
        arbitration: widget.arbitration,
      );
      final operation = widget.sessions.open(
        arguments,
        widget.runtime.realtimeMediaResources,
      );
      handedOff = true;
      lease = null;
      _activeOffer = offer;
      _activeOfferEpoch = ownerEpoch;
      _offerState = _IncomingOfferState.handedOff;
      if (mounted && identical(_offer, offer)) {
        setState(() {
          _offer = null;
          _busy = false;
        });
      }
      try {
        await widget.navigatorKey.currentState!.pushNamed(
          AppShellRouteNames.screenShare,
          arguments: arguments,
        );
      } catch (_) {
        await operation.stop();
        rethrow;
      }
    } finally {
      if (!handedOff && session != null) {
        if (lease != null) {
          await lease.stopAndRelease();
        } else {
          try {
            await session.stop();
          } catch (_) {}
          await widget.runtime.realtimeClient.releaseSession(session);
        }
      }
      _finish(offer, ownerEpoch);
    }
  }

  void _finish(RealtimeIncomingSessionOffer offer, int ownerEpoch) {
    if (_isExactPendingOwner(offer, ownerEpoch)) {
      _finishPending(offer, ownerEpoch);
    }
    if (_isExactActive(offer, ownerEpoch)) {
      _finishActive(offer, ownerEpoch);
    }
  }

  bool _beginResolving(RealtimeIncomingSessionOffer offer) {
    if (!mounted ||
        !identical(_offer, offer) ||
        _offerState != _IncomingOfferState.pending) {
      return false;
    }
    _offerExpiryTimer?.cancel();
    _offerExpiryTimer = null;
    _offerState = _IncomingOfferState.resolving;
    _busy = true;
    setState(() {});
    return true;
  }

  bool _isExactPending(RealtimeIncomingSessionOffer offer, int hostEpoch) =>
      mounted &&
      identical(_offer, offer) &&
      _offerState == _IncomingOfferState.pending &&
      hostEpoch == _hostEpoch;

  bool _isExactPendingOwner(
    RealtimeIncomingSessionOffer offer,
    int hostEpoch,
  ) =>
      mounted &&
      identical(_offer, offer) &&
      (_offerState == _IncomingOfferState.pending ||
          _offerState == _IncomingOfferState.resolving) &&
      hostEpoch == _hostEpoch;

  bool _isExactActive(RealtimeIncomingSessionOffer offer, int hostEpoch) =>
      mounted &&
      identical(_activeOffer, offer) &&
      _activeOfferEpoch == hostEpoch;

  Future<void> _expirePending(
    RealtimeIncomingSessionOffer offer,
    int hostEpoch,
  ) async {
    if (!_isExactPending(offer, hostEpoch)) return;
    _offerExpiryTimer?.cancel();
    _offerExpiryTimer = null;
    _offerState = _IncomingOfferState.terminal;
    _offer = null;
    _busy = false;
    widget.arbitration.release(
      remotePeerId: offer.authenticatedPeerId,
      initiatorPeerId: offer.request.senderPeerId,
      operationId: offer.request.operationId,
    );
    if (mounted) setState(() {});
    try {
      await widget.runtime.realtimeClient.discardIncomingOffer(offer);
    } catch (_) {
      // Native expiry is authoritative; this is only the UX cleanup path.
    }
  }

  void _finishPending(
    RealtimeIncomingSessionOffer offer,
    int ownerEpoch, {
    bool discard = false,
  }) {
    if (!_isExactPendingOwner(offer, ownerEpoch)) return;
    _offerExpiryTimer?.cancel();
    _offerExpiryTimer = null;
    _offerState = _IncomingOfferState.terminal;
    _offer = null;
    _busy = false;
    widget.arbitration.release(
      remotePeerId: offer.authenticatedPeerId,
      initiatorPeerId: offer.request.senderPeerId,
      operationId: offer.request.operationId,
    );
    if (discard) _discardBestEffort(offer);
    if (mounted) setState(() {});
  }

  void _finishActive(RealtimeIncomingSessionOffer offer, int ownerEpoch) {
    if (!_isExactActive(offer, ownerEpoch)) return;
    _activeOffer = null;
    _activeOfferEpoch = null;
    // The App operation owns admission after handoff, including without a page.
    // A pending replacement owns the global state and timer. An old active
    // route completion must never overwrite it.
    if (_offer == null && _offerState == _IncomingOfferState.handedOff) {
      _offerState = _IncomingOfferState.terminal;
      _busy = false;
    }
    if (mounted) setState(() {});
  }

  void _discardBestEffort(RealtimeIncomingSessionOffer offer) {
    unawaited(() async {
      try {
        await widget.runtime.realtimeClient.discardIncomingOffer(offer);
      } catch (_) {
        // Native expiry/terminal cleanup is authoritative; this callback only
        // releases the Host's best-effort UI owner.
      }
    }());
  }

  void _rejectBusyBestEffort(RealtimeIncomingSessionOffer offer) {
    unawaited(() async {
      try {
        final result = await widget.runtime.realtimeClient.rejectIncomingOffer(
          offer,
        );
        if (result is SdkFailure<void>) _discardBestEffort(offer);
      } catch (_) {
        _discardBestEffort(offer);
      }
    }());
  }

  void _armExpiryTimer(
    RealtimeIncomingSessionOffer offer,
    int hostEpoch,
    DateTime expiry,
  ) {
    _offerExpiryTimer?.cancel();
    final delay = expiry.difference(DateTime.now().toUtc());
    _offerExpiryTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_expirePending(offer, hostEpoch)),
    );
  }

  DateTime _effectiveExpiry(RealtimeIncomingSessionOffer offer) {
    final binding = offer.bindingExpiresAt.toUtc();
    final request = offer.request.expiresAt.toUtc();
    return binding.isBefore(request) ? binding : request;
  }

  void _rememberOffer(String key, DateTime effectiveExpiry, DateTime now) {
    final retention =
        effectiveExpiry.isAfter(now.add(const Duration(minutes: 5)))
        ? effectiveExpiry
        : now.add(const Duration(minutes: 5));
    _seenOffers[key] = retention;
    _pruneSeenOffers(now);
    if (_seenOffers.length <= 256) return;
    final oldest = _seenOffers.entries.reduce(
      (left, right) => left.value.isBefore(right.value) ? left : right,
    );
    _seenOffers.remove(oldest.key);
  }

  void _pruneSeenOffers(DateTime now) {
    _seenOffers.removeWhere((_, expiry) => !expiry.isAfter(now));
  }

  String _offerKey(RealtimeIncomingSessionOffer offer) =>
      '${offer.authenticatedPeerId}|${offer.realtimeId}|${offer.request.operationId}';
}
