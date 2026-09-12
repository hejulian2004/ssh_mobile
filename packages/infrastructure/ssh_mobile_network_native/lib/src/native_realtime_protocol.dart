// Native Network Protocol V2 Realtime command/event bindings.
//
// The Rust network-protocol crate remains the wire-contract owner. This file
// mirrors only the fields needed by the public native SDK facade and keeps
// protobuf framing, identifiers, and payload sizes bounded at the Dart edge.

import 'dart:convert';
import 'dart:typed_data';

part 'native_protocol_enums.dart';
part 'native_protocol_models.dart';
part 'native_command_result_guard.dart';
part 'native_realtime_models.dart';
part 'native_network_protocol_facade.dart';
part 'native_protocol_command_encoder.dart';
part 'native_protocol_event_decoder.dart';
part 'native_peer_event_decoder.dart';
part 'native_delivery_event_decoder.dart';
part 'native_realtime_event_decoder.dart';
part 'native_protocol_value_mapper.dart';
part 'native_proto_codec.dart';

const _protocolVersion = 2;
const _maxCommandIdBytes = 128;
const _maxEventIdBytes = 256;
const _maxPeerIdBytes = 128;
const _maxErrorMessageBytes = 8 * 1024;
const _realtimeIdBytes = 32;
const _sharedSessionInstanceIdBytes = 32;
const _maxRealtimePayloadBytes = 256 * 1024;
const _maxScreenShareConsentPayloadBytes = 4 * 1024;
const _maxScreenShareOperationIdBytes = 128;
const _maxIceCandidateBytes = 8 * 1024;
const _maxEventBytes = 384 * 1024;
const _maxStreamServiceBytes = 128;
const _maxStreamId = 0xffff;
const _maxStreamDataBytes = 384 * 1024;
const _maxStreamHandleBytes = _maxPeerIdBytes + 16;
const _maxTransferIdBytes = 128;
const _maxFileNameBytes = 256;
const _maxChannelIdBytes = 128;
const _maxMessageIdBytes = 64;
