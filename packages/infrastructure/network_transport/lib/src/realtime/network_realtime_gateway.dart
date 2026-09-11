import 'dart:typed_data';

import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

import '../native/native_network_adapter.dart';
import '../native/network_command_gateway.dart';
import '../transport/transport_connection.dart';

/// Non-owning typed gateway for a Runtime-owned native Realtime route.
///
/// This contract is an App Shell adapter boundary. Feature code should consume
/// `network_sdk.RealtimeSession`, not this native event/control shape.
abstract interface class NetworkRealtimeGateway {
  /// Native typed state/signaling events. Signaling events stay inside the
  /// App/adapter and are never forwarded to a Feature.
  Stream<NativeNetworkEvent> get events;

  /// Queues a native start command and returns its command identity.
  ///
  /// [NativeCommandTicket.queueStatus] only describes acceptance by the native
  /// command queue. The eventual operation result arrives as a
  /// [NativeCommandResultEvent] on [events].
  NativeCommandTicket start({
    required String realtimeId,
    required String peerId,
  });

  /// Queues a native stop command and returns its command identity.
  ///
  /// A successful command result still does not mean the native session is
  /// closed; `closed` is reported asynchronously through [events].
  NativeCommandTicket stop({required String realtimeId});

  /// Creates one opaque native screen-media endpoint bound to the supplied
  /// native-authoritative session generation.
  NativeRealtimeMediaEndpointCreateResult createMediaEndpoint({
    required String realtimeId,
    required String peerId,
    required int generation,
    required NativeRealtimeMediaDirection direction,
  });

  /// Releases one opaque native screen-media endpoint lease.
  NativeOperationStatus releaseMediaEndpoint(
    NativeRealtimeMediaEndpointId endpointId,
  );

  /// Opens the native-only platform owner for an existing endpoint lease.
  NativeRealtimeMediaOwnerOpenResult openMediaOwner({
    required NativeRealtimeMediaEndpointId endpointId,
    required String realtimeId,
    required String peerId,
    required int generation,
    required NativeRealtimeMediaDirection direction,
  });

  /// Closes the platform owner without finalizing the endpoint lease.
  NativeOperationStatus closeMediaOwner(NativeRealtimeMediaOwnerToken token);
}

/// Optional extension for authenticated, typed screen-share consent. Keeping
/// it separate means older/synthetic gateways remain valid while production
/// gateways can add the new signal kind without exposing protocol bytes to a
/// Feature.
abstract interface class NetworkRealtimeConsentGateway {
  NativeCommandTicket sendScreenShareConsent({
    required String realtimeId,
    required String peerId,
    required int revision,
    required Uint8List payload,
  });
}

/// Identity and queue-level status for one native Realtime command.
///
/// The ticket deliberately does not contain an operation result. Callers must
/// correlate [commandId] with [NativeCommandResultEvent.commandId].
final class NativeCommandTicket {
  const NativeCommandTicket({
    required this.commandId,
    required this.queueStatus,
  });

  /// Identifier copied into the native command envelope and result event.
  final String commandId;

  /// Whether the native runtime accepted the command into its queue.
  final NativeOperationStatus queueStatus;
}

