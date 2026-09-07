part of '../ssh_mobile_network_native.dart';

/// Creates an opaque native screen-media endpoint lease. The C ABI is limited
/// to low-frequency lifecycle control; it has no per-frame operation.
@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Uint8>,
    UintPtr,
    Pointer<Uint8>,
    UintPtr,
    Uint64,
    Uint32,
    Pointer<Uint64>,
  )
>(symbol: 'ssh_net_realtime_media_endpoint_create')
external int _sshNetRealtimeMediaEndpointCreateNative(
  Pointer<Void> handle,
  Pointer<Uint8> realtimeId,
  int realtimeIdLength,
  Pointer<Uint8> peerId,
  int peerIdLength,
  int expectedGeneration,
  int direction,
  Pointer<Uint64> outEndpoint,
);

/// Releases an opaque native screen-media endpoint lease.
@Native<Int32 Function(Pointer<Void>, Uint64)>(
  symbol: 'ssh_net_realtime_media_endpoint_release',
)
external int _sshNetRealtimeMediaEndpointReleaseNative(
  Pointer<Void> handle,
  int endpoint,
);
