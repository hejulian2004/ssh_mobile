import 'package:realtime_media/realtime_media.dart';

import 'android_realtime_media_platform.dart';

/// Composes the existing endpoint lease with Android native media ownership.
///
/// The endpoint backend remains the owner of the NetworkRuntime lease. Android
/// owns only projection, codecs, surfaces, and its generation-bound owner
/// token; release tears those down before final endpoint release.
final class AndroidRealtimeMediaBackend
    implements
        RealtimeMediaBackend,
        RealtimeMediaKeyframeBackend,
        RealtimeMediaAdaptationBackend {
  AndroidRealtimeMediaBackend({
    required this.endpointBackend,
    required this.platform,
  });

  final RealtimeMediaBackend endpointBackend;
  final AndroidRealtimeMediaPlatform platform;
  final Map<RealtimeMediaEndpointId, RealtimeMediaNativeOwnerToken> _owners =
      <RealtimeMediaEndpointId, RealtimeMediaNativeOwnerToken>{};
  final Map<RealtimeMediaEndpointId, RealtimeMediaEndpointIdentity>
  _ownerIdentities = <RealtimeMediaEndpointId, RealtimeMediaEndpointIdentity>{};

  Future<void> requestProjection() => platform.requestProjection();

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
      await _releaseEndpoint(endpointId, identity);
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Android media requires the native owner capability.',
      );
    }
    try {
      final token = await ownerBackend.openNativeOwner(
        endpointId: endpointId,
        identity: identity,
      );
      if (_owners.containsKey(endpointId)) {
        await ownerBackend.closeNativeOwner(token: token, identity: identity);
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.duplicateEndpoint,
          'Android media already owns this endpoint ID.',
        );
      }
      _owners[endpointId] = token;
      _ownerIdentities[endpointId] = identity;
      return endpointId;
    } catch (_) {
      await _releaseEndpoint(endpointId, identity);
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
    await platform.detach(
      endpointId: endpointId,
      identity: identity,
      ownerToken: _ownerFor(endpointId, identity),
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
      await endpointBackend.release(endpointId: endpointId, identity: identity);
      return;
    }
    final ownerIdentity = _ownerIdentities[endpointId];
    if (ownerIdentity == null || !ownerIdentity.matches(identity)) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleEndpoint,
        'The Android media endpoint belongs to another generation.',
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
        'The Android media endpoint has no active native owner.',
      );
    }
    if (!ownerIdentity.matches(identity)) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleEndpoint,
        'The Android media endpoint belongs to another generation.',
      );
    }
    return token;
  }

  Future<void> _releaseEndpoint(
    RealtimeMediaEndpointId endpointId,
    RealtimeMediaEndpointIdentity identity,
  ) async {
    try {
      await endpointBackend.release(endpointId: endpointId, identity: identity);
    } catch (_) {
      // The endpoint backend owns retry/failure reporting. Preserve the
      // original owner-capability error at this layer.
    }
  }
}
