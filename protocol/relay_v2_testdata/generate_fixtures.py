#!/usr/bin/env python3
"""Deterministic generator for the relay v2 golden fixtures.

Implements the minimal protobuf wire encoding for exactly the relay.v2
messages frozen in protocol/proto/relay/v2/relay_v2.proto, then emits:

  * 22 full-wire-frame .bin fixtures (4-byte big-endian length + protobuf)
  * manifest.json  — semantic expectations shared by the Rust and Go codecs
  * session_sequence.golden.json — ordered full-lifecycle frame sequence

Run:  python3 generate_fixtures.py [--regenerate | --check]

  --regenerate (default)  (re)write all files in this directory.
  --check                 verify committed files match the deterministic output
                          without writing; exits non-zero on mismatch.

The output is fully deterministic: no randomness, no timestamps, stable JSON
key ordering. Re-running always produces byte-identical files.

See protocol/RELAY_V2_CONTRACT.md for the contract and the seed semantics.
"""

import json
import os
import struct
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SCHEMA_VERSION = 2

# ---------------------------------------------------------------------------
# Centralized constants — MUST match the .proto header comment and each codec.
# ---------------------------------------------------------------------------
CONSTANTS = {
    "RELAY_V2_VERSION": 2,
    "FRAME_LENGTH_PREFIX_BYTES": 4,
    "MAX_RELAY_FRAME_BYTES": 4 + 512 * 1024,
    "MAX_RELAY_DATA_FRAME_BYTES": 4 + 512 * 1024,
    "MAX_DEVICE_ID_BYTES": 128,
    "MAX_ATTEMPT_ID_BYTES": 128,
    "MAX_REALTIME_ID_BYTES": 128,
    "MAX_REALTIME_SIGNAL_PAYLOAD_BYTES": 256 * 1024,
    "MAX_DISCOVERY_CANDIDATES": 64,
    "MAX_DISCOVERY_CANDIDATE_BYTES": 4096,
    "MAX_DISCOVERY_CAPABILITIES": 64,
    "RESERVATION_ID_BYTES": 16,
    "RESERVATION_ID_HEX_CHARS": 32,
    "RESERVATION_TOKEN_BYTES": 32,
    "HEARTBEAT_INTERVAL_S": 20,
    "PRESENCE_TTL_S": 60,
    "SERVER_HEARTBEAT_MISSES_BEFORE_CLOSE": 2,
    "RESERVATION_LIFETIME_S_DEFAULT": 60,
    "RESERVATION_EXPIRY_GRACE_S": 5,
    "RESOLVE_RETRY_HINT_NOT_READY_MS": 2000,
    "RESOLVE_RETRY_HINT_UNKNOWN_MS": 5000,
    "DIRECT_CONNECT_WINDOW_MS": 4000,
}

# Deterministic seed values (design §"Relay Protocol V2 Wire Contract" §7).
SEED = {
    "schema_version": SCHEMA_VERSION,
    "epoch_high": 0x6A09E667,          # device A (initiator) runtime epoch
    "epoch_low": 0xBB67AE85,
    "responder_epoch_high": 0x9E3779B9,  # device B (responder) runtime epoch
    "responder_epoch_low": 0x7F4A7C15,
    "revision": 7,
    "responder_revision": 3,
    "request_id": 1001,
    "responder_request_id": 2002,
    "attempt_id": "a1b2c3d4e5f60718293a4b5c6d7e8f90",  # 32 hex
    "device_a": "11111111111111111111111111111111",
    "device_b": "22222222222222222222222222222222",
    "reservation_id": "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d",  # 32 hex / 16 bytes
    "realtime_id": "rt-9f8e7d6c5b4a39281706f5e4d3c2b1a0",
    "server_time_ms": 1723840800123,
    "sent_at_ms": 1723840820123,
    "published_at_ms": 1723840800456,
    "expires_at_ms": 1723840860123,
    "sequence": 42,
    "candidate_a": "cand:type=host;ip=192.168.1.10;port=54321;proto=quic",
    "candidate_b": "cand:type=srflx;ip=203.0.113.7;port=3478;proto=udp",
}

# Opaque byte payloads (hex recorded in the manifest).
TOKEN_A = bytes(range(1, 33))                  # 32 bytes: 0x01..0x20
TOKEN_B = bytes(range(33, 65))                 # 32 bytes: 0x21..0x40
ENCRYPTED_PAYLOAD = bytes(range(65, 129))      # 64 bytes: 0x41..0x80
REALTIME_PAYLOAD = b"sdp-mid=0;candidate:842163049 1 udp 1677729535 198.51.100.7 54321 typ srflx"

