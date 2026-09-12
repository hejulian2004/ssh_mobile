import 'dart:async';

import 'package:realtime_media/realtime_media.dart';

import 'android_realtime_media_platform.dart';

typedef AndroidProjectionPreparationGuard = bool Function();

/// Result of an Android projection preparation transaction.
enum AndroidProjectionPreparationResult {
  /// The caller owns the granted projection and the shared preparation slot.
  acquired,

  /// The backend invalidated and cleaned the transaction; the caller owns no
  /// projection and must not issue a second abandon call.
  invalidated,
}

final class _ProjectionPreparation {
  final Completer<void> completion = Completer<void>();
  Future<void>? abandonFuture;
}

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
  _ProjectionPreparation? _projectionPreparation;

  /// Starts one serialized projection preparation transaction.
  ///
  /// The guard is checked before opening the platform permission flow and
  /// again after it completes. A false result means the backend already
  /// abandoned any grant and released the shared slot.
  Future<AndroidProjectionPreparationResult> requestProjection({
    AndroidProjectionPreparationGuard? isCurrent,
  }) async {
    final guard = isCurrent ?? _alwaysCurrent;
    while (true) {
      final previous = _projectionPreparation;
      if (previous != null) {
        await previous.completion.future;
        if (!guard()) return AndroidProjectionPreparationResult.invalidated;
        continue;
      }

      // Keep the slot claim synchronous: there must be no await between
      // observing an empty slot and publishing this preparation.
      if (!guard()) return AndroidProjectionPreparationResult.invalidated;
      final preparation = _ProjectionPreparation();
      _projectionPreparation = preparation;
      var callerOwnsPreparation = false;
      var platformRequestStarted = false;
      var cleanupStarted = false;

      Future<void> cleanupGrant() async {
        if (cleanupStarted) return;
        cleanupStarted = true;
        await _abandonPlatformGrant();
      }

      try {
        if (!guard()) return AndroidProjectionPreparationResult.invalidated;
        platformRequestStarted = true;
        await platform.requestProjection();
        if (!guard()) {
          await cleanupGrant();
          return AndroidProjectionPreparationResult.invalidated;
        }
        callerOwnsPreparation = true;
        return AndroidProjectionPreparationResult.acquired;
      } catch (_) {
        if (platformRequestStarted &&
            !callerOwnsPreparation &&
            !cleanupStarted) {
          try {
            await cleanupGrant();
          } catch (_) {
            // Preserve the original preparation failure. The slot is still
            // finalized below, and the platform cleanup is idempotent.
          }
        }
        rethrow;
      } finally {
        if (!callerOwnsPreparation) {
          _finishProjectionPreparation(preparation);
        }
      }
    }
  }

  /// Abandons the caller-owned grant and releases the shared preparation slot.
  /// Repeated calls share the same cleanup future.
  Future<void> abandonProjectionGrant() {
    final preparation = _projectionPreparation;
    if (preparation == null) return Future<void>.value();
    final ongoing = preparation.abandonFuture;
    if (ongoing != null) return ongoing;
    final cleanup = _abandonAndFinish(preparation);
    preparation.abandonFuture = cleanup;
    return cleanup;
  }

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
  }) async {
    final capturedPreparation = _projectionPreparation;
    await platform.startCapture(
      endpointId: endpointId,
      identity: identity,
      source: source,
      ownerToken: _ownerFor(endpointId, identity),
    );
    if (capturedPreparation != null) {
      _finishProjectionPreparation(capturedPreparation);
    }
  }

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

  Future<void> _abandonAndFinish(_ProjectionPreparation preparation) async {
    try {
      await _abandonPlatformGrant();
    } finally {
      _finishProjectionPreparation(preparation);
    }
  }

  Future<void> _abandonPlatformGrant() => platform.abandonProjectionGrant();

  void _finishProjectionPreparation(_ProjectionPreparation preparation) {
    if (!identical(_projectionPreparation, preparation)) return;
    _projectionPreparation = null;
    if (!preparation.completion.isCompleted) preparation.completion.complete();
  }

  static bool _alwaysCurrent() => true;
}
