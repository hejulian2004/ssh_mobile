// Package v2 implements the Go codec for the transport-network v2 relay wire
// contract, frozen in protocol/proto/relay/v2/relay_v2.proto.
//
// Both routes share one framing rule:
//
//	WS Binary payload == [4-byte big-endian length][protobuf]
//	Exactly ONE message per WS frame; length MUST equal len(frame) - 4.
//
// /v2/control frames decode to RelayFrame; /v2/relay/{reservation_id} frames
// decode to RelayDataFrame. A RelayDataFrame on /v2/control (or a RelayFrame on
// /v2/relay) is a protocol violation and closes the connection.
//
// The golden fixtures in protocol/relay_v2_testdata/ are the ground truth:
// relay_v2.pb.go is generated from the frozen .proto and must round-trip every
// fixture byte-for-byte. Do not hand-edit the generated file.
package v2

import (
	"encoding/binary"
	"errors"
	"fmt"

	"google.golang.org/protobuf/proto"
)

// Centralized constants — mirror protocol/proto/relay/v2/relay_v2.proto and
// protocol/relay_v2_testdata/manifest.json exactly. No magic numbers anywhere
// else; codec_test.go asserts these values against the manifest.
const (
	// RELAY_V2_VERSION is the only version accepted in RelayFrame/RelayDataFrame.
	RELAY_V2_VERSION = 2
	// FRAME_LENGTH_PREFIX_BYTES is the size of the big-endian length prefix.
	FRAME_LENGTH_PREFIX_BYTES = 4
	// MAX_RELAY_FRAME_BYTES is the largest accepted /v2/control frame (prefix + protobuf).
	MAX_RELAY_FRAME_BYTES = FRAME_LENGTH_PREFIX_BYTES + 512*1024
	// MAX_RELAY_DATA_FRAME_BYTES is the largest accepted /v2/relay frame.
	MAX_RELAY_DATA_FRAME_BYTES = FRAME_LENGTH_PREFIX_BYTES + 512*1024

	// MAX_DEVICE_ID_BYTES is the maximum device id length (UTF-8 bytes).
	MAX_DEVICE_ID_BYTES = 128
	// MAX_ATTEMPT_ID_BYTES is the maximum async-attempt correlation key length.
	MAX_ATTEMPT_ID_BYTES = 128
	// MAX_REALTIME_ID_BYTES is the maximum realtime session id length.
	MAX_REALTIME_ID_BYTES = 128
	// MAX_REALTIME_SIGNAL_PAYLOAD_BYTES is the maximum RealtimeSignal payload size.
	MAX_REALTIME_SIGNAL_PAYLOAD_BYTES = 256 * 1024
	// MAX_DISCOVERY_CANDIDATES caps CandidateBundle.candidates.
	MAX_DISCOVERY_CANDIDATES = 64
	// MAX_DISCOVERY_CANDIDATE_BYTES caps each opaque candidate blob.
	MAX_DISCOVERY_CANDIDATE_BYTES = 4096
	// MAX_DISCOVERY_CAPABILITIES caps repeated TransportCapability.
	MAX_DISCOVERY_CAPABILITIES = 64

	// RESERVATION_ID_BYTES is the raw reservation id size (16 bytes).
	RESERVATION_ID_BYTES = 16
	// RESERVATION_ID_HEX_CHARS is the hex-encoded reservation id length (32 chars).
	RESERVATION_ID_HEX_CHARS = 2 * RESERVATION_ID_BYTES
	// RESERVATION_TOKEN_BYTES is the length of reservation connect tokens.
	RESERVATION_TOKEN_BYTES = 32

	// HEARTBEAT_INTERVAL_S is the server-enforced heartbeat period (seconds).
	HEARTBEAT_INTERVAL_S = 20
	// PRESENCE_TTL_S is the presence lease TTL (seconds).
	PRESENCE_TTL_S = 60
	// SERVER_HEARTBEAT_MISSES_BEFORE_CLOSE is the missed-heartbeat close threshold.
	SERVER_HEARTBEAT_MISSES_BEFORE_CLOSE = 2
	// RESERVATION_LIFETIME_S_DEFAULT is the default reservation lifetime; the server
	// clamps requests to [15, 120].
	RESERVATION_LIFETIME_S_DEFAULT = 60
	// RESERVATION_EXPIRY_GRACE_S is the grace applied before the relay force-closes
	// an expired reservation.
	RESERVATION_EXPIRY_GRACE_S = 5
	// RESOLVE_RETRY_HINT_NOT_READY_MS is the retry hint for NOT_READY resolves.
	RESOLVE_RETRY_HINT_NOT_READY_MS = 2000
	// RESOLVE_RETRY_HINT_UNKNOWN_MS is the retry hint for UNKNOWN resolves.
	RESOLVE_RETRY_HINT_UNKNOWN_MS = 5000
	// DIRECT_CONNECT_WINDOW_MS is the fixed direct-connect window; not carried on
	// the wire.
	DIRECT_CONNECT_WINDOW_MS = 4000
)

