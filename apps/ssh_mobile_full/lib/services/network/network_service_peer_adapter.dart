part of 'network_service.dart';

/// Peer 命令适配器：只负责 peer registration 与连接状态终态等待。
final class _NetworkPeerAdapter {
  _NetworkPeerAdapter({
    required this.codec,
    required this.commands,
    required this.eventHub,
    required this.projection,
    this.traceRegistry,
  });

  final NetworkProtocolV2Codec codec;
  final _NetworkCommandCoordinator commands;
  final _NetworkEventHub eventHub;
  final _NetworkStateProjection projection;
  final TelemetryTraceRegistry? traceRegistry;

  Future<NetworkResult<void>> upsertPeer(PeerConfig peer) => commands.submit(
    codec.upsertPeerCommand(commandId: const Uuid().v4(), peer: peer),
    operation: NetworkOperation.upsertPeer,
  );

  Future<NetworkResult<void>> removePeer(String peerId) {
    commands.ensureUsable();
    if (peerId.trim().isEmpty) {
      return Future.value(
        _networkFailure(
          const NetworkError(
            code: NetworkErrorCode.invalidArgument,
            message: 'peer_id is required',
            operation: NetworkOperation.removePeer,
          ),
        ),
      );
    }
    return commands.submit(
      codec.removePeerCommand(commandId: const Uuid().v4(), peerId: peerId),
      operation: NetworkOperation.removePeer,
    );
  }

  Future<NetworkResult<void>> connect(
    String peerId, {
    required CommunicationClass communicationClass,
  }) async {
    commands.ensureUsable();
    if (peerId.trim().isEmpty) {
      return _networkFailure(
        const NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'peer_id is required',
          operation: NetworkOperation.connect,
        ),
      );
    }
    if (projection.hasRoute(peerId)) {
      final traceId = traceRegistry?.traceForPeer(peerId);
      if (traceId != null) {
        traceRegistry?.completePeer(peerId, traceId: traceId);
      }
      return const NetworkSuccess<void>(null);
    }

    final terminalState = Completer<PeerStateChanged>();
    final traceId = traceRegistry?.traceForPeer(peerId);
    var terminalObserved = false;
    final subscription = eventHub.stream
        .where(
          (event) =>
              event is PeerStateChanged &&
              event.peerId == peerId &&
              (event.state == PeerConnectionState.connected ||
                  event.state == PeerConnectionState.failed ||
                  event.state == PeerConnectionState.disconnected),
        )
        .cast<PeerStateChanged>()
        .listen((event) {
          if (!terminalState.isCompleted) terminalState.complete(event);
        });
    final result = await commands.submit(
      codec.connectPeerCommand(
        commandId: const Uuid().v4(),
        peerId: peerId,
        communicationClass: communicationClass,
      ),
      operation: NetworkOperation.connect,
      timeout: const Duration(seconds: 12),
      peerId: peerId,
    );
    if (result is NetworkFailure<void>) {
      // Native may publish the terminal peer failure immediately before the
      // command rejection. Preserve that typed authentication/route error;
      // otherwise the command layer's generic rejection hides the reason the
      // user needs to fix pairing.
      PeerStateChanged? terminalEvent;
      try {
        terminalEvent = await terminalState.future.timeout(
          const Duration(milliseconds: 250),
        );
      } on TimeoutException {
        // No terminal peer event: retain the command-level failure below.
      }
      await subscription.cancel();
      traceRegistry?.releasePeerTrace(peerId: peerId, traceId: traceId);
      final terminalError = terminalEvent?.error;
      if (terminalError != null) return _networkFailure(terminalError);
      return result;
    }
    PeerStateChanged? terminalEvent;
    try {
      final event = await terminalState.future.timeout(
        const Duration(seconds: 12),
      );
      terminalEvent = event;
      terminalObserved = true;
      if (event.state == PeerConnectionState.connected) {
        return const NetworkSuccess<void>(null);
      }
      return _networkFailure(
        event.error ??
            NetworkError(
              code: NetworkErrorCode.noRoute,
              message: 'peer connection failed',
              operation: NetworkOperation.connect,
              peerId: peerId,
            ),
      );
    } on TimeoutException {
      return _networkFailure(
        NetworkError(
          code: NetworkErrorCode.timeout,
          message: 'peer connection state timed out',
          operation: NetworkOperation.connect,
          peerId: peerId,
        ),
      );
    } finally {
      await subscription.cancel();
      if (traceId != null &&
          terminalEvent?.state == PeerConnectionState.connected) {
        // The bridge also observes this event, but it must not be the only
        // cleanup path: tests or another consumer may use the facade without
        // installing telemetry. The exact trace guard preserves a newer
        // same-peer operation.
        traceRegistry?.completePeer(peerId, traceId: traceId);
      } else if (traceId != null && !terminalObserved) {
        traceRegistry?.releasePeerTrace(peerId: peerId, traceId: traceId);
      }
    }
  }

  Future<NetworkResult<void>> disconnect(String peerId) {
    commands.ensureUsable();
    if (peerId.trim().isEmpty) {
      return Future.value(
        _networkFailure(
          const NetworkError(
            code: NetworkErrorCode.invalidArgument,
            message: 'peer_id is required',
            operation: NetworkOperation.disconnect,
          ),
        ),
      );
    }
    return commands.submit(
      codec.disconnectPeerCommand(commandId: const Uuid().v4(), peerId: peerId),
      operation: NetworkOperation.disconnect,
    );
  }
}
