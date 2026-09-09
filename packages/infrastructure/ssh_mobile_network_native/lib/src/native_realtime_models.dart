part of 'native_realtime_protocol.dart';

/// Typed, versioned screen-share consent metadata carried by the dedicated
/// realtime signal. The payload never contains media, SDP, ICE or secrets.
final class NativeScreenShareConsent {
  const NativeScreenShareConsent({
    required this.schemaVersion,
    required this.operationId,
    required this.realtimeId,
    required this.issuedAtMs,
    required this.expiresAtMs,
    required this.decision,
    required this.senderPeerId,
    required this.purpose,
    required this.media,
    required this.requiresAcceptance,
    required this.actionRevision,
  });

  final int schemaVersion;
  final String operationId;
  final String realtimeId;
  final int issuedAtMs;
  final int expiresAtMs;
  final NativeScreenShareConsentDecision decision;
  final String senderPeerId;
  final NativeScreenShareConsentPurpose purpose;
  final NativeScreenShareMediaKind media;
  final bool requiresAcceptance;
  final int actionRevision;
}

/// Realtime session state event.
final class NativeRealtimeStateChangedEvent extends NativeNetworkEvent {
  /// Creates a realtime state event.
  const NativeRealtimeStateChangedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.realtimeId,
    required this.peerId,
    required this.state,
    required this.revision,
    required this.generation,
    this.error,
  });

  /// Stable 16-byte lowercase hexadecimal realtime session identifier.
  final String realtimeId;

  /// Remote peer identifier.
  final String peerId;

  /// Current native realtime state.
  final NativeRealtimeSessionState state;

  /// Signaling revision associated with this state.
  final int revision;

  /// Native-authoritative media/session generation. This is independent from
  /// [revision] and is the only value accepted by media endpoint creation.
  final int generation;

  /// Structured failure, when [state] is failed.
  final NativeNetworkError? error;
}

/// Realtime session state snapshot published once the session is stable.
final class NativeRealtimeSnapshotEvent extends NativeNetworkEvent {
  /// Creates a realtime snapshot event.
  const NativeRealtimeSnapshotEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.realtimeId,
    required this.peerId,
    required this.state,
    required this.revision,
    required this.generation,
    this.error,
  });

  /// Stable 16-byte lowercase hexadecimal realtime session identifier.
  final String realtimeId;

  /// Remote peer identifier.
  final String peerId;

  /// Current native realtime state.
  final NativeRealtimeSessionState state;

  /// Signaling revision associated with this snapshot.
  final int revision;

  /// Native-authoritative media/session generation. This is independent from
  /// [revision] and is the only value accepted by media endpoint creation.
  final int generation;

  /// Structured failure, when [state] is failed.
  final NativeNetworkError? error;
}

/// Realtime signaling event containing bounded SDP/ICE opaque bytes.
final class NativeRealtimeSignalEvent extends NativeNetworkEvent {
  /// Creates a realtime signaling event.
  NativeRealtimeSignalEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.realtimeId,
    required this.peerId,
    required this.kind,
    required this.revision,
    required Uint8List payload,
    this.consent,
  }) : payload = Uint8List.fromList(payload);

  /// Stable 16-byte lowercase hexadecimal realtime session identifier.
  final String realtimeId;

  /// Remote peer identifier.
  final String peerId;

  /// Signaling message kind.
  final NativeRealtimeSignalKind kind;

  /// Signaling revision associated with the message.
  final int revision;

  /// Decoded consent metadata when [kind] is
  /// [NativeRealtimeSignalKind.screenShareConsent]. Other signal kinds leave
  /// this null and retain their opaque payload semantics.
  final NativeScreenShareConsent? consent;

  /// SDP, ICE, or close control bytes. Never a media/file data frame.
  final Uint8List payload;
}

/// Stable business identity for a logical ReliableStream.
///
/// `streamId` is only unique within the opener device namespace.
final class NativeStreamHandle {
  /// Creates a logical stream handle.
  const NativeStreamHandle({
    required this.openerDeviceId,
    required this.streamId,
  });

  /// Device ID of the side that opened the logical stream.
  final String openerDeviceId;

  /// Numeric stream ID within the opener device namespace.
  final int streamId;

  @override
  bool operator ==(Object other) =>
      other is NativeStreamHandle &&
      other.openerDeviceId == openerDeviceId &&
      other.streamId == streamId;

  @override
  int get hashCode => Object.hash(openerDeviceId, streamId);
}

/// ReliableStream 收到对端字节后发布的事件（network-protocol tag 26）。
final class NativeSshStreamDataReceivedEvent extends NativeNetworkEvent {
  /// Creates an SSH stream data event.
  NativeSshStreamDataReceivedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peerId,
    required this.handle,
    required Uint8List data,
  }) : data = Uint8List.fromList(data);

  /// Remote peer identifier.
  final String peerId;

  /// Stable identity of the logical stream.
  final NativeStreamHandle handle;

  /// Opener device ID, retained as a convenience view of [handle].
  String get openerDeviceId => handle.openerDeviceId;

  /// Logical stream identifier, retained as a convenience view of [handle].
  int get streamId => handle.streamId;

  /// Opaque SSH/SFTP protocol bytes.
  final Uint8List data;
}

/// ReliableStream 关闭事件（network-protocol tag 27）。
final class NativeSshStreamClosedEvent extends NativeNetworkEvent {
  /// Creates an SSH stream closed event.
  const NativeSshStreamClosedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peerId,
    required this.handle,
  });

  /// Remote peer identifier.
  final String peerId;

  /// Stable identity of the logical stream.
  final NativeStreamHandle handle;

  /// Opener device ID, retained as a convenience view of [handle].
  String get openerDeviceId => handle.openerDeviceId;

  /// Logical stream identifier, retained as a convenience view of [handle].
  int get streamId => handle.streamId;
}