// Sentinel causes for frame-protocol violations. Decode functions wrap these in
// *FrameError carrying the wire ErrorCode a peer should be notified with.
var (
	// ErrFrameTooShort means the buffer is smaller than the length prefix.
	ErrFrameTooShort = errors.New("frame shorter than length prefix")
	// ErrLengthMismatch means the prefix length does not equal len(frame) - 4.
	ErrLengthMismatch = errors.New("length prefix does not match frame size")
	// ErrFrameTooLarge means the frame exceeds the route's maximum size.
	ErrFrameTooLarge = errors.New("frame exceeds maximum size")
	// ErrBadVersion means RelayFrame/RelayDataFrame.version != RELAY_V2_VERSION.
	ErrBadVersion = errors.New("unsupported protocol version")
	// ErrMalformedProto means the protobuf payload failed to parse.
	ErrMalformedProto = errors.New("malformed protobuf payload")
	// ErrInvalidBounds means a field violates a frozen size/value bound.
	ErrInvalidBounds = errors.New("field violates protocol bounds")
)

// FrameError is a frame-protocol violation with the unified wire ErrorCode
// (§33 of the design) a peer should be notified with.
type FrameError struct {
	Code ErrorCode
	Err  error
}

func (e *FrameError) Error() string {
	if e.Err == nil {
		return "v2: " + e.Code.String()
	}
	return "v2: " + e.Code.String() + ": " + e.Err.Error()
}

func (e *FrameError) Unwrap() error { return e.Err }

func frameError(code ErrorCode, err error) *FrameError {
	return &FrameError{Code: code, Err: err}
}

