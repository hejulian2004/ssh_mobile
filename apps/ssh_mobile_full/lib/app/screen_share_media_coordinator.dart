import 'dart:async';

import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:realtime_media_android/realtime_media_android.dart';
import 'package:realtime_media_windows/realtime_media_windows.dart';

import 'realtime_media_feature_adapters.dart';
import 'screen_share_feature_adapters.dart';

typedef AppScreenShareOperationGuard = bool Function();

/// Result of the App Shell's capture-preparation lifecycle.
enum AppScreenSharePreparationResult {
  /// The caller owns the prepared platform lease until attach or abandon.
  acquired,

  /// The platform owner invalidated and cleaned the preparation already.
  invalidated,
}

/// App-owned platform capability boundary for one screen-share route.
///
/// It carries only source metadata and permission/lifecycle results. Platform
/// adapters retain capture, codec, surface and native-owner ownership.
abstract interface class AppScreenSharePlatformCapabilities {
  factory AppScreenSharePlatformCapabilities({
    required Future<AppScreenSharePreparationResult> Function(
      AppScreenShareOperationGuard guard,
    ) prepareCapture,
    required Future<void> Function() abandonCapturePreparation,
    required Future<List<ScreenCaptureSource>> Function() listCaptureSources,
  }) = _AppScreenSharePlatformCapabilities;

  Future<AppScreenSharePreparationResult> prepareCapture(
    AppScreenShareOperationGuard guard,
  );

  Future<void> abandonCapturePreparation();

  Future<List<ScreenCaptureSource>> listCaptureSources();
}

final class _AppScreenSharePlatformCapabilities
    implements AppScreenSharePlatformCapabilities {
  const _AppScreenSharePlatformCapabilities({
    required this._prepareCapture,
    required this._abandonCapturePreparation,
    required this._listCaptureSources,
  });

  final Future<AppScreenSharePreparationResult> Function(
    AppScreenShareOperationGuard guard,
  ) _prepareCapture;
  final Future<void> Function() _abandonCapturePreparation;
  final Future<List<ScreenCaptureSource>> Function() _listCaptureSources;

  @override
  Future<AppScreenSharePreparationResult> prepareCapture(
    AppScreenShareOperationGuard guard,
  ) => _prepareCapture(guard);

  @override
  Future<void> abandonCapturePreparation() => _abandonCapturePreparation();

  @override
  Future<List<ScreenCaptureSource>> listCaptureSources() =>
      _listCaptureSources();
}

/// Route-scoped owner that connects Feature consent to opaque media leases.
final class AppScreenShareMediaCoordinator {
  AppScreenShareMediaCoordinator({
    required this.session,
    required this.resources,
    required this.capabilities,
    this.source,
  }) {
    _port = AppScreenShareMediaPort(
      events: _events.stream,
      onStartCapture: _startCaptureTracked,
      onStartViewer: _startViewerTracked,
      onStop: _stop,
    );
  }

  final RealtimeSession session;
  final AppRealtimeMediaResources resources;
  final AppScreenSharePlatformCapabilities capabilities;
  final ScreenCaptureSource? source;
  final StreamController<ScreenShareMediaEvent> _events =
      StreamController<ScreenShareMediaEvent>.broadcast();
  late final AppScreenShareMediaPort _port;
  RealtimeMediaSessionController? _mediaSession;
  RealtimeMediaEndpoint? _endpoint;
  String? _operationId;
  Future<void>? _activeMediaOperation;
  bool _prepared = false;
  bool _disposed = false;
  int _operationEpoch = 0;

  AppScreenShareMediaPort get port => _port;

