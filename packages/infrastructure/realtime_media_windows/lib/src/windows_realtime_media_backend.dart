import 'package:realtime_media/realtime_media.dart';

import 'windows_realtime_media_platform.dart';

/// Composes the NetworkRuntime endpoint lease with the Windows media owner.
///
/// Endpoint creation/release remains delegated to the existing native bridge.
/// Windows owns only capture, codec, decoder, surface, and texture resources;
/// therefore release first tears down the platform resource and only then
/// finalizes the endpoint lease.
final class WindowsRealtimeMediaBackend
    implements
        RealtimeMediaBackend,
        RealtimeMediaKeyframeBackend,
        RealtimeMediaAdaptationBackend {
  WindowsRealtimeMediaBackend({
    required this.endpointBackend,
    required this.platform,
  });

  final RealtimeMediaBackend endpointBackend;
  final WindowsRealtimeMediaPlatform platform;
  final Map<RealtimeMediaEndpointId, RealtimeMediaNativeOwnerToken> _owners =
      <RealtimeMediaEndpointId, RealtimeMediaNativeOwnerToken>{};
  final Map<RealtimeMediaEndpointId, RealtimeMediaEndpointIdentity>
  _ownerIdentities = <RealtimeMediaEndpointId, RealtimeMediaEndpointIdentity>{};

  Future<List<ScreenCaptureSource>> listCaptureSources() =>
      platform.listCaptureSources();

  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity identity,
  ) async {
    final endpointId = await endpointBackend.start(identity);
    final ownerBackend = endpointBackend is RealtimeMediaNativeOwnerBackend
        ? endpointBackend as RealtimeMediaNativeOwnerBackend
        : null;
    if (ownerBackend == null) {
      // A Windows endpoint without the runtime-owned native owner port cannot
      // safely bind capture/codec/renderer resources to the endpoint
      // generation. Reclaim the lease immediately instead of allowing a
      // platform call to proceed with a missing token.
      try {
        await endpointBackend.release(
          endpointId: endpointId,
          identity: identity,
        );
      } catch (_) {
        // The capability error is the primary result. The endpoint backend
        // still owns any cleanup retry policy for this failed registration.
      }
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Windows media requires the native owner capability.',
      );
    }
    try {
      final token = await ownerBackend.openNativeOwner(
        endpointId: endpointId,
        identity: identity,
      );
      if (_owners.containsKey(endpointId)) {
        await ownerBackend.closeNativeOwner(token: token, identity: identity);
        await endpointBackend.release(
          endpointId: endpointId,
          identity: identity,
        );
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.duplicateEndpoint,
          'Windows media already owns this endpoint ID.',
        );
      }
      _owners[endpointId] = token;
      _ownerIdentities[endpointId] = identity;
      return endpointId;
    } catch (_) {
      // The endpoint was acquired before the platform owner. Reclaim it
      // immediately so a failed owner registration cannot leak a native lease.
      await endpointBackend.release(endpointId: endpointId, identity: identity);
      rethrow;
    }
  }

  @override
  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  }) => platform.startCapture(
    endpointId: endpointId,
    identity: identity,
    source: source,
    ownerToken: _ownerFor(endpointId, identity),
  );

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => platform.attachRemoteVideoSurface(
    endpointId: endpointId,
    identity: identity,
    ownerToken: _ownerFor(endpointId, identity),
  );

  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    final token = _ownerFor(endpointId, identity);
    await platform.detach(
      endpointId: endpointId,
      identity: identity,
      ownerToken: token,
    );
    await endpointBackend.detach(endpointId: endpointId, identity: identity);
  }

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    final token = _owners[endpointId];
    if (token == null) {
      // A completed backend release is idempotent. The platform owner has
      // already been closed, so only repeat the native endpoint release.
      await endpointBackend.release(endpointId: endpointId, identity: identity);
      return;
    }
    final ownerIdentity = _ownerIdentities[endpointId];
    if (ownerIdentity == null || !ownerIdentity.matches(identity)) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleEndpoint,
        'The Windows media endpoint belongs to another generation.',
      );
    }
    await platform.release(
      endpointId: endpointId,
      identity: identity,
      ownerToken: token,
    );
    final ownerBackend = endpointBackend is RealtimeMediaNativeOwnerBackend
        ? endpointBackend as RealtimeMediaNativeOwnerBackend
        : null;
    if (ownerBackend != null) {
      await ownerBackend.closeNativeOwner(token: token, identity: identity);
    }
    await endpointBackend.release(endpointId: endpointId, identity: identity);
    // Retain the token until the endpoint lease itself is finalized. If
    // endpoint cleanup fails after owner close, a retry must still pass the
    // same generation-bound token through platform teardown.
    _owners.remove(endpointId);
    _ownerIdentities.remove(endpointId);
  }

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => platform.readStats(
    endpointId: endpointId,
    identity: identity,
    ownerToken: _ownerFor(endpointId, identity),
  );

  @override
  Future<void> requestKeyframe({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => platform.requestKeyframe(
    endpointId: endpointId,
    identity: identity,
    ownerToken: _ownerFor(endpointId, identity),
  );

  @override
  Future<void> resetDecoder({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => platform.resetDecoder(
    endpointId: endpointId,
    identity: identity,
    ownerToken: _ownerFor(endpointId, identity),
  );

  @override
  Future<void> applyAdaptation({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required RealtimeMediaAdaptationDecision decision,
  }) => platform.applyAdaptation(
    endpointId: endpointId,
    identity: identity,
    decision: decision,
    ownerToken: _ownerFor(endpointId, identity),
  );

  RealtimeMediaNativeOwnerToken _ownerFor(
    RealtimeMediaEndpointId endpointId,
    RealtimeMediaEndpointIdentity identity,
  ) {
    final token = _owners[endpointId];
    final ownerIdentity = _ownerIdentities[endpointId];
    if (token == null || ownerIdentity == null) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleEndpoint,
        'The Windows media endpoint has no active native owner.',
      );
    }
    if (!ownerIdentity.matches(identity)) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleEndpoint,
        'The Windows media endpoint belongs to another generation.',
      );
    }
    return token;
  }
}