// ErrorCodeOf returns the wire ErrorCode associated with a codec error, or
// ErrorCode_ERROR_CODE_UNSPECIFIED if err is nil or not a frame-protocol violation.
func ErrorCodeOf(err error) ErrorCode {
	if err == nil {
		return ErrorCode_ERROR_CODE_UNSPECIFIED
	}
	var fe *FrameError
	if errors.As(err, &fe) {
		return fe.Code
	}
	return ErrorCode_ERROR_CODE_UNSPECIFIED
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

// EncodeFrame serializes a control-plane message into a complete /v2/control WS
// Binary frame: 4-byte big-endian length prefix + canonical protobuf. It
// rejects non-v2 versions and frames larger than MAX_RELAY_FRAME_BYTES.
func EncodeFrame(msg *RelayFrame) ([]byte, error) {
	if msg == nil {
		return nil, errors.New("v2: cannot encode nil relay frame")
	}
	if msg.Version != RELAY_V2_VERSION {
		return nil, frameError(ErrorCode_ERROR_CODE_PROTOCOL, fmt.Errorf("%w: got %d, want %d", ErrBadVersion, msg.Version, RELAY_V2_VERSION))
	}
	return encodeFrame(msg, MAX_RELAY_FRAME_BYTES)
}

// EncodeDataFrame serializes a relay-data-plane message into a complete
// /v2/relay/{reservation_id} WS Binary frame. It rejects non-v2 versions and
// frames larger than MAX_RELAY_DATA_FRAME_BYTES.
func EncodeDataFrame(msg *RelayDataFrame) ([]byte, error) {
	if msg == nil {
		return nil, errors.New("v2: cannot encode nil relay data frame")
	}
	if msg.Version != RELAY_V2_VERSION {
		return nil, frameError(ErrorCode_ERROR_CODE_PROTOCOL, fmt.Errorf("%w: got %d, want %d", ErrBadVersion, msg.Version, RELAY_V2_VERSION))
	}
	return encodeFrame(msg, MAX_RELAY_DATA_FRAME_BYTES)
}

func encodeFrame(msg proto.Message, maxFrameBytes int) ([]byte, error) {
	pb, err := proto.Marshal(msg)
	if err != nil {
		return nil, fmt.Errorf("v2: marshal: %w", err)
	}
	if len(pb)+FRAME_LENGTH_PREFIX_BYTES > maxFrameBytes {
		return nil, frameError(ErrorCode_ERROR_CODE_FRAME_TOO_LARGE, fmt.Errorf("%w: %d bytes", ErrFrameTooLarge, len(pb)+FRAME_LENGTH_PREFIX_BYTES))
	}
	frame := make([]byte, FRAME_LENGTH_PREFIX_BYTES+len(pb))
	binary.BigEndian.PutUint32(frame[:FRAME_LENGTH_PREFIX_BYTES], uint32(len(pb)))
	copy(frame[FRAME_LENGTH_PREFIX_BYTES:], pb)
	return frame, nil
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

// DecodeControl decodes a complete /v2/control WS Binary frame into a
// RelayFrame. It validates the length prefix, the route maximum size, that
// RelayFrame.version == RELAY_V2_VERSION, and the frozen per-message field
// bounds. Unknown oneof tags are skipped per proto3 forward compatibility.
func DecodeControl(frame []byte) (*RelayFrame, error) {
	pb, err := stripPrefix(frame, MAX_RELAY_FRAME_BYTES)
	if err != nil {
		return nil, err
	}
	var msg RelayFrame
	if err := proto.Unmarshal(pb, &msg); err != nil {
		return nil, frameError(ErrorCode_ERROR_CODE_MALFORMED_FRAME, fmt.Errorf("%w: %v", ErrMalformedProto, err))
	}
	if msg.Version != RELAY_V2_VERSION {
		return nil, frameError(ErrorCode_ERROR_CODE_PROTOCOL, fmt.Errorf("%w: got %d, want %d", ErrBadVersion, msg.Version, RELAY_V2_VERSION))
	}
	if err := ValidateControl(&msg); err != nil {
		return nil, err
	}
	return &msg, nil
}

// DecodeData decodes a complete /v2/relay/{reservation_id} WS Binary frame into
// a RelayDataFrame with the same framing/version/bounds validation as
// DecodeControl, but against MAX_RELAY_DATA_FRAME_BYTES.
func DecodeData(frame []byte) (*RelayDataFrame, error) {
	pb, err := stripPrefix(frame, MAX_RELAY_DATA_FRAME_BYTES)
	if err != nil {
		return nil, err
	}
	var msg RelayDataFrame
	if err := proto.Unmarshal(pb, &msg); err != nil {
		return nil, frameError(ErrorCode_ERROR_CODE_MALFORMED_FRAME, fmt.Errorf("%w: %v", ErrMalformedProto, err))
	}
	if msg.Version != RELAY_V2_VERSION {
		return nil, frameError(ErrorCode_ERROR_CODE_PROTOCOL, fmt.Errorf("%w: got %d, want %d", ErrBadVersion, msg.Version, RELAY_V2_VERSION))
	}
	if err := ValidateDataFrame(&msg); err != nil {
		return nil, err
	}
	return &msg, nil
}

// stripPrefix validates the length-prefix framing and returns the protobuf
// payload. It enforces the prefix size, the route maximum, and that the prefix
// length equals len(frame) - 4.
func stripPrefix(frame []byte, maxFrameBytes int) ([]byte, error) {
	if len(frame) < FRAME_LENGTH_PREFIX_BYTES {
		return nil, frameError(ErrorCode_ERROR_CODE_MALFORMED_FRAME, fmt.Errorf("%w: got %d bytes", ErrFrameTooShort, len(frame)))
	}
	if len(frame) > maxFrameBytes {
		return nil, frameError(ErrorCode_ERROR_CODE_FRAME_TOO_LARGE, fmt.Errorf("%w: got %d bytes", ErrFrameTooLarge, len(frame)))
	}
	length := binary.BigEndian.Uint32(frame[:FRAME_LENGTH_PREFIX_BYTES])
	if int(length) != len(frame)-FRAME_LENGTH_PREFIX_BYTES {
		return nil, frameError(ErrorCode_ERROR_CODE_MALFORMED_FRAME, fmt.Errorf("%w: prefix %d, frame payload %d", ErrLengthMismatch, length, len(frame)-FRAME_LENGTH_PREFIX_BYTES))
	}
	return frame[FRAME_LENGTH_PREFIX_BYTES:], nil
}

// ---------------------------------------------------------------------------
// Bounds validation (frozen contract)
// ---------------------------------------------------------------------------

// ValidateControl enforces the per-message size bounds of the frozen contract
// on a decoded control frame: device/attempt/realtime id lengths, realtime
// signal payload size, discovery candidate and capability caps, and
// reservation id/token sizes. It returns nil when the frame is within bounds.
func ValidateControl(msg *RelayFrame) error {
	if msg == nil {
		return errors.New("v2: nil relay frame")
	}
	switch k := msg.Kind.(type) {
	case *RelayFrame_Ready:
		return checkMax("device_id", len(k.Ready.DeviceId), MAX_DEVICE_ID_BYTES)
	case *RelayFrame_DiscoveryPublish:
		return validateSnapshot(k.DiscoveryPublish.Snapshot)
	case *RelayFrame_ResolvePeerRequest:
		return checkMax("target_device_id", len(k.ResolvePeerRequest.TargetDeviceId), MAX_DEVICE_ID_BYTES)
	case *RelayFrame_ResolvePeerResponse:
		return validateSnapshot(k.ResolvePeerResponse.Discovery)
	case *RelayFrame_ConnectivityOffer:
		o := k.ConnectivityOffer
		if err := checkMax("attempt_id", len(o.AttemptId), MAX_ATTEMPT_ID_BYTES); err != nil {
			return err
		}
		if err := checkMax("initiator_device_id", len(o.InitiatorDeviceId), MAX_DEVICE_ID_BYTES); err != nil {
			return err
		}
		return validateSnapshot(o.InitiatorSnapshot)
	case *RelayFrame_ConnectivityAnswer:
		a := k.ConnectivityAnswer
		if err := checkMax("attempt_id", len(a.AttemptId), MAX_ATTEMPT_ID_BYTES); err != nil {
			return err
		}
		if err := checkMax("responder_device_id", len(a.ResponderDeviceId), MAX_DEVICE_ID_BYTES); err != nil {
			return err
		}
		return validateSnapshot(a.ResponderSnapshot)
	case *RelayFrame_PresenceHintSnapshot:
		for i, p := range k.PresenceHintSnapshot.Peers {
			if err := checkMax(fmt.Sprintf("peers[%d].device_id", i), len(p.DeviceId), MAX_DEVICE_ID_BYTES); err != nil {
				return err
			}
		}
		return nil
	case *RelayFrame_PeerAvailableHint:
		return checkMax("device_id", len(k.PeerAvailableHint.DeviceId), MAX_DEVICE_ID_BYTES)
	case *RelayFrame_PeerUnavailableHint:
		return checkMax("device_id", len(k.PeerUnavailableHint.DeviceId), MAX_DEVICE_ID_BYTES)
	case *RelayFrame_RelayReserveRequest:
		r := k.RelayReserveRequest
		if err := checkMax("attempt_id", len(r.AttemptId), MAX_ATTEMPT_ID_BYTES); err != nil {
			return err
		}
		return checkMax("target_device_id", len(r.TargetDeviceId), MAX_DEVICE_ID_BYTES)
	case *RelayFrame_RelayReserveResponse:
		r := k.RelayReserveResponse
		if err := checkMax("attempt_id", len(r.AttemptId), MAX_ATTEMPT_ID_BYTES); err != nil {
			return err
		}
		if err := checkLen("reservation_id", len(r.ReservationId), RESERVATION_ID_HEX_CHARS); err != nil {
			return err
		}
		return checkLen("local_token", len(r.LocalToken), RESERVATION_TOKEN_BYTES)
	case *RelayFrame_IncomingRelayReservation:
		r := k.IncomingRelayReservation
		if err := checkMax("attempt_id", len(r.AttemptId), MAX_ATTEMPT_ID_BYTES); err != nil {
			return err
		}
		if err := checkMax("initiator_device_id", len(r.InitiatorDeviceId), MAX_DEVICE_ID_BYTES); err != nil {
			return err
		}
		if err := checkLen("reservation_id", len(r.ReservationId), RESERVATION_ID_HEX_CHARS); err != nil {
			return err
		}
		return checkLen("local_token", len(r.LocalToken), RESERVATION_TOKEN_BYTES)
	case *RelayFrame_RealtimeSignal:
		s := k.RealtimeSignal
		if err := checkMax("realtime_id", len(s.RealtimeId), MAX_REALTIME_ID_BYTES); err != nil {
			return err
		}
		if err := checkMax("target_device_id", len(s.TargetDeviceId), MAX_DEVICE_ID_BYTES); err != nil {
			return err
		}
		if err := checkMax("source_device_id", len(s.SourceDeviceId), MAX_DEVICE_ID_BYTES); err != nil {
			return err
		}
		return checkMax("payload", len(s.Payload), MAX_REALTIME_SIGNAL_PAYLOAD_BYTES)
	case *RelayFrame_ProtocolError:
		return checkMax("attempt_id", len(k.ProtocolError.AttemptId), MAX_ATTEMPT_ID_BYTES)
	default:
		// Empty or unknown-kind frames carry no bound-checkable fields.
		return nil
	}
}

// ValidateDataFrame enforces the frozen data-plane bounds on a decoded
// RelayDataFrame.
func ValidateDataFrame(msg *RelayDataFrame) error {
	if msg == nil {
		return errors.New("v2: nil relay data frame")
	}
	switch k := msg.Kind.(type) {
	case *RelayDataFrame_Connect:
		c := k.Connect
		if err := checkLen("reservation_id", len(c.ReservationId), RESERVATION_ID_HEX_CHARS); err != nil {
			return err
		}
		return checkLen("local_token", len(c.LocalToken), RESERVATION_TOKEN_BYTES)
	default:
		// RelayDataPayload is bounded by the frame maximum (checked during
		// framing); RelayDataAck/RelayDataClose carry no size-bounded fields.
		return nil
	}
}

func validateSnapshot(s *DiscoverySnapshot) error {
	if s == nil {
		return nil
	}
	if err := checkMax("transport_capabilities", len(s.TransportCapabilities), MAX_DISCOVERY_CAPABILITIES); err != nil {
		return err
	}
	if s.CandidateBundle == nil {
		return nil
	}
	if err := checkMax("candidates", len(s.CandidateBundle.Candidates), MAX_DISCOVERY_CANDIDATES); err != nil {
		return err
	}
	for i, c := range s.CandidateBundle.Candidates {
		if err := checkMax(fmt.Sprintf("candidates[%d]", i), len(c), MAX_DISCOVERY_CANDIDATE_BYTES); err != nil {
			return err
		}
	}
	return nil
}

func checkMax(what string, got, max int) error {
	if got > max {
		return frameError(ErrorCode_ERROR_CODE_PROTOCOL, fmt.Errorf("%w: %s has %d bytes, max %d", ErrInvalidBounds, what, got, max))
	}
	return nil
}

func checkLen(what string, got, want int) error {
	if got != want {
		return frameError(ErrorCode_ERROR_CODE_PROTOCOL, fmt.Errorf("%w: %s has %d bytes, want %d", ErrInvalidBounds, what, got, want))
	}
	return nil
}

// ---------------------------------------------------------------------------
// Kind helpers
// ---------------------------------------------------------------------------

// KindName returns the canonical wire message name for the control frame's
// oneof kind ("ready", "heartbeat", ...), or "" when no kind is set.
func KindName(msg *RelayFrame) string {
	if msg == nil {
		return ""
	}
	switch msg.Kind.(type) {
	case *RelayFrame_Ready:
		return "ready"
	case *RelayFrame_Heartbeat:
		return "heartbeat"
	case *RelayFrame_HeartbeatAck:
		return "heartbeat_ack"
	case *RelayFrame_DiscoveryPublish:
		return "discovery_publish"
	case *RelayFrame_DiscoveryAck:
		return "discovery_ack"
	case *RelayFrame_ResolvePeerRequest:
		return "resolve_peer_request"
	case *RelayFrame_ResolvePeerResponse:
		return "resolve_peer_response"
	case *RelayFrame_ConnectivityOffer:
		return "connectivity_offer"
	case *RelayFrame_ConnectivityAnswer:
		return "connectivity_answer"
	case *RelayFrame_PresenceHintSnapshot:
		return "presence_hint_snapshot"
	case *RelayFrame_PeerAvailableHint:
		return "peer_available_hint"
	case *RelayFrame_PeerUnavailableHint:
		return "peer_unavailable_hint"
	case *RelayFrame_RelayReserveRequest:
		return "relay_reserve_request"
	case *RelayFrame_RelayReserveResponse:
		return "relay_reserve_response"
	case *RelayFrame_IncomingRelayReservation:
		return "incoming_relay_reservation"
	case *RelayFrame_RealtimeSignal:
		return "realtime_signal"
	case *RelayFrame_ProtocolError:
		return "protocol_error"
	default:
		return ""
	}
}

// DataKindName returns the canonical wire message name for a relay-data frame's
// oneof kind ("relay_data_connect", ...), or "" when no kind is set.
func DataKindName(msg *RelayDataFrame) string {
	if msg == nil {
		return ""
	}
	switch msg.Kind.(type) {
	case *RelayDataFrame_Connect:
		return "relay_data_connect"
	case *RelayDataFrame_Payload:
		return "relay_data_payload"
	case *RelayDataFrame_Ack:
		return "relay_data_ack"
	case *RelayDataFrame_Close:
		return "relay_data_close"
	default:
		return ""
	}
}