  /// Verifies the local native generation and source metadata.
  /// Permission, source enumeration, endpoint creation, and capture remain
  /// gated by remote consent and media readiness.
  Future<void> prepare({required bool capture}) async {
    _ensureUsable();
    final token = session.mediaToken;
    if (token == null) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native Realtime generation is not available.',
      );
    }
    _mediaSession ??= resources.sessionFactory.create(session);
    if (capture && source == null) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.invalidArgument,
        'A capture source is required for screen sharing.',
      );
    }
    _prepared = true;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    ++_operationEpoch;
    _disposed = true;
    final activeOperation = _activeMediaOperation;
    if (activeOperation != null) {
      try {
        await activeOperation;
      } catch (_) {
        // The stale operation has already attempted compensating cleanup.
      }
    }
    try {
      await _releaseCurrentEndpoint();
    } catch (_) {
      // The session controller keeps a retryable lease when native cleanup
      // fails; route disposal must still cancel its subscriptions.
    }
    try {
      await _mediaSession?.dispose();
    } catch (_) {
      // Keep route disposal deterministic. The session controller retains a
      // retryable lease internally; no stale operation is allowed to proceed.
    }
    await _events.close();
  }

  Future<void> _startCaptureTracked({
    required String operationId,
    required String realtimeId,
    required int generation,
  }) async {
    _validateOperation(
      operationId: operationId,
      realtimeId: realtimeId,
      generation: generation,
    );
    final epoch = ++_operationEpoch;
    await _trackMediaOperation(
      () => _startCapture(
        operationId: operationId,
        realtimeId: realtimeId,
        generation: generation,
        epoch: epoch,
      ),
    );
  }

  Future<void> _startViewerTracked({
    required String operationId,
    required String realtimeId,
    required int generation,
  }) async {
    _validateOperation(
      operationId: operationId,
      realtimeId: realtimeId,
      generation: generation,
    );
    final epoch = ++_operationEpoch;
    await _trackMediaOperation(
      () => _startViewer(
        operationId: operationId,
        realtimeId: realtimeId,
        generation: generation,
        epoch: epoch,
      ),
    );
  }

  Future<void> _trackMediaOperation(Future<void> Function() operation) {
    final predecessor = _activeMediaOperation;
    late final Future<void> tracked;
    tracked = _runTrackedMediaOperation(() async {
      if (predecessor != null) await predecessor;
      await operation();
    }, () {
      if (identical(_activeMediaOperation, tracked)) {
        _activeMediaOperation = null;
      }
    });
    _activeMediaOperation = tracked;
    return tracked;
  }

  Future<void> _runTrackedMediaOperation(
    Future<void> Function() operation,
    void Function() onComplete,
  ) async {
    try {
      await operation();
    } finally {
      onComplete();
    }
  }

  Future<void> _startCapture({
    required String operationId,
    required String realtimeId,
    required int generation,
    required int epoch,
  }) async {
    _validateOperation(
      operationId: operationId,
      realtimeId: realtimeId,
      generation: generation,
    );
    _ensureCurrentOperation(epoch, operationId, realtimeId, generation);
    final selectedSource = source;
    if (!_prepared || selectedSource == null) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Screen-share capture is not ready.',
      );
    }
    if (_endpoint != null) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'Screen-share media is already active.',
      );
    }
    final mediaSession = _mediaSession!;
    var ownsPreparation = false;
    var attachCompleted = false;
    try {
      final preparation = await capabilities.prepareCapture(
        () => _isCurrentOperation(epoch, operationId, realtimeId, generation),
      );
      if (preparation == AppScreenSharePreparationResult.invalidated) {
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.staleEndpoint,
          'Screen-share capture preparation became stale.',
        );
      }
      ownsPreparation = true;
      _ensureCurrentOperation(epoch, operationId, realtimeId, generation);
      final sources = await capabilities.listCaptureSources();
      _ensureCurrentOperation(epoch, operationId, realtimeId, generation);
      if (!sources.any((item) => item.id.value == selectedSource.id.value)) {
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.driverUnavailable,
          'The selected capture source is no longer available.',
        );
      }
      final endpoint = await mediaSession.start(RealtimeMediaDirection.send);
      if (!_isCurrentOperation(epoch, operationId, realtimeId, generation)) {
        await _releaseEndpointIfNeeded(mediaSession, endpoint);
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.staleEndpoint,
          'Screen-share capture start became stale.',
        );
      }
      _endpoint = endpoint;
      _operationId = operationId;
      try {
        await mediaSession.attachCaptureSource(endpoint, selectedSource);
        attachCompleted = true;
        ownsPreparation = false;
        _ensureCurrentOperation(epoch, operationId, realtimeId, generation);
      } catch (_) {
        await _releaseCurrentEndpoint();
        rethrow;
      }
    } finally {
      if (ownsPreparation && !attachCompleted) {
        await capabilities.abandonCapturePreparation();
      }
    }
  }

  Future<void> _startViewer({
    required String operationId,
    required String realtimeId,
    required int generation,
    required int epoch,
  }) async {
    _validateOperation(
      operationId: operationId,
      realtimeId: realtimeId,
      generation: generation,
    );
    _ensureCurrentOperation(epoch, operationId, realtimeId, generation);
    if (!_prepared) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Screen-share viewer is not ready.',
      );
    }
    if (_endpoint != null) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'Screen-share media is already active.',
      );
    }
    final mediaSession = _mediaSession!;
    final endpoint = await mediaSession.start(RealtimeMediaDirection.receive);
    if (!_isCurrentOperation(epoch, operationId, realtimeId, generation)) {
      await _releaseEndpointIfNeeded(mediaSession, endpoint);
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleEndpoint,
        'Screen-share viewer start became stale.',
      );
    }
    _endpoint = endpoint;
    _operationId = operationId;
    try {
      await mediaSession.attachRemoteVideoSurface(endpoint);
      _ensureCurrentOperation(epoch, operationId, realtimeId, generation);
    } catch (_) {
      await _releaseCurrentEndpoint();
      rethrow;
    }
  }

  Future<void> _stop({
    required String operationId,
    required String realtimeId,
    required int generation,
  }) async {
    _validateOperation(
      operationId: operationId,
      realtimeId: realtimeId,
      generation: generation,
    );
    if (_operationId != null && _operationId != operationId) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleEndpoint,
        'Screen-share operation does not own this media endpoint.',
      );
    }
    ++_operationEpoch;
    final activeOperation = _activeMediaOperation;
    if (activeOperation != null) {
      try {
        await activeOperation;
      } catch (_) {
        // Preserve the original stop operation while the stale start cleans
        // up its own endpoint lease.
      }
    }
    await _releaseCurrentEndpoint();
    _operationId = null;
  }

  Future<void> _releaseCurrentEndpoint() async {
    final endpoint = _endpoint;
    if (endpoint == null) return;
    try {
      await _mediaSession!.release(endpoint);
      _endpoint = null;
    } catch (_) {
      // Keep the endpoint reference so the controller can retry the native
      // cleanup. RealtimeMediaSessionController retains retryable leases.
      rethrow;
    }
  }

  Future<void> _releaseEndpointIfNeeded(
    RealtimeMediaSessionController mediaSession,
    RealtimeMediaEndpoint endpoint,
  ) async {
    try {
      await mediaSession.release(endpoint);
    } on Object {
      // Keep the session controller's retryable lease; the stale operation
      // must still fail closed and never attach a later callback.
    }
  }

  bool _isCurrentOperation(
    int epoch,
    String operationId,
    String realtimeId,
    int generation,
  ) {
    final token = session.mediaToken;
    return !_disposed &&
        _operationEpoch == epoch &&
        (_operationId == null || _operationId == operationId) &&
        token?.realtimeId == realtimeId &&
        token?.generation == generation;
  }

  void _ensureCurrentOperation(
    int epoch,
    String operationId,
    String realtimeId,
    int generation,
  ) {
    if (!_isCurrentOperation(epoch, operationId, realtimeId, generation)) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleEndpoint,
        'Screen-share media operation is stale.',
      );
    }
  }

  void _validateOperation({
    required String operationId,
    required String realtimeId,
    required int generation,
  }) {
    _ensureUsable();
    final token = session.mediaToken;
    if (token == null ||
        token.realtimeId != realtimeId ||
        token.generation != generation) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleGeneration,
        'Screen-share operation belongs to a stale Realtime generation.',
      );
    }
    if (_operationId != null && _operationId != operationId) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleEndpoint,
        'Screen-share operation identity does not match the active lease.',
      );
    }
  }

  void _ensureUsable() {
    if (_disposed) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.sessionReleased,
        'Screen-share media coordinator is released.',
      );
    }
  }
}

AppScreenSharePlatformCapabilities appScreenSharePlatformCapabilitiesFor(
  RealtimeMediaBackend backend,
) {
  if (backend is WindowsRealtimeMediaBackend) {
    final windows = backend;
    return AppScreenSharePlatformCapabilities(
      prepareCapture: (_) async => AppScreenSharePreparationResult.acquired,
      abandonCapturePreparation: () async {},
      listCaptureSources: windows.listCaptureSources,
    );
  }
  if (backend is AndroidRealtimeMediaBackend) {
    final android = backend;
    return AppScreenSharePlatformCapabilities(
      prepareCapture: (guard) async {
        final result = await android.requestProjection(isCurrent: guard);
        return switch (result) {
          AndroidProjectionPreparationResult.acquired =>
            AppScreenSharePreparationResult.acquired,
          AndroidProjectionPreparationResult.invalidated =>
            AppScreenSharePreparationResult.invalidated,
        };
      },
      abandonCapturePreparation: android.abandonProjectionGrant,
      listCaptureSources: android.listCaptureSources,
    );
  }
  throw const RealtimeMediaException(
    RealtimeMediaErrorCode.driverUnavailable,
    'Screen sharing is unavailable on this platform.',
  );
}