/// Runtime-owned implementation backed by a borrowed command gateway.
final class RuntimeNetworkRealtimeGateway
    implements NetworkRealtimeGateway, NetworkRealtimeConsentGateway {
  RuntimeNetworkRealtimeGateway(this._gateway, [this._media]);

  final NetworkCommandGateway _gateway;
  final NativeRealtimeMediaPort? _media;
  final NativeCommandResultGuard _commandResultGuard =
      NativeCommandResultGuard();
  int _commandSequence = 0;

  @override
  Stream<NativeNetworkEvent> get events => _gateway.events
      .map(_decodeEvent)
      .where((event) => event != null)
      .cast<NativeNetworkEvent>()
      .map(_commandResultGuard.filterEvent)
      .where((event) => event != null)
      .cast<NativeNetworkEvent>();

  @override
  NativeCommandTicket start({
    required String realtimeId,
    required String peerId,
  }) {
    final commandId = _nextCommandId('realtime-start');
    try {
      return _send(
        commandId: commandId,
        command: NativeNetworkProtocol.startRealtimeSessionCommand(
          commandId: commandId,
          realtimeId: realtimeId,
          peerId: peerId,
        ),
      );
    } on ArgumentError {
      return NativeCommandTicket(
        commandId: commandId,
        queueStatus: NativeOperationStatus.invalidArgument,
      );
    }
  }

  @override
  NativeCommandTicket stop({required String realtimeId}) {
    final commandId = _nextCommandId('realtime-stop');
    try {
      return _send(
        commandId: commandId,
        command: NativeNetworkProtocol.stopRealtimeSessionCommand(
          commandId: commandId,
          realtimeId: realtimeId,
        ),
      );
    } on ArgumentError {
      return NativeCommandTicket(
        commandId: commandId,
        queueStatus: NativeOperationStatus.invalidArgument,
      );
    }
  }

  @override
  NativeRealtimeMediaEndpointCreateResult createMediaEndpoint({
    required String realtimeId,
    required String peerId,
    required int generation,
    required NativeRealtimeMediaDirection direction,
  }) =>
      _media?.createMediaEndpoint(
        realtimeId: realtimeId,
        peerId: peerId,
        generation: generation,
        direction: direction,
      ) ??
      const NativeRealtimeMediaEndpointCreateResult(
        status: NativeOperationStatus.driverUnavailable,
      );

  @override
  NativeOperationStatus releaseMediaEndpoint(
    NativeRealtimeMediaEndpointId endpointId,
  ) =>
      _media?.releaseMediaEndpoint(endpointId) ??
      NativeOperationStatus.driverUnavailable;

  @override
  NativeRealtimeMediaOwnerOpenResult openMediaOwner({
    required NativeRealtimeMediaEndpointId endpointId,
    required String realtimeId,
    required String peerId,
    required int generation,
    required NativeRealtimeMediaDirection direction,
  }) =>
      _media?.openMediaOwner(
        endpointId: endpointId,
        realtimeId: realtimeId,
        peerId: peerId,
        generation: generation,
        direction: direction,
      ) ??
      const NativeRealtimeMediaOwnerOpenResult(
        status: NativeOperationStatus.driverUnavailable,
      );

  @override
  NativeOperationStatus closeMediaOwner(NativeRealtimeMediaOwnerToken token) =>
      _media?.closeMediaOwner(token) ?? NativeOperationStatus.driverUnavailable;

  @override
  NativeCommandTicket sendScreenShareConsent({
    required String realtimeId,
    required String peerId,
    required int revision,
    required Uint8List payload,
  }) {
    final commandId = _nextCommandId('realtime-consent');
    try {
      return _send(
        commandId: commandId,
        command: NativeNetworkProtocol.sendRealtimeSignalCommand(
          commandId: commandId,
          realtimeId: realtimeId,
          peerId: peerId,
          kind: NativeRealtimeSignalKind.screenShareConsent,
          revision: revision,
          payload: payload,
        ),
      );
    } on ArgumentError {
      return NativeCommandTicket(
        commandId: commandId,
        queueStatus: NativeOperationStatus.invalidArgument,
      );
    }
  }

  NativeCommandTicket _send({
    required String commandId,
    required Uint8List command,
  }) {
    if (!_commandResultGuard.register(commandId)) {
      return NativeCommandTicket(
        commandId: commandId,
        queueStatus: NativeOperationStatus.failure,
      );
    }
    final queueStatus = switch (_gateway.sendCommand(command)) {
      TransportOperationStatus.success => NativeOperationStatus.success,
      TransportOperationStatus.invalidArgument =>
        NativeOperationStatus.invalidArgument,
      TransportOperationStatus.stopped => NativeOperationStatus.stopped,
      TransportOperationStatus.failure => NativeOperationStatus.failure,
    };
    if (!queueStatus.isSuccess) _commandResultGuard.cancel(commandId);
    return NativeCommandTicket(commandId: commandId, queueStatus: queueStatus);
  }

  String _nextCommandId(String operation) {
    _commandSequence = (_commandSequence + 1) & 0x7fffffff;
    return '$operation-${DateTime.now().microsecondsSinceEpoch}-$_commandSequence';
  }

  static NativeNetworkEvent? _decodeEvent(Uint8List bytes) {
    try {
      return NativeNetworkProtocol.decodeEvent(bytes);
    } on FormatException {
      return null;
    }
  }
}