# Enum value maps (names in the .proto -> numbers on the wire).
ENUMS = {
    "TransportCapability": {
        "TRANSPORT_CAPABILITY_UNSPECIFIED": 0,
        "TRANSPORT_CAPABILITY_QUIC": 1,
        "TRANSPORT_CAPABILITY_TCP": 2,
        "TRANSPORT_CAPABILITY_UDP_DATAGRAM": 3,
        "TRANSPORT_CAPABILITY_WEBSOCKET": 4,
        "TRANSPORT_CAPABILITY_WEBRTC": 5,
        "TRANSPORT_CAPABILITY_RELAY_DATA": 6,
    },
    "ResolveStatus": {
        "RESOLVE_STATUS_UNSPECIFIED": 0,
        "RESOLVE_STATUS_READY": 1,
        "RESOLVE_STATUS_OFFLINE": 2,
        "RESOLVE_STATUS_NOT_READY": 3,
        "RESOLVE_STATUS_UNKNOWN": 4,
    },
    "RealtimeSignalKind": {
        "REALTIME_SIGNAL_KIND_UNSPECIFIED": 0,
        "REALTIME_SIGNAL_KIND_OFFER": 1,
        "REALTIME_SIGNAL_KIND_ANSWER": 2,
        "REALTIME_SIGNAL_KIND_ICE_CANDIDATE": 3,
        "REALTIME_SIGNAL_KIND_ICE_RESTART": 4,
        "REALTIME_SIGNAL_KIND_CLOSE": 5,
    },
    "ErrorCode": {
        "ERROR_CODE_UNSPECIFIED": 0,
        "ERROR_CODE_CONTROL_UNAVAILABLE": 1,
        "ERROR_CODE_AUTHENTICATION_FAILED": 2,
        "ERROR_CODE_PEER_OFFLINE": 3,
        "ERROR_CODE_PEER_NOT_READY": 4,
        "ERROR_CODE_RESOLVE_TIMEOUT": 5,
        "ERROR_CODE_PROTOCOL": 6,
        "ERROR_CODE_EPOCH_CONFLICT": 7,
        "ERROR_CODE_REVISION_STALE": 8,
        "ERROR_CODE_RESERVATION_FAILED": 9,
        "ERROR_CODE_RESERVATION_EXPIRED": 10,
        "ERROR_CODE_RELAY_UNAVAILABLE": 11,
        "ERROR_CODE_RATE_LIMITED": 12,
        "ERROR_CODE_MALFORMED_FRAME": 13,
        "ERROR_CODE_FRAME_TOO_LARGE": 14,
    },
}


# ---------------------------------------------------------------------------
# Minimal protobuf wire encoding (proto3, canonical output).
# ---------------------------------------------------------------------------
def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _tag(field, wire):
    return varint((field << 3) | wire)


def f_varint(field, value):
    return _tag(field, 0) + varint(value)


def f_fixed64(field, value):
    return _tag(field, 1) + struct.pack("<Q", value & 0xFFFFFFFFFFFFFFFF)


