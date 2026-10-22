part of 'lan_native_transfer_coordinator.dart';

extension LanNativeTransferResponses on LanNativeTransferCoordinator {
  Future<NetworkResult<void>> _respond(
    IncomingTransferOffer offer, {
    required bool accept,
  }) async {
    if (_disposed) {
      return LanNativeTransferCoordinator._failure(
        code: NetworkErrorCode.cancelled,
        message: 'Native transfer coordinator is disposed.',
        operation: NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }
    _pendingOffers[offer.transferId] ??= offer;
    final committed = _committedDecisions[offer.transferId];
    if (committed != null) {
      if (committed == accept) return const NetworkSuccess<void>(null);
      return LanNativeTransferCoordinator._failure(
        code: NetworkErrorCode.invalidArgument,
        message: 'Incoming transfer already has a different decision.',
        operation: NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }

    final inFlight = _decisionOperations[offer.transferId];
    if (inFlight != null) {
      if (inFlight.accept == accept) {
        return inFlight.future;
      }
      return LanNativeTransferCoordinator._failure(
        code: NetworkErrorCode.invalidState,
        message: 'A conflicting decision is currently in flight.',
        operation: NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }

    final completer = Completer<NetworkResult<void>>();
    _decisionOperations[offer.transferId] = _IncomingDecisionOperation(
      accept: accept,
      future: completer.future,
    );

    try {
      final result = await _executeRespond(offer, accept: accept);
      if (identical(
        _decisionOperations[offer.transferId]?.future,
        completer.future,
      )) {
        _decisionOperations.remove(offer.transferId);
      }
      completer.complete(result);
      return result;
    } catch (error) {
      final failure = NetworkFailure<void>(
        lanNetworkError(
          error,
          operation: NetworkOperation.respondToIncoming,
          peerId: offer.peerId,
        ),
      );
      if (identical(
        _decisionOperations[offer.transferId]?.future,
        completer.future,
      )) {
        _decisionOperations.remove(offer.transferId);
      }
      completer.complete(failure);
      return failure;
    } finally {
      if (identical(
        _decisionOperations[offer.transferId]?.future,
        completer.future,
      )) {
        _decisionOperations.remove(offer.transferId);
      }
    }
  }

  Future<NetworkResult<void>> _executeRespond(
    IncomingTransferOffer offer, {
    required bool accept,
  }) async {
    final policyResult = await _policyPort.getPeerPolicy(offer.peerId);
    if (policyResult is NetworkFailure<LanPeerPolicySnapshot>) {
      final nativeRes = await _respondNative(offer, accept: false);
      if (nativeRes is NetworkSuccess<void>) {
        _committedDecisions[offer.transferId] = false;
        _pendingOffers.remove(offer.transferId);
        _offerTimers.remove(offer.transferId)?.cancel();
      }
      return NetworkFailure<void>(policyResult.error);
    }
    final policy = (policyResult as NetworkSuccess<LanPeerPolicySnapshot>).data;
    if (!policy.isTrusted ||
        !isIncomingRouteAuthorized(
          policy.trust!.authorization,
          offer.routeType,
        )) {
      final nativeRes = await _respondNative(offer, accept: false);
      if (nativeRes is NetworkSuccess<void>) {
        _committedDecisions[offer.transferId] = false;
        _pendingOffers.remove(offer.transferId);
        _offerTimers.remove(offer.transferId)?.cancel();
      }
      return LanNativeTransferCoordinator._failure(
        code: NetworkErrorCode.authenticationFailed,
        message:
            'Incoming transfer peer is not trusted or route is unauthorized.',
        operation: NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }

    if (accept) {
      final hasSpace = await _storageService.hasSufficientSpace(offer.fileSize);
      if (!hasSpace) {
        final nativeRes = await _respondNative(offer, accept: false);
        if (nativeRes is NetworkSuccess<void>) {
          _committedDecisions[offer.transferId] = false;
          _pendingOffers.remove(offer.transferId);
          _offerTimers.remove(offer.transferId)?.cancel();
        }
        return LanNativeTransferCoordinator._failure(
          code: NetworkErrorCode.resourceLimit,
          message: 'Insufficient storage space for incoming transfer.',
          operation: NetworkOperation.respondToIncoming,
          peerId: offer.peerId,
        );
      }
    }

    final nativeResult = await _respondNative(offer, accept: accept);
    if (nativeResult is NetworkSuccess<void>) {
      _committedDecisions[offer.transferId] = accept;
      _pendingOffers.remove(offer.transferId);
      _offerTimers.remove(offer.transferId)?.cancel();
    }
    return nativeResult;
  }

  Future<NetworkResult<void>> _respondNative(
    IncomingTransferOffer offer, {
    required bool accept,
  }) async {
    try {
      return await _networkFacade.respondToIncomingTransfer(
        transferId: offer.transferId,
        accept: accept,
      );
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.respondToIncoming,
          peerId: offer.peerId,
        ),
      );
    }
  }

  Future<void> _expireOffer(IncomingTransferOffer offer) async {
    if (_disposed) return;
    final inFlight = _decisionOperations[offer.transferId];
    if (inFlight != null) {
      try {
        await inFlight.future;
      } catch (_) {}
    }
    if (!_disposed &&
        !_committedDecisions.containsKey(offer.transferId) &&
        _pendingOffers.containsKey(offer.transferId)) {
      await reject(offer);
    }
  }
}
