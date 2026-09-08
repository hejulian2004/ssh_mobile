import 'package:flutter/services.dart';
import 'package:realtime_media/realtime_media.dart';

import 'windows_realtime_media_platform.dart';

/// Windows method-channel adapter for the native platform owner.
///
/// The native plugin is responsible for Windows Graphics Capture, Media
/// Foundation H.264, native decoding, and Flutter texture registration. The
/// method channel carries only bounded identifiers, lifecycle state, and
/// payload-free statistics.
final class MethodChannelWindowsRealtimeMediaPlatform
    implements WindowsRealtimeMediaPlatform {
  const MethodChannelWindowsRealtimeMediaPlatform({
    this._channel = const MethodChannel(_channelName),
  });

  static const _channelName = 'ssh_mobile/realtime_media/windows';

  final MethodChannel _channel;

  @override
  Future<List<ScreenCaptureSource>> listCaptureSources() async {
    final result = await _invoke<List<Object?>>('listSources');
    return result
        .map(_decodeSource)
        .whereType<ScreenCaptureSource>()
        .toList(growable: false);
  }

  @override
  Future<void> startCapture({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {
    await _invoke<void>('startCapture', <String, Object?>{
      'endpoint_id': endpointId.value,
      'realtime_id': identity.realtimeId,
      'peer_id': identity.peerId,
      'generation': identity.generation,
      'direction': identity.direction.name,
      'source_id': source.id.value,
      'source_kind': source.kind.name,
      'owner_token': ownerToken?.value,
    });
  }

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {
    final result = await _invoke<Map<Object?, Object?>>(
      'attachRemoteVideoSurface',
      <String, Object?>{
        'endpoint_id': endpointId.value,
        'realtime_id': identity.realtimeId,
        'peer_id': identity.peerId,
        'generation': identity.generation,
        'direction': identity.direction.name,
        'owner_token': ownerToken?.value,
      },
    );
    final surfaceId = result['surface_id'];
    if (surfaceId is! String || surfaceId.trim().isEmpty) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Windows renderer returned no opaque surface ID.',
      );
    }
    try {
      return RemoteVideoSurface(
        id: RemoteVideoSurfaceId(surfaceId),
        endpointId: endpointId,
        identity: identity,
      );
    } on ArgumentError {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Windows renderer returned an invalid opaque surface ID.',
      );
    }
  }

  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) => _invoke<void>(
    'detach',
    _identityArguments(endpointId, identity, ownerToken),
  );

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) => _invoke<void>(
    'release',
    _identityArguments(endpointId, identity, ownerToken),
  );

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  }) async {
    final result = await _invoke<Map<Object?, Object?>>(
      'readStats',
      _identityArguments(endpointId, identity, ownerToken),
    );
    return RealtimeMediaStats(
      width: _nonNegativeInt(result['width']),
      height: _nonNegativeInt(result['height']),
      framesCaptured: _nonNegativeInt(result['frames_captured']),
      framesSent: _nonNegativeInt(result['frames_sent']),
      framesDropped: _nonNegativeInt(result['frames_dropped']),
      framesDecoded: _nonNegativeInt(result['frames_decoded']),
      framesRendered: _nonNegativeInt(result['frames_rendered']),
      packetsSent: _nonNegativeInt(result['packets_sent']),
      packetsReceived: _nonNegativeInt(result['packets_received']),
      packetsLost: _nonNegativeInt(result['packets_lost']),
      framesRecovered: _nonNegativeInt(result['frames_recovered']),
      keyframeRequests: _nonNegativeInt(result['keyframe_requests']),
      jitterMs: _nonNegativeInt(result['jitter_ms']),
      rttMs: _nonNegativeInt(result['rtt_ms']),
      queueDepth: _boundedQueueDepth(result['queue_depth']),
      queueCapacity: _queueCapacity(result['queue_capacity']),
    );
  }

  Map<String, Object?> _identityArguments(
    RealtimeMediaEndpointId endpointId,
    RealtimeMediaEndpointIdentity identity,
    RealtimeMediaNativeOwnerToken? ownerToken,
  ) => <String, Object?>{
    'endpoint_id': endpointId.value,
    'realtime_id': identity.realtimeId,
    'peer_id': identity.peerId,
    'generation': identity.generation,
    'direction': identity.direction.name,
    'owner_token': ownerToken?.value,
  };

  Future<T> _invoke<T>(String method, [Object? arguments]) async {
    try {
      final value = await _channel.invokeMethod<T>(method, arguments);
      return value as T;
    } on PlatformException catch (error) {
      throw RealtimeMediaException(
        _mapPlatformError(error.code),
        error.message ?? 'Windows realtime media operation failed.',
      );
    } on MissingPluginException {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Windows realtime media plugin is unavailable.',
      );
    } on TypeError {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Windows realtime media plugin returned an invalid response.',
      );
    }
  }

  static ScreenCaptureSource? _decodeSource(Object? value) {
    if (value is! Map<Object?, Object?>) return null;
    final id = value['id'];
    final kind = value['kind'];
    if (id is! String || kind is! String) return null;
    final sourceKind = switch (kind) {
      'display' => ScreenCaptureSourceKind.display,
      'window' => ScreenCaptureSourceKind.window,
      _ => null,
    };
    if (sourceKind == null) return null;
    try {
      return ScreenCaptureSource(
        id: ScreenCaptureSourceId(id),
        kind: sourceKind,
        label: _boundedLabel(value['label']),
        width: _positiveInt(value['width']),
        height: _positiveInt(value['height']),
      );
    } on ArgumentError {
      return null;
    }
  }

  static int _nonNegativeInt(Object? value) {
    if (value is! num || !value.isFinite || value < 0) return 0;
    return value.toInt();
  }

  static int _boundedQueueDepth(Object? value) {
    if (value == null) return 0;
    final depth = _nonNegativeInt(value);
    if (depth > 3) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Windows media queue exceeded the fixed three-frame bound.',
      );
    }
    return depth;
  }

  static int _queueCapacity(Object? value) {
    if (value == null) return 3;
    if (_nonNegativeInt(value) != 3) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Windows media queue capacity violated the fixed three-frame bound.',
      );
    }
    return 3;
  }

  static int? _positiveInt(Object? value) {
    final result = _nonNegativeInt(value);
    return result > 0 && result <= 16_384 ? result : null;
  }

  static String? _boundedLabel(Object? value) {
    if (value is! String) return null;
    final label = value.trim();
    return label.isEmpty || label.length > 128 ? null : label;
  }

  static RealtimeMediaErrorCode _mapPlatformError(String code) =>
      switch (code) {
        'permission_denied' => RealtimeMediaErrorCode.permissionDenied,
        'capture_source_ended' => RealtimeMediaErrorCode.captureSourceEnded,
        'encoder_unavailable' => RealtimeMediaErrorCode.encoderUnavailable,
        'encoder_failed' => RealtimeMediaErrorCode.encoderFailed,
        'decoder_unavailable' => RealtimeMediaErrorCode.decoderUnavailable,
        'decoder_failed' => RealtimeMediaErrorCode.decoderFailed,
        'unsupported_codec' => RealtimeMediaErrorCode.unsupportedCodec,
        'stale_generation' => RealtimeMediaErrorCode.staleGeneration,
        'stale_endpoint' => RealtimeMediaErrorCode.staleEndpoint,
        'direction_mismatch' => RealtimeMediaErrorCode.directionMismatch,
        'duplicate_endpoint' => RealtimeMediaErrorCode.duplicateEndpoint,
        'driver_unavailable' => RealtimeMediaErrorCode.driverUnavailable,
        'peer_mismatch' => RealtimeMediaErrorCode.peerMismatch,
        'frame_rejected' => RealtimeMediaErrorCode.frameRejected,
        _ => RealtimeMediaErrorCode.backendFailure,
      };
}