def f_len(field, data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    return _tag(field, 2) + varint(len(data)) + data


def f_msg(field, data):
    return _tag(field, 2) + varint(len(data)) + data


def f_packed(field, values):
    body = b"".join(varint(v) for v in values)
    return _tag(field, 2) + varint(len(body)) + body


def frame(pb):
    return struct.pack(">I", len(pb)) + pb


# ---------------------------------------------------------------------------
# Message builders (fields emitted in ascending field-number order; proto3
# default values omitted so prost / protoc-gen-go re-encode byte-identically).
# ---------------------------------------------------------------------------
def msg_runtime_epoch(high, low):
    return f_fixed64(1, high) + f_fixed64(2, low)


def msg_candidate_bundle(candidates):
    return b"".join(f_len(1, c) for c in candidates)


def msg_discovery_snapshot(epoch_high, epoch_low, revision, caps, candidates, published_at_ms):
    out = b""
    if epoch_high or epoch_low:
        out += f_msg(1, msg_runtime_epoch(epoch_high, epoch_low))
    if revision:
        out += f_varint(2, revision)
    if caps:
        out += f_packed(3, caps)
    if candidates is not None:
        out += f_msg(4, msg_candidate_bundle(candidates))
    if published_at_ms:
        out += f_varint(5, published_at_ms)
    return out


def msg_ready(protocol_version, device_id, server_time_ms, heartbeat_interval_s, presence_ttl_s):
    out = b""
    if protocol_version:
        out += f_varint(1, protocol_version)
    if device_id:
        out += f_len(2, device_id)
    if server_time_ms:
        out += f_varint(3, server_time_ms)
    if heartbeat_interval_s:
        out += f_varint(4, heartbeat_interval_s)
    if presence_ttl_s:
        out += f_varint(5, presence_ttl_s)
    return out


def msg_heartbeat(request_id, sent_at_ms):
    out = b""
    if request_id:
        out += f_varint(1, request_id)
    if sent_at_ms:
        out += f_varint(2, sent_at_ms)
    return out


def msg_heartbeat_ack(request_id, server_time_ms):
    out = b""
    if request_id:
        out += f_varint(1, request_id)
    if server_time_ms:
        out += f_varint(2, server_time_ms)
    return out


def msg_discovery_publish(request_id, snapshot):
    out = b""
    if request_id:
        out += f_varint(1, request_id)
    if snapshot is not None:
        out += f_msg(2, snapshot)
    return out


def msg_discovery_ack(request_id, epoch_high, epoch_low, revision):
    out = b""
    if request_id:
        out += f_varint(1, request_id)
    if epoch_high or epoch_low:
        out += f_msg(2, msg_runtime_epoch(epoch_high, epoch_low))
    if revision:
        out += f_varint(3, revision)
    return out


def msg_resolve_peer_response(request_id, status, discovery, retry_after_ms):
    out = b""
    if request_id:
        out += f_varint(1, request_id)
    if status:
        out += f_varint(2, status)
    if discovery is not None:
        out += f_msg(3, discovery)
    if retry_after_ms:
        out += f_varint(4, retry_after_ms)
    return out


def msg_connectivity_offer(request_id, attempt_id, initiator_device_id, epoch_high, epoch_low,
                           initiator_revision, initiator_snapshot):
    out = b""
    if request_id:
        out += f_varint(1, request_id)
    if attempt_id:
        out += f_len(2, attempt_id)
    if initiator_device_id:
        out += f_len(3, initiator_device_id)
    if epoch_high or epoch_low:
        out += f_msg(4, msg_runtime_epoch(epoch_high, epoch_low))
    if initiator_revision:
        out += f_varint(5, initiator_revision)
    if initiator_snapshot is not None:
        out += f_msg(6, initiator_snapshot)
    return out


def msg_connectivity_answer(request_id, attempt_id, accepted, responder_device_id, epoch_high,
                            epoch_low, responder_revision, responder_snapshot):
    out = b""
    if request_id:
        out += f_varint(1, request_id)
    if attempt_id:
        out += f_len(2, attempt_id)
    if accepted:
        out += f_varint(3, 1)
    if responder_device_id:
        out += f_len(4, responder_device_id)
    if epoch_high or epoch_low:
        out += f_msg(5, msg_runtime_epoch(epoch_high, epoch_low))
    if responder_revision:
        out += f_varint(6, responder_revision)
    if responder_snapshot is not None:
        out += f_msg(7, responder_snapshot)
    return out


def msg_peer_presence_hint(device_id, online, epoch_high, epoch_low, revision):
    out = b""
    if device_id:
        out += f_len(1, device_id)
    if online:
        out += f_varint(2, 1)
    if epoch_high or epoch_low:
        out += f_msg(3, msg_runtime_epoch(epoch_high, epoch_low))
    if revision:
        out += f_varint(4, revision)
    return out


def msg_presence_hint_snapshot(peers, published_at_ms):
    out = b""
    for p in peers:
        out += f_msg(1, msg_peer_presence_hint(*p))
    if published_at_ms:
        out += f_varint(2, published_at_ms)
    return out


def msg_peer_available_hint(device_id, epoch_high, epoch_low, revision):
    out = b""
    if device_id:
        out += f_len(1, device_id)
    if epoch_high or epoch_low:
        out += f_msg(2, msg_runtime_epoch(epoch_high, epoch_low))
    if revision:
        out += f_varint(3, revision)
    return out


def msg_peer_unavailable_hint(device_id, reason):
    out = b""
    if device_id:
        out += f_len(1, device_id)
    if reason:
        out += f_len(2, reason)
    return out


def msg_relay_reserve_request(request_id, attempt_id, target_device_id, desired_lifetime_s):
    out = b""
    if request_id:
        out += f_varint(1, request_id)
    if attempt_id:
        out += f_len(2, attempt_id)
    if target_device_id:
        out += f_len(3, target_device_id)
    if desired_lifetime_s:
        out += f_varint(4, desired_lifetime_s)
    return out


def msg_relay_reserve_response(request_id, attempt_id, reservation_id, endpoint, expires_at_ms, local_token):
    out = b""
    if request_id:
        out += f_varint(1, request_id)
    if attempt_id:
        out += f_len(2, attempt_id)
    if reservation_id:
        out += f_len(3, reservation_id)
    if endpoint:
        out += f_len(4, endpoint)
    if expires_at_ms:
        out += f_varint(5, expires_at_ms)
    if local_token:
        out += f_len(6, local_token)
    return out


def msg_incoming_relay_reservation(attempt_id, reservation_id, initiator_device_id, endpoint,
                                   expires_at_ms, local_token):
    out = b""
    if attempt_id:
        out += f_len(1, attempt_id)
    if reservation_id:
        out += f_len(2, reservation_id)
    if initiator_device_id:
        out += f_len(3, initiator_device_id)
    if endpoint:
        out += f_len(4, endpoint)
    if expires_at_ms:
        out += f_varint(5, expires_at_ms)
    if local_token:
        out += f_len(6, local_token)
    return out


def msg_realtime_signal(request_id, realtime_id, target_device_id, kind, revision, payload):
    out = b""
    if request_id:
        out += f_varint(1, request_id)
    if realtime_id:
        out += f_len(2, realtime_id)
    if target_device_id:
        out += f_len(3, target_device_id)
    if kind:
        out += f_varint(4, kind)
    if revision:
        out += f_varint(5, revision)
    if payload:
        out += f_len(6, payload)
    return out


def msg_protocol_error(request_id, attempt_id, code, message):
    out = b""
    if request_id:
        out += f_varint(1, request_id)
    if attempt_id:
        out += f_len(2, attempt_id)
    if code:
        out += f_varint(3, code)
    if message:
        out += f_len(4, message)
    return out


def msg_relay_data_connect(reservation_id, local_token):
    out = b""
    if reservation_id:
        out += f_len(1, reservation_id)
    if local_token:
        out += f_len(2, local_token)
    return out


def msg_relay_data_payload(sequence, encrypted_payload):
    out = b""
    if sequence:
        out += f_varint(1, sequence)
    if encrypted_payload:
        out += f_len(2, encrypted_payload)
    return out


def msg_relay_data_close(reason, detail):
    out = b""
    if reason:
        out += f_varint(1, reason)
    if detail:
        out += f_len(2, detail)
    return out


# RelayFrame oneof field numbers (must match the .proto).
ONE_OF = {
    "ready": 10, "heartbeat": 11, "heartbeat_ack": 12, "discovery_publish": 13,
    "discovery_ack": 14, "resolve_peer_request": 15, "resolve_peer_response": 16,
    "connectivity_offer": 17, "connectivity_answer": 18, "presence_hint_snapshot": 19,
    "peer_available_hint": 20, "peer_unavailable_hint": 21, "relay_reserve_request": 22,
    "relay_reserve_response": 23, "incoming_relay_reservation": 24, "realtime_signal": 25,
    "protocol_error": 26,
}
DATA_ONE_OF = {"connect": 10, "payload": 11, "ack": 12, "close": 13}


def relay_frame(kind, inner_bytes):
    return f_varint(1, CONSTANTS["RELAY_V2_VERSION"]) + f_msg(ONE_OF[kind], inner_bytes)


def relay_data_frame(kind, inner_bytes):
    return f_varint(1, CONSTANTS["RELAY_V2_VERSION"]) + f_msg(DATA_ONE_OF[kind], inner_bytes)


# ---------------------------------------------------------------------------
# Deterministic derived values
# ---------------------------------------------------------------------------
ENDPOINT = "wss://relay.example.test/v2/relay/%s" % SEED["reservation_id"]
EPOCH_A = (SEED["epoch_high"], SEED["epoch_low"])
EPOCH_B = (SEED["responder_epoch_high"], SEED["responder_epoch_low"])
SNAPSHOT_A = msg_discovery_snapshot(
    SEED["epoch_high"], SEED["epoch_low"], SEED["revision"],
    caps=[1, 2, 6],  # QUIC, TCP, RELAY_DATA
    candidates=[SEED["candidate_a"], SEED["candidate_b"]],
    published_at_ms=SEED["published_at_ms"],
)
SNAPSHOT_B = msg_discovery_snapshot(
    SEED["responder_epoch_high"], SEED["responder_epoch_low"], SEED["responder_revision"],
    caps=[1, 6],  # QUIC, RELAY_DATA
    candidates=[SEED["candidate_a"]],
    published_at_ms=SEED["published_at_ms"],
)
PEERS = [
    (SEED["device_a"], True, SEED["epoch_high"], SEED["epoch_low"], SEED["revision"]),
    (SEED["device_b"], True, SEED["responder_epoch_high"], SEED["responder_epoch_low"],
     SEED["responder_revision"]),
]


def _cap_names(nums):
    inv = {v: k for k, v in ENUMS["TransportCapability"].items()}
    return [inv[n].replace("TRANSPORT_CAPABILITY_", "") for n in nums]


def _epoch_expect(high_key, low_key):
    return {
        "epoch_high": "0x%08x" % SEED[high_key],
        "epoch_low": "0x%08x" % SEED[low_key],
    }


# ---------------------------------------------------------------------------
# Fixture table
# ---------------------------------------------------------------------------
FIXTURES = [
    # 1
    dict(
        name="ready", file="ready.control.bin", transport="control", direction="server->client",
        build=lambda: relay_frame("ready", msg_ready(
            protocol_version=2, device_id=SEED["device_a"],
            server_time_ms=SEED["server_time_ms"],
            heartbeat_interval_s=CONSTANTS["HEARTBEAT_INTERVAL_S"],
            presence_ttl_s=CONSTANTS["PRESENCE_TTL_S"])),
        expects=dict(
            message="ready", version=2, protocol_version=2, device_id=SEED["device_a"],
            server_time_ms=SEED["server_time_ms"], heartbeat_interval_s=20, presence_ttl_s=60),
    ),
    # 2
    dict(
        name="heartbeat", file="heartbeat.control.bin", transport="control", direction="client->server",
        build=lambda: relay_frame("heartbeat", msg_heartbeat(
            request_id=SEED["request_id"], sent_at_ms=SEED["sent_at_ms"])),
        expects=dict(message="heartbeat", version=2, request_id=SEED["request_id"],
                     sent_at_ms=SEED["sent_at_ms"]),
    ),
    # 3
    dict(
        name="heartbeat_ack", file="heartbeat_ack.control.bin", transport="control", direction="server->client",
        build=lambda: relay_frame("heartbeat_ack", msg_heartbeat_ack(
            request_id=SEED["request_id"], server_time_ms=SEED["sent_at_ms"])),
        expects=dict(message="heartbeat_ack", version=2, request_id=SEED["request_id"],
                     server_time_ms=SEED["sent_at_ms"]),
    ),
    # 4
    dict(
        name="discovery_publish", file="discovery_publish.control.bin", transport="control",
        direction="client->server",
        build=lambda: relay_frame("discovery_publish", msg_discovery_publish(
            request_id=SEED["request_id"], snapshot=SNAPSHOT_A)),
        expects=dict(
            message="discovery_publish", version=2, request_id=SEED["request_id"],
            revision=SEED["revision"], transport_capabilities=[1, 2, 6],
            transport_capability_names=_cap_names([1, 2, 6]), candidate_count=2,
            published_at_ms=SEED["published_at_ms"], **_epoch_expect("epoch_high", "epoch_low")),
    ),
    # 5
    dict(
        name="discovery_ack", file="discovery_ack.control.bin", transport="control", direction="server->client",
        build=lambda: relay_frame("discovery_ack", msg_discovery_ack(
            request_id=SEED["request_id"], epoch_high=SEED["epoch_high"],
            epoch_low=SEED["epoch_low"], revision=SEED["revision"])),
        expects=dict(message="discovery_ack", version=2, request_id=SEED["request_id"],
                     revision=SEED["revision"], **_epoch_expect("epoch_high", "epoch_low")),
    ),
    # 6
    dict(
        name="resolve_ready", file="resolve_ready.control.bin", transport="control",
        direction="server->client",
        build=lambda: relay_frame("resolve_peer_response", msg_resolve_peer_response(
            request_id=SEED["request_id"], status=1, discovery=SNAPSHOT_A, retry_after_ms=0)),
        expects=dict(
            message="resolve_peer_response", version=2, request_id=SEED["request_id"],
            status=1, status_name="RESOLVE_STATUS_READY", revision=SEED["revision"],
            **_epoch_expect("epoch_high", "epoch_low")),
    ),
    # 7
    dict(
        name="resolve_offline", file="resolve_offline.control.bin", transport="control",
        direction="server->client",
        build=lambda: relay_frame("resolve_peer_response", msg_resolve_peer_response(
            request_id=SEED["request_id"], status=2, discovery=None, retry_after_ms=0)),
        expects=dict(message="resolve_peer_response", version=2, request_id=SEED["request_id"],
                     status=2, status_name="RESOLVE_STATUS_OFFLINE"),
    ),
    # 8
    dict(
        name="resolve_not_ready", file="resolve_not_ready.control.bin", transport="control",
        direction="server->client",
        build=lambda: relay_frame("resolve_peer_response", msg_resolve_peer_response(
            request_id=SEED["request_id"], status=3, discovery=None,
            retry_after_ms=CONSTANTS["RESOLVE_RETRY_HINT_NOT_READY_MS"])),
        expects=dict(message="resolve_peer_response", version=2, request_id=SEED["request_id"],
                     status=3, status_name="RESOLVE_STATUS_NOT_READY", retry_after_ms=2000),
    ),
    # 9
    dict(
        name="resolve_unknown", file="resolve_unknown.control.bin", transport="control",
        direction="server->client",
        build=lambda: relay_frame("resolve_peer_response", msg_resolve_peer_response(
            request_id=SEED["request_id"], status=4, discovery=None,
            retry_after_ms=CONSTANTS["RESOLVE_RETRY_HINT_UNKNOWN_MS"])),
        expects=dict(message="resolve_peer_response", version=2, request_id=SEED["request_id"],
                     status=4, status_name="RESOLVE_STATUS_UNKNOWN", retry_after_ms=5000),
    ),
    # 10
    dict(
        name="connectivity_offer", file="connectivity_offer.control.bin", transport="control",
        direction="client->server",
        build=lambda: relay_frame("connectivity_offer", msg_connectivity_offer(
            request_id=SEED["request_id"], attempt_id=SEED["attempt_id"],
            initiator_device_id=SEED["device_a"], epoch_high=SEED["epoch_high"],
            epoch_low=SEED["epoch_low"], initiator_revision=SEED["revision"],
            initiator_snapshot=SNAPSHOT_A)),
        expects=dict(
            message="connectivity_offer", version=2, request_id=SEED["request_id"],
            attempt_id=SEED["attempt_id"], initiator_device_id=SEED["device_a"],
            initiator_revision=SEED["revision"], **_epoch_expect("epoch_high", "epoch_low")),
    ),
    # 11
    dict(
        name="connectivity_answer", file="connectivity_answer.control.bin", transport="control",
        direction="server->client",
        build=lambda: relay_frame("connectivity_answer", msg_connectivity_answer(
            request_id=SEED["responder_request_id"], attempt_id=SEED["attempt_id"],
            accepted=True, responder_device_id=SEED["device_b"],
            epoch_high=SEED["responder_epoch_high"], epoch_low=SEED["responder_epoch_low"],
            responder_revision=SEED["responder_revision"], responder_snapshot=SNAPSHOT_B)),
        expects=dict(
            message="connectivity_answer", version=2, request_id=SEED["responder_request_id"],
            attempt_id=SEED["attempt_id"], accepted=True, responder_device_id=SEED["device_b"],
            responder_revision=SEED["responder_revision"],
            **_epoch_expect("responder_epoch_high", "responder_epoch_low")),
    ),
    # 12
    dict(
        name="presence_hint_snapshot", file="presence_hint_snapshot.control.bin", transport="control",
        direction="server->client",
        build=lambda: relay_frame("presence_hint_snapshot", msg_presence_hint_snapshot(
            peers=PEERS, published_at_ms=SEED["published_at_ms"])),
        expects=dict(
            message="presence_hint_snapshot", version=2, peer_count=2,
            published_at_ms=SEED["published_at_ms"],
            peers=[
                dict(device_id=SEED["device_a"], online=True, revision=SEED["revision"],
                     **_epoch_expect("epoch_high", "epoch_low")),
                dict(device_id=SEED["device_b"], online=True, revision=SEED["responder_revision"],
                     **_epoch_expect("responder_epoch_high", "responder_epoch_low")),
            ]),
    ),
    # 13
    dict(
        name="peer_available_hint", file="peer_available_hint.control.bin", transport="control",
        direction="server->client",
        build=lambda: relay_frame("peer_available_hint", msg_peer_available_hint(
            device_id=SEED["device_b"], epoch_high=SEED["responder_epoch_high"],
            epoch_low=SEED["responder_epoch_low"], revision=SEED["responder_revision"])),
        expects=dict(
            message="peer_available_hint", version=2, device_id=SEED["device_b"],
            revision=SEED["responder_revision"],
            **_epoch_expect("responder_epoch_high", "responder_epoch_low")),
    ),
    # 14
    dict(
        name="peer_unavailable_hint", file="peer_unavailable_hint.control.bin", transport="control",
        direction="server->client",
        build=lambda: relay_frame("peer_unavailable_hint", msg_peer_unavailable_hint(
            device_id=SEED["device_b"], reason="device offline")),
        expects=dict(message="peer_unavailable_hint", version=2, device_id=SEED["device_b"],
                     reason="device offline"),
    ),
    # 15
    dict(
        name="relay_reserve_request", file="relay_reserve_request.control.bin", transport="control",
        direction="client->server",
        build=lambda: relay_frame("relay_reserve_request", msg_relay_reserve_request(
            request_id=SEED["request_id"], attempt_id=SEED["attempt_id"],
            target_device_id=SEED["device_b"],
            desired_lifetime_s=CONSTANTS["RESERVATION_LIFETIME_S_DEFAULT"])),
        expects=dict(
            message="relay_reserve_request", version=2, request_id=SEED["request_id"],
            attempt_id=SEED["attempt_id"], target_device_id=SEED["device_b"],
            desired_lifetime_s=60),
    ),
    # 16
    dict(
        name="relay_reserve_response", file="relay_reserve_response.control.bin", transport="control",
        direction="server->client",
        build=lambda: relay_frame("relay_reserve_response", msg_relay_reserve_response(
            request_id=SEED["request_id"], attempt_id=SEED["attempt_id"],
            reservation_id=SEED["reservation_id"], endpoint=ENDPOINT,
            expires_at_ms=SEED["expires_at_ms"], local_token=TOKEN_A)),
        expects=dict(
            message="relay_reserve_response", version=2, request_id=SEED["request_id"],
            attempt_id=SEED["attempt_id"], reservation_id=SEED["reservation_id"],
            relay_data_endpoint=ENDPOINT, expires_at_ms=SEED["expires_at_ms"],
            local_token_hex=TOKEN_A.hex()),
    ),
    # 17
    dict(
        name="incoming_relay_reservation", file="incoming_relay_reservation.control.bin",
        transport="control", direction="server->client",
        build=lambda: relay_frame("incoming_relay_reservation", msg_incoming_relay_reservation(
            attempt_id=SEED["attempt_id"], reservation_id=SEED["reservation_id"],
            initiator_device_id=SEED["device_a"], endpoint=ENDPOINT,
            expires_at_ms=SEED["expires_at_ms"], local_token=TOKEN_B)),
        expects=dict(
            message="incoming_relay_reservation", version=2, attempt_id=SEED["attempt_id"],
            reservation_id=SEED["reservation_id"], initiator_device_id=SEED["device_a"],
            relay_data_endpoint=ENDPOINT, expires_at_ms=SEED["expires_at_ms"],
            local_token_hex=TOKEN_B.hex()),
    ),
    # 18
    dict(
        name="realtime_signal", file="realtime_signal.control.bin", transport="control",
        direction="client->server",
        build=lambda: relay_frame("realtime_signal", msg_realtime_signal(
            request_id=SEED["request_id"], realtime_id=SEED["realtime_id"],
            target_device_id=SEED["device_b"], kind=3, revision=SEED["revision"],
            payload=REALTIME_PAYLOAD)),
        expects=dict(
            message="realtime_signal", version=2, request_id=SEED["request_id"],
            realtime_id=SEED["realtime_id"], target_device_id=SEED["device_b"],
            kind=3, kind_name="REALTIME_SIGNAL_KIND_ICE_CANDIDATE", revision=SEED["revision"],
            payload_hex=REALTIME_PAYLOAD.hex()),
    ),
    # 19
    dict(
        name="protocol_error", file="protocol_error.control.bin", transport="control",
        direction="server->client",
        build=lambda: relay_frame("protocol_error", msg_protocol_error(
            request_id=SEED["request_id"], attempt_id=SEED["attempt_id"], code=7,
            message="revision already published under a different runtime epoch")),
        expects=dict(
            message="protocol_error", version=2, request_id=SEED["request_id"],
            attempt_id=SEED["attempt_id"], code=7, code_name="ERROR_CODE_EPOCH_CONFLICT",
            error_message="revision already published under a different runtime epoch"),
    ),
    # 20
    dict(
        name="relay_data_connect", file="relay_data_connect.data.bin", transport="data",
        direction="client->relay",
        build=lambda: relay_data_frame("connect", msg_relay_data_connect(
            reservation_id=SEED["reservation_id"], local_token=TOKEN_A)),
        expects=dict(
            message="relay_data_connect", version=2, reservation_id=SEED["reservation_id"],
            local_token_hex=TOKEN_A.hex()),
    ),
    # 21
    dict(
        name="relay_data_payload", file="relay_data_payload.data.bin", transport="data",
        direction="peer->relay",
        build=lambda: relay_data_frame("payload", msg_relay_data_payload(
            sequence=SEED["sequence"], encrypted_payload=ENCRYPTED_PAYLOAD)),
        expects=dict(
            message="relay_data_payload", version=2, sequence=SEED["sequence"],
            encrypted_payload_hex=ENCRYPTED_PAYLOAD.hex()),
    ),
    # 22
    dict(
        name="relay_data_close", file="relay_data_close.data.bin", transport="data",
        direction="peer->relay",
        build=lambda: relay_data_frame("close", msg_relay_data_close(reason=0, detail="")),
        expects=dict(message="relay_data_close", version=2, reason=0),
    ),
]

# Ordered full-lifecycle sequence (design §7 session_sequence.golden.json).
SESSION_SEQUENCE = [
    ("ready.control.bin", "server sends Ready on connect"),
    ("heartbeat.control.bin", "client heartbeat"),
    ("heartbeat_ack.control.bin", "server ack echoes request_id"),
    ("discovery_publish.control.bin", "client publishes full discovery snapshot"),
    ("discovery_ack.control.bin", "server CAS ack echoes epoch+revision"),
    ("resolve_ready.control.bin", "resolve returns READY with snapshot"),
    ("connectivity_offer.control.bin", "initiator opens connectivity attempt"),
    ("connectivity_answer.control.bin", "responder accepts, correlates by attempt_id"),
    ("relay_reserve_request.control.bin", "direct failed; reserve relay"),
    ("relay_reserve_response.control.bin", "reservation issued to initiator"),
    ("incoming_relay_reservation.control.bin", "reservation pushed to responder"),
    ("relay_data_connect.data.bin", "both endpoints connect the data plane"),
    ("relay_data_payload.data.bin", "first encrypted payload"),
    ("relay_data_payload.data.bin", "second encrypted payload (re-uses sequence=42 fixture; live flows increment sequence)"),
    ("relay_data_close.data.bin", "normal close"),
]


def build_manifest():
    seed = dict(SEED)
    for key in ("epoch_high", "epoch_low", "responder_epoch_high", "responder_epoch_low"):
        seed[key] = "0x%08x" % seed[key]
    return {
        "schema_version": SCHEMA_VERSION,
        "title": "relay v2 golden fixture manifest",
        "constants": CONSTANTS,
        "seed": seed,
        "enums": ENUMS,
        "fixtures": [
            {
                "name": fx["name"],
                "file": fx["file"],
                "transport": fx["transport"],
                "direction": fx["direction"],
                "expects": fx["expects"],
            }
            for fx in FIXTURES
        ],
    }


def build_session_sequence():
    return {
        "schema_version": SCHEMA_VERSION,
        "title": "relay v2 full-lifecycle golden sequence",
        "sequence": [
            {"step": i + 1, "file": name, "note": note}
            for i, (name, note) in enumerate(SESSION_SEQUENCE)
        ],
    }


def generated_files():
    files = {}
    for fx in FIXTURES:
        pb = fx["build"]()
        files[fx["file"]] = frame(pb)
    files["manifest.json"] = json.dumps(build_manifest(), indent=2, sort_keys=True,
                                        ensure_ascii=False).encode("utf-8") + b"\n"
    files["session_sequence.golden.json"] = json.dumps(
        build_session_sequence(), indent=2, sort_keys=True, ensure_ascii=False).encode("utf-8") + b"\n"
    return files


def main():
    check_only = "--check" in sys.argv
    files = generated_files()
    if len(FIXTURES) != 22:
        print("error: expected 22 fixtures, got %d" % len(FIXTURES), file=sys.stderr)
        return 1
    if check_only:
        ok = True
        for name, data in files.items():
            path = os.path.join(ROOT, name)
            if not os.path.exists(path):
                print("missing: %s" % name, file=sys.stderr)
                ok = False
            elif open(path, "rb").read() != data:
                print("drift: %s" % name, file=sys.stderr)
                ok = False
        if not ok:
            print("fixtures are NOT current; run generate_fixtures.py --regenerate", file=sys.stderr)
            return 1
        print("fixtures current: %d files, %d fixtures" % (len(files), len(FIXTURES)))
        return 0
    for name, data in files.items():
        path = os.path.join(ROOT, name)
        with open(path, "wb") as f:
            f.write(data)
        print("wrote %s (%d bytes)" % (name, len(data)))
    print("regenerated %d files (%d fixtures)" % (len(files), len(FIXTURES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
