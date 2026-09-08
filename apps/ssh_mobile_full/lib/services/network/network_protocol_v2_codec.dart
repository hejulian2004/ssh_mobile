// Network Protocol V2 手写编解码器，由 Dart FFI 服务与测试共同使用。
//
// Protobuf schema 仍是唯一线协议来源；本编解码器只镜像仓库中的字段 tag，
// 不引入生成绑定。命令、信封、事件族和 wire primitives 分别由相邻 part
// 文件维护，保持这个稳定入口的 public API 不变。

import 'dart:convert';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

part '../../app/network/network_protocol_v2_codec_commands.dart';
part '../../app/network/network_protocol_v2_codec_envelope.dart';
part '../../app/network/network_protocol_v2_codec_peer_events.dart';
part '../../app/network/network_protocol_v2_codec_transfer_events.dart';
part '../../app/network/network_protocol_v2_codec_stream_events.dart';
part '../../app/network/network_protocol_v2_codec_screen_share.dart';
part '../../app/network/network_protocol_v2_codec_wire.dart';

/// Stable identity for a logical ReliableStream.
typedef SshStreamHandle = NativeStreamHandle;

/// ReliableStream 收到对端 SSH/SFTP 字节的事件（network-protocol tag 26）。
final class SshStreamDataReceivedEvent {
  /// 创建 SSH 流数据事件。
  const SshStreamDataReceivedEvent({
    required this.eventId,
    required this.timestamp,
    required this.peerId,
    required this.handle,
    required this.data,
  });

  final String eventId;
  final DateTime timestamp;
  final String peerId;
  final NativeStreamHandle handle;
  int get streamId => handle.streamId;
  final Uint8List data;
}

/// ReliableStream 关闭事件（network-protocol tag 27）。
final class SshStreamClosedEvent {
  /// 创建 SSH 流关闭事件。
  const SshStreamClosedEvent({
    required this.eventId,
    required this.timestamp,
    required this.peerId,
    required this.handle,
  });

  final String eventId;
  final DateTime timestamp;
  final String peerId;
  final NativeStreamHandle handle;
  int get streamId => handle.streamId;
}

/// 解码后的 V2 信封，包含内部命令结果或公开事件。
final class NetworkProtocolFrame {
  /// 创建解码后的协议帧。
  const NetworkProtocolFrame({
    required this.eventId,
    required this.protocolVersion,
    this.commandId,
    this.commandAccepted = false,
    this.commandError,
    this.event,
    this.screenShareConsent,
    this.sshStreamData,
    this.sshStreamClosed,
  });

  final String eventId;
  final int protocolVersion;
  final String? commandId;
  final bool commandAccepted;
  final NetworkError? commandError;
  final NetworkEvent? event;

  /// Typed screen-share consent carried by realtime signal field 22.
  final RealtimeConsent? screenShareConsent;

  /// native SSH 流数据事件（tag 26），不进入业务 [event] 流。
  final SshStreamDataReceivedEvent? sshStreamData;

  /// native SSH 流关闭事件（tag 27），不进入业务 [event] 流。
  final SshStreamClosedEvent? sshStreamClosed;
}

/// 当前 network.v2 线协议契约的手写编解码器。
final class NetworkProtocolV2Codec {
  static const int protocolVersion = 2;
  static const _commands = _NetworkCommandEncoder();
  static const _peerEvents = _PeerEventDecoder();
  static const _transferEvents = _TransferEventDecoder();
  static const _streamEvents = _SshStreamEventDecoder();

  /// 创建无状态 V2 编解码器。
  const NetworkProtocolV2Codec();

  /// 编码运行时配置命令。
  Uint8List configureRuntimeCommand({
    required String commandId,
    required NetworkRuntimeConfig config,
  }) => _commands.configureRuntime(commandId: commandId, config: config);

  /// 编码对端新增或替换命令。
  Uint8List upsertPeerCommand({
    required String commandId,
    required PeerConfig peer,
  }) => _commands.upsertPeer(commandId: commandId, peer: peer);

  /// 编码显式删除对端 trust/configuration 命令。
  Uint8List removePeerCommand({
    required String commandId,
    required String peerId,
  }) => _commands.removePeer(commandId: commandId, peerId: peerId);

  /// 编码异步对端连接命令。
  ///
  /// 载荷镜像 network_protocol ConnectPeerCommand：peer_id(1)、intent(2)、
  /// communication_class(3)。communication_class 的取值与 Rust 侧
  /// `CommunicationClass` 枚举一致（reliableStream=1 … realtimeMedia=5），
  /// 由 [CommunicationClass.wireValue] 提供。
  Uint8List connectPeerCommand({
    required String commandId,
    required String peerId,
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) => _commands.connectPeer(
    commandId: commandId,
    peerId: peerId,
    communicationClass: communicationClass,
  );

  /// 编码异步对端断开命令。
  Uint8List disconnectPeerCommand({
    required String commandId,
    required String peerId,
  }) => _commands.disconnectPeer(commandId: commandId, peerId: peerId);

  /// 编码文件传输注册命令。
  Uint8List sendFileCommand({
    required String commandId,
    required String transferId,
    required String peerId,
    required String filePath,
  }) => _commands.sendFile(
    commandId: commandId,
    transferId: transferId,
    peerId: peerId,
    filePath: filePath,
  );

  /// 编码传输取消命令。
  Uint8List cancelTransferCommand({
    required String commandId,
    required String transferId,
  }) => _commands.cancelTransfer(commandId: commandId, transferId: transferId);

  /// 编码传入传输审批或拒绝命令。
  Uint8List respondIncomingTransferCommand({
    required String commandId,
    required String transferId,
    required bool accept,
  }) => _commands.respondIncomingTransfer(
    commandId: commandId,
    transferId: transferId,
    accept: accept,
  );

  /// 为原生数据面编码 Relay 配置凭据。
  Uint8List configureRelayCommand({
    required String commandId,
    required RelayConfig config,
  }) => _commands.configureRelay(commandId: commandId, config: config);

  /// 编码 Relay 断开命令。
  Uint8List disconnectRelayCommand({required String commandId}) =>
      _commands.disconnectRelay(commandId: commandId);

  /// 编码打开一条到对端的 ReliableStream（native tag 25）。
  Uint8List sshStreamOpenCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    String service = 'ssh',
  }) => _commands.openSshStream(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
    service: service,
  );

  /// 编码向已打开流追加 SSH/SFTP 字节（native tag 26）。
  Uint8List sshStreamDataCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    required Uint8List data,
  }) => _commands.sendSshStreamData(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
    data: data,
  );

  /// 编码关闭一条 ReliableStream（native tag 27）。
  Uint8List sshStreamCloseCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
  }) => _commands.closeSshStream(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
  );

  /// 从 V2 命令信封读取命令标识。
  String commandId(Uint8List command) => _commands.commandId(command);

  /// 编码 typed/versioned screen-share consent metadata.
  Uint8List encodeScreenShareConsent(RealtimeConsent consent) =>
      _encodeScreenShareConsent(consent);

  /// 解码 typed/versioned screen-share consent metadata.
  RealtimeConsent decodeScreenShareConsent(Uint8List bytes) =>
      _decodeScreenShareConsent(bytes);

  /// 解码 V2 事件信封及可选的内部命令结果。
  NetworkProtocolFrame decodeEvent(Uint8List bytes) => _decodeEvent(bytes);
}
