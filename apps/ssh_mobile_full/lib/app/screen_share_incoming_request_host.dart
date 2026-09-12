import 'dart:async';

import 'package:feature_lan_share/feature_lan_share.dart' as lan;
import 'package:flutter/material.dart';
import 'package:network_sdk/network_sdk.dart';

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
    required this.child,
    super.key,
  });

  final AppRuntime runtime;
  final GlobalKey<NavigatorState> navigatorKey;
  final lan.LanShareScreenSharePort screenSharePort;
  final AppScreenSharePeerArbitrationRegistry arbitration;
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
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.runtime.realtimeClient.incomingOffers.listen(
      _onOffer,
    );
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
    if (_offer != null && _offerState != _IncomingOfferState.pending) {
      // A claim/reject resolution already owns the current offer. Do not let
      // a later notification replace it or discard its provisional binding.
      _discardBestEffort(offer);
      return;
    }
    _rememberOffer(key, effectiveExpiry, now);
    final candidateEpoch = ++_hostEpoch;
    final acquired = widget.arbitration.acquire(
      remotePeerId: offer.authenticatedPeerId,
      initiatorPeerId: offer.request.senderPeerId,
      operationId: offer.request.operationId,
      onReplaced: () async {
        if (_isExactPending(offer, candidateEpoch)) {
          await _expirePending(offer, candidateEpoch);
        } else if (mounted && identical(_activeOffer, offer)) {
          unawaited(widget.navigatorKey.currentState?.maybePop());
        }
      },
    );
    if (!acquired) {
      _discardBestEffort(offer);
      return;
    }
    final previous = _offer;
    if (previous != null && !identical(previous, offer)) {
      _finishPending(previous);
    }
    _offer = offer;
    _offerState = _IncomingOfferState.pending;
    _busy = false;
    _armExpiryTimer(offer, candidateEpoch, effectiveExpiry);
    setState(() {});
  }

  @override
  void dispose() {
    _offerExpiryTimer?.cancel();
    _offerExpiryTimer = null;
    unawaited(_subscription?.cancel());
    final pending = _offer;
    final active = _activeOffer;
    if (pending != null && _offerState == _IncomingOfferState.pending) {
      _discardBestEffort(pending);
    }
    for (final offer in <RealtimeIncomingSessionOffer>{?pending, ?active}) {
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
    try {
      await widget.runtime.realtimeClient.rejectIncomingOffer(offer);
    } finally {
      _finish(offer);
    }
  }

  Future<void> _accept(RealtimeIncomingSessionOffer offer) async {
    if (!_beginResolving(offer)) return;
    AppScreenShareSessionLease? lease;
    RealtimeSession? session;
    var handedOff = false;
    try {
      final result = await widget.runtime.realtimeClient.claimIncomingSession(
        offer,
      );
      if (result is SdkFailure<RealtimeSession>) {
        throw StateError(result.error.message);
      }
      session = (result as SdkSuccess<RealtimeSession>).data;
      await _waitForIdentity(session);
      lease = AppScreenShareSessionLease(
        client: widget.runtime.realtimeClient,
        session: session,
      );
      final navigation = widget.navigatorKey.currentState!.pushNamed(
        AppShellRouteNames.screenShare,
        arguments: AppScreenShareRouteArguments(
          session: session,
          sessionLease: lease,
          localPeerId: widget.runtime.lanShareSettingsAdapter.lanDeviceId,
          operationId: offer.request.operationId,
          initialIncomingRequest: offer.request,
          mode: AppScreenShareRouteMode.receive,
          acceptIncomingOnOpen: true,
        ),
      );
      // Transfer ownership as soon as Navigator installs the route. The
      // returned Future completes only after the eventual pop.
      handedOff = true;
      lease = null;
      _activeOffer = offer;
      _offerState = _IncomingOfferState.handedOff;
      if (mounted && identical(_offer, offer)) {
        setState(() {
          _offer = null;
          _busy = false;
        });
      }
      await navigation;
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
      _finish(offer);
    }
  }

  void _finish(RealtimeIncomingSessionOffer offer) {
    _offerExpiryTimer?.cancel();
    _offerExpiryTimer = null;
    _offerState = _IncomingOfferState.terminal;
    widget.arbitration.release(
      remotePeerId: offer.authenticatedPeerId,
      initiatorPeerId: offer.request.senderPeerId,
      operationId: offer.request.operationId,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (identical(_offer, offer)) _offer = null;
      if (identical(_activeOffer, offer)) _activeOffer = null;
    });
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

  void _finishPending(RealtimeIncomingSessionOffer offer) {
    widget.arbitration.release(
      remotePeerId: offer.authenticatedPeerId,
      initiatorPeerId: offer.request.senderPeerId,
      operationId: offer.request.operationId,
    );
    _discardBestEffort(offer);
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

  Future<void> _waitForIdentity(RealtimeSession session) async {
    bool ready(RealtimeSnapshot? snapshot) {
      final state = snapshot?.state ?? session.state;
      return (state == RealtimeSessionState.negotiating ||
              state == RealtimeSessionState.connected) &&
          (snapshot?.generation ?? session.generation) != null &&
          (snapshot?.sharedSessionInstanceId ??
                  session.sharedSessionInstanceId) !=
              null;
    }

    if (ready(session.currentSnapshot)) return;
    final completer = Completer<void>();
    late final StreamSubscription<RealtimeSnapshot> subscription;
    subscription = session.snapshots.listen((snapshot) {
      if (!completer.isCompleted && ready(snapshot)) completer.complete();
    });
    try {
      if (ready(session.currentSnapshot)) return;
      await completer.future.timeout(const Duration(seconds: 30));
    } finally {
      await subscription.cancel();
    }
  }

  String _offerKey(RealtimeIncomingSessionOffer offer) =>
      '${offer.authenticatedPeerId}|${offer.realtimeId}|${offer.request.operationId}';
}
