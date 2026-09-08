part of '../ssh_mobile_network_native.dart';

/// Media-owner operations kept separate from the general protocol runtime
/// facade so each production file retains one responsibility.
extension NativeNetworkRuntimeMedia on NativeNetworkRuntime {
  /// Requests one native-only media endpoint for the active realtime session.
  ///
  /// Dart receives only the opaque lease ID. The native capture, encoder,
  /// decoder, RTP path, and renderer retain all high-frequency media data.
  NativeRealtimeMediaEndpointCreateResult createRealtimeMediaEndpoint({
    required String realtimeId,
    required String peerId,
    required NativeRealtimeMediaDirection direction,
    required int generation,
  }) {
    if (_handle == nullptr || _lifecycle != _NativeRuntimeLifecycle.running) {
      return const NativeRealtimeMediaEndpointCreateResult(
        status: NativeOperationStatus.stopped,
      );
    }
    if (!_isValidRealtimeMediaId(realtimeId) ||
        !_isValidRealtimeMediaPeerId(peerId) ||
        generation <= 0) {
      return const NativeRealtimeMediaEndpointCreateResult(
        status: NativeOperationStatus.invalidArgument,
      );
    }

    final realtimeIdBytes = utf8.encode(realtimeId);
    final peerIdBytes = utf8.encode(peerId);
    final realtimeIdPointer = realtimeId.toNativeUtf8();
    final peerIdPointer = peerId.toNativeUtf8();
    final outEndpoint = calloc<Uint64>();
    try {
      final status = NativeOperationStatus.fromRealtimeMediaCode(
        _sshNetRealtimeMediaEndpointCreateNative(
          _handle,
          realtimeIdPointer.cast<Uint8>(),
          realtimeIdBytes.length,
          peerIdPointer.cast<Uint8>(),
          peerIdBytes.length,
          generation,
          direction.nativeValue,
          outEndpoint,
        ),
      );
      if (!status.isSuccess || outEndpoint.value == 0) {
        return NativeRealtimeMediaEndpointCreateResult(status: status);
      }
      return NativeRealtimeMediaEndpointCreateResult(
        status: status,
        endpointId: NativeRealtimeMediaEndpointId(outEndpoint.value),
      );
    } finally {
      calloc.free(realtimeIdPointer);
      calloc.free(peerIdPointer);
      calloc.free(outEndpoint);
    }
  }

  /// Releases a media endpoint ID. Releasing after native shutdown is a safe
  /// no-op because shutdown invalidates the whole endpoint generation first.
  NativeOperationStatus releaseRealtimeMediaEndpoint(
    NativeRealtimeMediaEndpointId endpointId,
  ) {
    if (_handle == nullptr || _lifecycle != _NativeRuntimeLifecycle.running) {
      return NativeOperationStatus.success;
    }
    return NativeOperationStatus.fromRealtimeMediaCode(
      _sshNetRealtimeMediaEndpointReleaseNative(_handle, endpointId.value),
    );
  }

  /// Registers an existing endpoint with the native platform owner. The
  /// returned ID is safe to pass to a platform plugin; it is not a pointer and
  /// does not expose media bytes to Dart.
  NativeRealtimeMediaOwnerOpenResult openRealtimeMediaOwner({
    required NativeRealtimeMediaEndpointId endpointId,
    required String realtimeId,
    required String peerId,
    required int generation,
    required NativeRealtimeMediaDirection direction,
  }) {
    if (_handle == nullptr || _lifecycle != _NativeRuntimeLifecycle.running) {
      return const NativeRealtimeMediaOwnerOpenResult(
        status: NativeOperationStatus.stopped,
      );
    }
    if (endpointId.value <= 0 ||
        !_isValidRealtimeMediaId(realtimeId) ||
        !_isValidRealtimeMediaPeerId(peerId) ||
        generation <= 0) {
      return const NativeRealtimeMediaOwnerOpenResult(
        status: NativeOperationStatus.invalidArgument,
      );
    }

    final realtimeIdPointer = realtimeId.toNativeUtf8();
    final peerIdPointer = peerId.toNativeUtf8();
    final outOwner = calloc<Uint64>();
    try {
      final status = NativeOperationStatus.fromRealtimeMediaCode(
        _sshNetRealtimeMediaOwnerOpenNative(
          _handle,
          endpointId.value,
          realtimeIdPointer.cast<Uint8>(),
          utf8.encode(realtimeId).length,
          peerIdPointer.cast<Uint8>(),
          utf8.encode(peerId).length,
          generation,
          direction.nativeValue,
          outOwner,
        ),
      );
      if (!status.isSuccess || outOwner.value == 0) {
        return NativeRealtimeMediaOwnerOpenResult(status: status);
      }
      return NativeRealtimeMediaOwnerOpenResult(
        status: status,
        token: NativeRealtimeMediaOwnerToken(outOwner.value),
      );
    } finally {
      calloc.free(realtimeIdPointer);
      calloc.free(peerIdPointer);
      calloc.free(outOwner);
    }
  }

  /// Closes a native platform owner. Repeating a close is idempotent.
  NativeOperationStatus closeRealtimeMediaOwner(
    NativeRealtimeMediaOwnerToken token,
  ) {
    if (_handle == nullptr || _lifecycle != _NativeRuntimeLifecycle.running) {
      return NativeOperationStatus.success;
    }
    return NativeOperationStatus.fromRealtimeMediaCode(
      _sshNetRealtimeMediaOwnerCloseNative(token.value),
    );
  }
}
