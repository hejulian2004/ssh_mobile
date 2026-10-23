import 'package:realtime_media/realtime_media.dart';
import 'package:ssh_mobile/app/realtime_media_feature_adapters.dart';

final class ProbeEndpointBackend
    implements RealtimeMediaBackend, RealtimeMediaNativeOwnerBackend {
  ProbeEndpointBackend(this.inner, {this.onPhase});
  final void Function(String)? onPhase;
  int startCalls = 0;
  final AppRealtimeMediaBackend inner;
  RealtimeMediaEndpointId? endpointId;
  RealtimeMediaEndpointIdentity? identity;
  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity value,
  ) async {
    startCalls++;
    identity = value;
    onPhase?.call('endpoint_create');
    endpointId = await inner.start(value);
    onPhase?.call('endpoint_created');
    return endpointId!;
  }

  @override
  Future<RealtimeMediaNativeOwnerToken> openNativeOwner({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    onPhase?.call('owner_open');
    final token = await inner.openNativeOwner(
      endpointId: endpointId,
      identity: identity,
    );
    onPhase?.call('owner_opened');
    return token;
  }

  @override
  Future<void> closeNativeOwner({
    required RealtimeMediaNativeOwnerToken token,
    required RealtimeMediaEndpointIdentity identity,
  }) => inner.closeNativeOwner(token: token, identity: identity);
  @override
  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  }) => inner.attachCaptureSource(
    endpointId: endpointId,
    identity: identity,
    source: source,
  );
  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => inner.attachRemoteVideoSurface(
    endpointId: endpointId,
    identity: identity,
  );
  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => inner.detach(endpointId: endpointId, identity: identity);
  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => inner.release(endpointId: endpointId, identity: identity);
  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => inner.readStats(endpointId: endpointId, identity: identity);
}
