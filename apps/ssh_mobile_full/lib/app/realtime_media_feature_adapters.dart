import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

/// App-owned bridge from the opaque native media endpoint ABI to the
/// `realtime_media` lifecycle contract.
///
/// The native runtime remains the resource owner. This adapter only borrows a
/// Realtime gateway and translates the typed ABI status into lifecycle errors;
/// encoded frames, capture buffers, and renderer handles never enter Dart.
final class AppRealtimeMediaBackend
    implements RealtimeMediaBackend, RealtimeMediaNativeOwnerBackend {
  // The public named parameter is part of the adapter API; using an
  // initializing formal here would expose the private field name.
  AppRealtimeMediaBackend({required NetworkRuntime networkRuntime})
    : _networkRuntime = networkRuntime; // ignore: prefer_initializing_formals

  final NetworkRuntime _networkRuntime;
  NetworkRealtimeGateway? _gateway;
  Future<NetworkRealtimeGateway>? _gatewayFuture;

  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity identity,
  ) async {
    final gateway = await _ensureGateway();
    final result = gateway.createMediaEndpoint(
      realtimeId: identity.realtimeId,
      peerId: identity.peerId,
      generation: identity.generation,
      direction: switch (identity.direction) {
        RealtimeMediaDirection.send => NativeRealtimeMediaDirection.send,
        RealtimeMediaDirection.receive => NativeRealtimeMediaDirection.receive,
      },
    );
    if (!result.isSuccess) {
      throw _statusFailure(result.status);
    }
    final endpointId = result.endpointId;
    if (endpointId == null) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native media endpoint creation returned no endpoint ID.',
      );
    }
    return RealtimeMediaEndpointId(endpointId.value.toString());
  }

  @override
  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  }) => throw const RealtimeMediaException(
    RealtimeMediaErrorCode.backendFailure,
    'Platform capture is not part of the Phase 2 native bridge.',
  );

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => throw const RealtimeMediaException(
    RealtimeMediaErrorCode.backendFailure,
    'Platform rendering is not part of the Phase 2 native bridge.',
  );

  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    // Phase 2 has no platform source/surface binding yet, so detach is an
    // idempotent no-op. Endpoint release below remains native-authoritative.
  }

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    final nativeId = _parseEndpointId(endpointId);
    final status = (await _ensureGateway()).releaseMediaEndpoint(nativeId);
    if (!status.isSuccess) throw _statusFailure(status);
  }

  @override
  Future<RealtimeMediaNativeOwnerToken> openNativeOwner({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    final nativeEndpoint = _parseEndpointId(endpointId);
    final result = (await _ensureGateway()).openMediaOwner(
      endpointId: nativeEndpoint,
      realtimeId: identity.realtimeId,
      peerId: identity.peerId,
      generation: identity.generation,
      direction: switch (identity.direction) {
        RealtimeMediaDirection.send => NativeRealtimeMediaDirection.send,
        RealtimeMediaDirection.receive => NativeRealtimeMediaDirection.receive,
      },
    );
    if (!result.isSuccess || result.token == null) {
      throw _statusFailure(result.status);
    }
    return RealtimeMediaNativeOwnerToken(result.token!.value.toString());
  }

  @override
  Future<void> closeNativeOwner({
    required RealtimeMediaNativeOwnerToken token,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    final value = int.tryParse(token.value);
    if (value == null || value <= 0) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.invalidArgument,
        'Native media owner token is invalid.',
      );
    }
    final status = (await _ensureGateway()).closeMediaOwner(
      NativeRealtimeMediaOwnerToken(value),
    );
    if (!status.isSuccess) throw _statusFailure(status);
  }

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => throw const RealtimeMediaException(
    RealtimeMediaErrorCode.backendFailure,
    'Native media statistics are not part of the Phase 2 bridge.',
  );

  Future<NetworkRealtimeGateway> _ensureGateway() {
    final gateway = _gateway;
    if (gateway != null) return Future<NetworkRealtimeGateway>.value(gateway);
    final existing = _gatewayFuture;
    if (existing != null) return existing;
    late final Future<NetworkRealtimeGateway> future;
    future = _networkRuntime.openRealtimeGateway();
    _gatewayFuture = future;
    future.then<void>(
      (opened) {
        if (!identical(_gatewayFuture, future)) return;
        _gatewayFuture = null;
        _gateway = opened;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_gatewayFuture, future)) _gatewayFuture = null;
      },
    );
    return future;
  }

  static NativeRealtimeMediaEndpointId _parseEndpointId(
    RealtimeMediaEndpointId endpointId,
  ) {
    final value = int.tryParse(endpointId.value);
    if (value == null || value <= 0) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.invalidArgument,
        'Media endpoint ID is not a valid native endpoint ID.',
      );
    }
    return NativeRealtimeMediaEndpointId(value);
  }

  static RealtimeMediaException _statusFailure(NativeOperationStatus status) {
    final code = switch (status) {
      NativeOperationStatus.invalidArgument =>
        RealtimeMediaErrorCode.invalidArgument,
      NativeOperationStatus.unknownSession =>
        RealtimeMediaErrorCode.unknownSession,
      NativeOperationStatus.staleGeneration =>
        RealtimeMediaErrorCode.staleGeneration,
      NativeOperationStatus.staleEndpoint =>
        RealtimeMediaErrorCode.staleEndpoint,
      NativeOperationStatus.directionMismatch =>
        RealtimeMediaErrorCode.directionMismatch,
      NativeOperationStatus.duplicateEndpoint =>
        RealtimeMediaErrorCode.duplicateEndpoint,
      NativeOperationStatus.driverUnavailable =>
        RealtimeMediaErrorCode.driverUnavailable,
      NativeOperationStatus.peerMismatch => RealtimeMediaErrorCode.peerMismatch,
      NativeOperationStatus.frameRejected =>
        RealtimeMediaErrorCode.frameRejected,
      NativeOperationStatus.stopped => RealtimeMediaErrorCode.sessionReleased,
      NativeOperationStatus.success => RealtimeMediaErrorCode.backendFailure,
      NativeOperationStatus.failure => RealtimeMediaErrorCode.backendFailure,
    };
    return RealtimeMediaException(
      code,
      'Native media endpoint operation failed with ${status.name}.',
    );
  }
}

/// Builds a media controller only from the native-authoritative token exposed
/// by a production `RealtimeSession`. No signaling revision fallback exists.
final class AppRealtimeMediaSessionFactory {
  const AppRealtimeMediaSessionFactory({required this.backend});

  final RealtimeMediaBackend backend;

  RealtimeMediaSessionController create(RealtimeSession session) {
    final token = session.mediaToken;
    if (token == null) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native Realtime generation is not available yet.',
      );
    }
    return RealtimeMediaSessionController(
      backend: backend,
      realtimeId: token.realtimeId,
      peerId: token.peerId,
      generation: token.generation,
    );
  }
}

/// App-runtime-owned media adapters that share the NetworkRuntime borrow.
final class AppRealtimeMediaResources {
  const AppRealtimeMediaResources({
    required this.backend,
    required this.sessionFactory,
  });

  final RealtimeMediaBackend backend;
  final AppRealtimeMediaSessionFactory sessionFactory;
}
