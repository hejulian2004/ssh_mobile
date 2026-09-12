// v2 Relay 控制面（GET /v2/control，设计 §24/§32/§33）。
//
// 控制面连接是一条长期存活的 WebSocket，只承载 protobuf 二进制 RelayFrame（每帧 =
// [4-byte BE 长度][RelayFrame]，codec.DecodeControl）。它复用 hub 的 peer 表与
// presence 租约：/v2/control 连接经 hub.add 入表、占据设备 presence 租约、受服务端
// 心跳监视器与 sweeper 管辖。控制面纯净性：RelayDataFrame 错投到这条路由是协议违规
// 并关闭；proto3 未知 oneof tag 按冻结契约跳过，解码成空 kind 时保持连接以兼容未来 tag。
//
// 每条控制面连接的帧分派见 routeControlV2。服务端→客户端的方向性消息（Ready/
// HeartbeatAck/DiscoveryAck/ResolvePeerResponse/RelayReserveResponse/
// IncomingRelayReservation，以及 PresenceHintSnapshot/PeerAvailableHint/
// PeerUnavailableHint 三帧 presence 提示）若由客户端反向发送，一律按控制面纯净性判
// 协议违规——回一帧 ProtocolError 后关闭连接，绝不原样广播。

package relay

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/gorilla/websocket"
	"google.golang.org/protobuf/proto"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

// v2AttemptLifetime 是 v2Attempt 路由注册表条目的存活上限：覆盖一次 ConnectivityAttempt
// 的完整 offer→answer 窗口（设计 §12 单次 attempt 一次性状态）。
const v2AttemptLifetime = 30 * time.Second

// v2Attempt 记录一条已转发的 ConnectivityOffer 的发起方，供 ConnectivityAnswer /
// ProtocolError 按 attempt_id 回路由。条目带过期时间，由 hub.prune 惰性清理。
type v2Attempt struct {
	initiator string
	// Connection IDs bind the complete offer/answer cycle to the two control
	// sockets that were READY when the offer was forwarded.  A reconnect of
	// either device must not be able to consume a late answer from the previous
	// generation.
	initiatorConnectionID string
	// target is the authenticated device that received the offer.  Answers and
	// attempt-scoped errors are accepted only from this device; an arbitrary
	// authenticated peer must not be able to consume or poison an attempt.
	target             string
	targetConnectionID string
	expiresAt          time.Time
}

// ---------------------------------------------------------------------------
// HTTP：GET /v2/control
// ---------------------------------------------------------------------------

// connectControlV2 处理 /v2/control 升级：bearer 认证（authenticatedRequest），
// 升级后服务端先发 Ready（protocol_version=2 + heartbeat/ttl 等），随后按 v2 控制面
// 读循环运行。Ready 在 hub.add 之前入队，保证它是客户端收到的第一帧。
func (s *Server) connectControlV2(w http.ResponseWriter, r *http.Request) {
	claims, publicKey, code, ok := s.authenticatedRequest(r)
	if !ok {
		retry := retryUnspecified
		if code == relayErrorCredentialExpired {
			retry = retryRefreshCredentialThenRetry
		}
		writeNetworkErrorRetry(w, http.StatusUnauthorized, code,
			"Relay control-plane authentication failed.", "connect_relay_v2", "", retry, 0)
		return
	}
	admission, admissionCode, admitted := s.admitAuthenticatedDevice(r.Context(), claims, publicKey)
	if !admitted {
		retry := retryUnspecified
		if admissionCode == relayErrorCredentialExpired {
			retry = retryRefreshCredentialThenRetry
		}
		writeNetworkErrorRetry(w, http.StatusUnauthorized, admissionCode,
			"Relay control-plane authentication failed.", "connect_relay_v2", "", retry, 0)
		return
	}
	// Keep the admission lock only until the upgraded socket is registered. A
	// long-lived control connection must not block revoke/re-enroll forever;
	// once hub.add has recorded the socket, revoke can find and close it.
	defer func() {
		if admission != nil {
			admission.release()
		}
	}()
	connection, err := s.upgradeWithinContext(admission.ctx, w, r)
	if err != nil {
		return
	}
	peer := &peer{
		deviceID:             claims.DeviceID,
		connectionID:         hex.EncodeToString(randomBytes(12)),
		enrollmentGeneration: claims.EnrollmentGeneration,
		socket:               connection,
		outbound:             make(chan outboundFrame, s.config.MaxPendingFramesPerDevice),
		done:                 make(chan struct{}),
		maxPendingFrames:     s.config.MaxPendingFramesPerDevice,
		maxPendingBytes:      s.config.MaxPendingBytesPerDevice,
		maxFramesPerSecond:   s.config.MaxFramesPerSecondPerDevice,
		maxBytesPerSecond:    s.config.MaxBytesPerSecondPerDevice,
		remoteAddr:           clientRemoteAddr(r, s.config.TrustedProxyCIDRs),
		relayHost:            r.Host,
	}
	presenceTTLSeconds := uint32(s.config.PresenceTTL / time.Second)
	if presenceTTLSeconds == 0 {
		presenceTTLSeconds = 1
	}
	ready, err := v2.EncodeFrame(&v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_Ready{Ready: &v2.Ready{
			ProtocolVersion:    v2.RELAY_V2_VERSION,
			DeviceId:           claims.DeviceID,
			ServerTimeMs:       time.Now().UnixMilli(),
			HeartbeatIntervalS: v2.HEARTBEAT_INTERVAL_S,
			PresenceTtlS:       presenceTTLSeconds,
		}},
	})
	if err != nil {
		_ = connection.Close()
		return
	}
	// 先入队 Ready 再 add：write goroutine 从 outbound 先写它，客户端收到的第一帧
	// 一定是 Ready（随后任何 heartbeat ack 都在它之后）。
	if !peer.enqueue(outboundFrame{websocket.BinaryMessage, ready}) {
		_ = connection.Close()
		return
	}
	if !s.hub.stageWithContext(admission.ctx, peer) {
		_ = connection.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "connection limit"), time.Now().Add(time.Second))
		_ = connection.Close()
		return
	}
	_, enrollmentCurrent := s.enrollmentClaimsCurrent(admission.ctx, claims, publicKey)
	if !enrollmentCurrent || !s.hub.controlLeaseCurrentV2WithinContext(admission.ctx, peer) {
		// hub.add historically kept a socket alive when the shared lease store
		// failed.  A control connection without an authoritative presence lease
		// is not safe to use for Resolve, signaling, or reservation admission.
		// The workers remain behind their activation barrier, so neither Ready nor
		// a client frame can cross the failed admission decision.
		s.hub.sendV2ProtocolErrorSync(peer, 0, v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE, "control lease unavailable")
		s.hub.disconnectConnection(peer.deviceID, peer.connectionID)
		return
	}
	if !s.hub.activate(peer) {
		return
	}
	admission.release()
	admission = nil
	// Presence hints are advisory, but a newly connected control client needs a
	// complete current view rather than waiting for the next edge-triggered
	// event.  Ready remains the first frame; add() has already queued it before
	// this snapshot is enqueued.
	s.hub.sendPresenceHintSnapshotV2(peer)
}

// controlLeaseCurrentV2 verifies the authoritative presence owner after hub.add
// admits a control socket.  The check closes the admission gap where a backend
// error could otherwise leave an in-memory peer routable without a lease.
func (h *hub) controlLeaseCurrentV2(peer *peer) bool {
	return h.controlLeaseCurrentV2WithinContext(context.Background(), peer)
}

func (h *hub) controlLeaseCurrentV2WithinContext(parent context.Context, peer *peer) bool {
	if h.presence == nil || peer == nil {
		return false
	}
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, presenceLeaseTimeout)
	presence, ok, err := h.presence.GetPresence(ctx, peer.deviceID)
	cancel()
	return err == nil && ok && presence.ConnectionID == peer.connectionID
}

// ---------------------------------------------------------------------------
// 帧分派
// ---------------------------------------------------------------------------

// routeControlV2 解码并分派一条 /v2/control 二进制帧。返回 false 表示应关闭连接
// （帧级协议违规）。解码/版本/边界违规先用同步写冲刷一帧 ProtocolError 再关闭——
// 不能走 outbound 异步队列，否则 read goroutine 的 defer closePeer 会在 write
// goroutine 冲刷前关掉 socket，ProtocolError 丢失。
func (h *hub) routeControlV2(sender *peer, data []byte) bool {
	if sender == nil {
		return false
	}
	select {
	case <-sender.done:
		// A socket selected for shutdown must not dispatch a frame that was
		// already buffered in Gorilla before Close interrupted the reader.
		return false
	default:
	}
	// 每帧重核 currency（v1 routeControl 的同款守卫）：被取代/撤销的控制连接，其 read
	// goroutine 仍可能读到一帧在途数据（closePeer 之后、socket 关闭之前）。若不拦截，
	// 这条陈旧连接仍能分派 ConnectivityOffer/RelayReserveRequest/RealtimeSignal。
	// 返回 false 让 hub.read 关闭这条连接。速率限制检查在其后（两者都保留）。
	h.mutex.Lock()
	isCurrent := h.peers[sender.deviceID] == sender
	h.mutex.Unlock()
	if !isCurrent {
		return false
	}
	if !sender.allowFrame(len(data)) {
		h.sendV2ProtocolErrorSync(sender, 0, v2.ErrorCode_ERROR_CODE_RATE_LIMITED, "control frame rate limit exceeded")
		return false
	}
	frame, err := v2.DecodeControl(data)
	if err != nil {
		code := v2.ErrorCodeOf(err)
		if code == v2.ErrorCode_ERROR_CODE_UNSPECIFIED {
			code = v2.ErrorCode_ERROR_CODE_MALFORMED_FRAME
		}
		h.sendV2ProtocolErrorSync(sender, 0, code, err.Error())
		return false
	}
	if frame.Kind == nil {
		// proto3 unknown oneof tags are intentionally skipped by the frozen
		// contract.  There is no way to distinguish such a forward-compatible
		// frame from an empty oneof after decoding, so ignore it rather than
		// turning a future message into a connection failure.
		return true
	}
	if requestID, err := validateV2ClientRequest(frame); err != nil {
		h.sendV2ProtocolErrorSync(sender, requestID, v2.ErrorCode_ERROR_CODE_PROTOCOL, err.Error())
		return false
	}
	switch kind := frame.Kind.(type) {
	case *v2.RelayFrame_Heartbeat:
		h.handleHeartbeatV2(sender, kind.Heartbeat)
	case *v2.RelayFrame_DiscoveryPublish:
		h.handleDiscoveryPublishV2(sender, kind.DiscoveryPublish)
	case *v2.RelayFrame_ResolvePeerRequest:
		h.handleResolvePeerRequestV2(sender, kind.ResolvePeerRequest)
	case *v2.RelayFrame_ConnectivityOffer:
		h.handleConnectivityOfferV2(sender, kind.ConnectivityOffer)
	case *v2.RelayFrame_ConnectivityAnswer:
		h.handleConnectivityAnswerV2(sender, kind.ConnectivityAnswer)
	case *v2.RelayFrame_PresenceHintSnapshot, *v2.RelayFrame_PeerAvailableHint, *v2.RelayFrame_PeerUnavailableHint:
		// PresenceHintSnapshot/PeerAvailableHint/PeerUnavailableHint 都是服务端→客户端
		// 方向（服务端由 broadcastPeerHintV2 从权威 presence/discovery 状态构造）。
		// 已认证的客户端反向原样发送这些帧，可伪装任意设备的在线/离线提示广播给整个
		// fleet，因此按控制面纯净性同其它服务端方向帧一样判违规并关闭连接。
		h.sendV2ProtocolErrorSync(sender, 0, v2.ErrorCode_ERROR_CODE_PROTOCOL,
			"client must not send server-direction control frames")
		return false
	case *v2.RelayFrame_RelayReserveRequest:
		h.handleRelayReserveRequestV2(sender, kind.RelayReserveRequest)
	case *v2.RelayFrame_RealtimeSignal:
		h.handleRealtimeSignalV2(sender, kind.RealtimeSignal)
	case *v2.RelayFrame_ProtocolError:
		h.handleProtocolErrorV2(sender, frame)
	default:
		// Ready/HeartbeatAck/DiscoveryAck/ResolvePeerResponse/RelayReserveResponse/
		// IncomingRelayReservation 都是服务端→客户端方向，合法的 v2 客户端绝不会反向
		// 发送。这些 oneof tag（尤其 10/12）与 RelayDataFrame 的 connect/ack 重叠——
		// 数据面帧被错投到控制面会伪装成这些方向帧，因此按控制面纯净性直接判违规关闭。
		h.sendV2ProtocolErrorSync(sender, 0, v2.ErrorCode_ERROR_CODE_PROTOCOL,
			"client must not send server-direction control frames")
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// 消息处理
// ---------------------------------------------------------------------------

// handleHeartbeatV2 刷新服务端心跳监视器时间、CAS 续租 presence（并续 discovery
// TTL）、租约被抢时自愈关闭，最后回 HeartbeatAck。
func (h *hub) handleHeartbeatV2(sender *peer, hb *v2.Heartbeat) {
	h.mutex.Lock()
	sender.lastHeartbeat = time.Now()
	h.mutex.Unlock()
	if h.presence == nil {
		h.sendV2ProtocolError(sender, hb.RequestId, v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE, "control lease store unavailable")
		return
	}
	{
		leaseCtx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		ok, err := h.presence.RenewPresence(leaseCtx, sender.deviceID, sender.connectionID, h.presenceFor(sender), h.presenceTTL)
		cancel()
		if err != nil {
			// The server cannot claim the lease was renewed when the authority
			// could not be reached.  Keep the socket alive for a later retry, but
			// fail this heartbeat closed instead of acknowledging a false lease.
			h.sendV2ProtocolError(sender, hb.RequestId, v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE, "control lease renewal unavailable")
			return
		} else if !ok {
			// 租约已被其它连接抢占：本连接已被取代，自愈关闭且不回 ack。
			closePeer(sender)
			return
		}
		discCtx, dcancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		_, discErr := h.presence.RenewDiscovery(discCtx, sender.deviceID, sender.connectionID, h.presenceTTL)
		dcancel()
		if discErr != nil {
			h.sendV2ProtocolError(sender, hb.RequestId, v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE, "discovery lease renewal unavailable")
			return
		}
		// 续租后重新核对 currency，防复活已死亡 peer 的租约。
		h.mutex.Lock()
		isCurrent := h.peers[sender.deviceID] == sender
		h.mutex.Unlock()
		if !isCurrent {
			closePeer(sender)
			releaseCtx, releaseCancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
			_, _ = h.presence.ReleasePresence(releaseCtx, sender.deviceID, sender.connectionID)
			releaseCancel()
			return
		}
	}
	h.sendV2Frame(sender, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_HeartbeatAck{HeartbeatAck: &v2.HeartbeatAck{
			RequestId:    hb.RequestId,
			ServerTimeMs: time.Now().UnixMilli(),
		}},
	})
}

// handleDiscoveryPublishV2 调用 Step-3 的可靠发布原语 publishDiscoveryV2：落盘
// discovery、广播 peer_online/peer_updated，并向发布客户端回 DiscoveryAck。失败按
// 冻结错误模型映射 ProtocolError（EPOCH_CONFLICT / REVISION_STALE / CONTROL_UNAVAILABLE）。
func (h *hub) handleDiscoveryPublishV2(sender *peer, pub *v2.DiscoveryPublish) {
	if !h.allowDiscoveryPublish(sender.deviceID, time.Now()) {
		h.sendV2ProtocolError(sender, pub.RequestId, v2.ErrorCode_ERROR_CODE_RATE_LIMITED,
			"Discovery publication rate limit exceeded.")
		return
	}
	ack, err := h.publishDiscoveryV2(pub.RequestId, sender.deviceID, sender.connectionID, pub.Snapshot)
	if err != nil {
		code := v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE
		message := "Relay discovery state is unavailable."
		switch {
		case errors.Is(err, errDiscoveryInvalidSnapshot):
			code = v2.ErrorCode_ERROR_CODE_PROTOCOL
			message = "Discovery snapshot is invalid."
		case errors.Is(err, errDiscoveryRevisionStale),
			errors.Is(err, errDiscoveryRevisionImmutable),
			errors.Is(err, errDiscoveryNoRevision):
			code = v2.ErrorCode_ERROR_CODE_REVISION_STALE
			message = "Discovery revision is stale."
		case errors.Is(err, errDiscoveryNotOwner):
			code = v2.ErrorCode_ERROR_CODE_EPOCH_CONFLICT
			message = "Discovery lease ownership changed."
		default:
			if h.logger != nil {
				h.logger.Warn("discovery publication failed", "device_id", sender.deviceID, "error", err)
			}
		}
		h.sendV2ProtocolError(sender, pub.RequestId, code, message)
		return
	}
	h.sendV2Frame(sender, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_DiscoveryAck{DiscoveryAck: ack},
	})
}

// handleResolvePeerRequestV2 用权威 4-state resolve（设计 §10）判定目标可连性：
// READY 携带 discovery；OFFLINE/NOT_READY/UNKNOWN 分别回状态并附 retry_after_ms 提示。
func (h *hub) handleResolvePeerRequestV2(sender *peer, req *v2.ResolvePeerRequest) {
	if req.TargetDeviceId == "" {
		h.sendV2ProtocolError(sender, req.RequestId, v2.ErrorCode_ERROR_CODE_PROTOCOL, "resolve requires a target device")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	result := h.resolvePeer(ctx, req.TargetDeviceId)
	cancel()
	resp := &v2.ResolvePeerResponse{RequestId: req.RequestId, Status: result.status}
	switch result.status {
	case v2.ResolveStatus_RESOLVE_STATUS_READY:
		resp.Discovery = discoveryToV2(result.discovery)
		// ConnectivityOffer deliberately has no target field on the frozen
		// wire.  Record the authoritative target for the next offer on this
		// control connection; the Rust client holds its narrow gate only through
		// Resolve + Offer, never through the answer/probe window.
		h.rememberCoordinationTarget(sender, req.TargetDeviceId)
	case v2.ResolveStatus_RESOLVE_STATUS_NOT_READY:
		resp.RetryAfterMs = v2.RESOLVE_RETRY_HINT_NOT_READY_MS
	case v2.ResolveStatus_RESOLVE_STATUS_UNKNOWN:
		resp.RetryAfterMs = v2.RESOLVE_RETRY_HINT_UNKNOWN_MS
	}
	h.sendV2Frame(sender, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_ResolvePeerResponse{ResolvePeerResponse: resp},
	})
}

// handleConnectivityOfferV2 consumes the one-shot target recorded by the
// preceding authoritative Resolve on this control connection.  The target is
// intentionally absent from ConnectivityOffer's frozen wire shape.
func (h *hub) handleConnectivityOfferV2(sender *peer, offer *v2.ConnectivityOffer) {
	targetID, coordinated := h.consumeCoordinationTarget(sender)
	if !coordinated {
		h.sendV2ProtocolErrorWithAttempt(sender, offer.RequestId, offer.AttemptId, v2.ErrorCode_ERROR_CODE_PROTOCOL,
			"connectivity offer requires a preceding resolve")
		return
	}
	if targetID == "" || targetID == sender.deviceID {
		h.sendV2ProtocolErrorWithAttempt(sender, offer.RequestId, offer.AttemptId, v2.ErrorCode_ERROR_CODE_PROTOCOL,
			"connectivity offer requires a different target device")
		return
	}
	// Resolve is the only connectivity authority.  Do not forward a client
	// supplied snapshot when the backend cannot prove that the initiator and
	// target are READY; doing so would be a fail-open candidate exchange.
	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	initiatorResult := h.resolvePeer(ctx, sender.deviceID)
	targetResult := h.resolvePeer(ctx, targetID)
	cancel()
	if initiatorResult.status != v2.ResolveStatus_RESOLVE_STATUS_READY {
		code, message := resolveStatusError(initiatorResult.status)
		h.sendV2ProtocolErrorWithAttempt(sender, offer.RequestId, offer.AttemptId, code, message)
		return
	}
	if targetResult.status != v2.ResolveStatus_RESOLVE_STATUS_READY {
		code, message := resolveStatusError(targetResult.status)
		h.sendV2ProtocolErrorWithAttempt(sender, offer.RequestId, offer.AttemptId, code, message)
		return
	}
	// The relay owns the authoritative initiator snapshot and overwrites all
	// client-provided identity/version fields before forwarding.
	offer.InitiatorSnapshot = discoveryToV2(initiatorResult.discovery)
	offer.InitiatorRuntimeEpoch = &v2.RuntimeEpoch{High: initiatorResult.discovery.RuntimeEpochHigh, Low: initiatorResult.discovery.RuntimeEpochLow}
	offer.InitiatorRevision = initiatorResult.discovery.Revision
	// 发起方身份以服务端认证为准：客户端可任意填写 initiator_device_id（伪造为其它设备），
	// 服务端在转发前强制覆盖为发送者，防止对端把被伪装的设备记为协商发起方。
	offer.InitiatorDeviceId = sender.deviceID
	encodedOffer, err := v2.EncodeFrame(&v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_ConnectivityOffer{ConnectivityOffer: offer},
	})
	if err != nil {
		code := v2.ErrorCodeOf(err)
		if code == v2.ErrorCode_ERROR_CODE_UNSPECIFIED {
			code = v2.ErrorCode_ERROR_CODE_PROTOCOL
		}
		h.sendV2ProtocolErrorWithAttempt(sender, offer.RequestId, offer.AttemptId, code,
			"connectivity offer could not be encoded")
		return
	}
	outboundOffer := outboundFrame{messageType: websocket.BinaryMessage, data: encodedOffer}

	h.mutex.Lock()
	now := time.Now()
	// routeControlV2 checked currency before the authoritative store lookups,
	// but either lookup and the potentially large encode may have overlapped a
	// reconnect. Re-check the local peer and its authoritative READY owner under
	// the Hub lock before publishing any route or reservation authorization state.
	if h.peers[sender.deviceID] != sender || !peerControlOpen(sender) ||
		initiatorResult.discovery.ConnectionID != sender.connectionID {
		h.mutex.Unlock()
		return
	}
	// Do not retain a target pointer across the lock-free encode. Re-fetch the
	// exact current peer and require it to be the connection proven READY by the
	// authoritative lookup above.
	target := h.peers[targetID]
	if !peerControlOpen(target) || target.connectionID != targetResult.discovery.ConnectionID {
		target = nil
	}
	if existing, exists := h.v2Attempts[offer.AttemptId]; exists {
		if now.Before(existing.expiresAt) {
			h.mutex.Unlock()
			h.sendV2ProtocolErrorWithAttempt(sender, offer.RequestId, offer.AttemptId, v2.ErrorCode_ERROR_CODE_PROTOCOL, "attempt_id is already in use")
			return
		}
		h.removeV2AttemptLocked(offer.AttemptId)
	}
	gateKey := relayReservationGateKey{initiatorConnectionID: sender.connectionID, attemptID: offer.AttemptId}
	if h.reservationGates.contains(gateKey, now) {
		h.mutex.Unlock()
		h.sendV2ProtocolErrorWithAttempt(sender, offer.RequestId, offer.AttemptId, v2.ErrorCode_ERROR_CODE_PROTOCOL, "attempt_id is already in use")
		return
	}
	if target != nil {
		attempt := v2Attempt{
			initiator:             sender.deviceID,
			initiatorConnectionID: sender.connectionID,
			target:                targetID,
			targetConnectionID:    target.connectionID,
			expiresAt:             now.Add(v2AttemptLifetime),
		}
		if !h.addV2AttemptLocked(offer.AttemptId, attempt, now) {
			h.removeV2AttemptLocked(offer.AttemptId)
			h.mutex.Unlock()
			h.sendV2ProtocolErrorWithAttempt(sender, offer.RequestId, offer.AttemptId,
				v2.ErrorCode_ERROR_CODE_RATE_LIMITED, "connectivity attempt capacity is temporarily exhausted")
			return
		}
		if !h.reservationGates.add(offer.AttemptId, relayReservationGate{
			initiatorDeviceID:     attempt.initiator,
			initiatorConnectionID: attempt.initiatorConnectionID,
			targetDeviceID:        attempt.target,
			targetConnectionID:    attempt.targetConnectionID,
			expiresAt:             attempt.expiresAt,
		}, now) {
			h.removeV2AttemptLocked(offer.AttemptId)
			h.reservationGates.remove(gateKey)
			h.mutex.Unlock()
			h.sendV2ProtocolErrorWithAttempt(sender, offer.RequestId, offer.AttemptId,
				v2.ErrorCode_ERROR_CODE_RATE_LIMITED, "relay reservation authorization capacity is temporarily exhausted")
			return
		}
	}
	if target == nil {
		h.mutex.Unlock()
		h.sendV2ProtocolErrorWithAttempt(sender, offer.RequestId, offer.AttemptId, v2.ErrorCode_ERROR_CODE_PEER_OFFLINE,
			"target peer is not connected on the v2 control plane")
		return
	}
	// All gate readers use the Hub lock. The tentative gate therefore becomes
	// visible only after this already-encoded frame enters the exact target
	// connection's queue and the lock is released. The queue handoff is bounded
	// and non-blocking; failure removes every attempt/gate index before unlock.
	forwarded := target.enqueue(outboundOffer)
	if !forwarded {
		h.removeV2AttemptLocked(offer.AttemptId)
		h.reservationGates.remove(gateKey)
	}
	h.mutex.Unlock()
	if !forwarded {
		closePeer(target)
		h.sendV2ProtocolErrorWithAttempt(sender, offer.RequestId, offer.AttemptId,
			v2.ErrorCode_ERROR_CODE_PEER_OFFLINE, "target peer is not connected on the v2 control plane")
	}
}

// handleConnectivityAnswerV2 把 B 的 ConnectivityAnswer 按 attempt_id 回路由给发起方
// A（attempt 一次性，转发后即删除注册）。
func (h *hub) handleConnectivityAnswerV2(sender *peer, ans *v2.ConnectivityAnswer) {
	h.mutex.Lock()
	attempt, ok := h.v2Attempts[ans.AttemptId]
	if ok && !time.Now().Before(attempt.expiresAt) {
		h.removeV2AttemptLocked(ans.AttemptId)
		ok = false
	}
	// A stale or mismatched answer is deliberately dropped.  In particular,
	// an unrelated authenticated peer must not be able to consume the live
	// attempt before the real target answers.
	if ok && (attempt.target != sender.deviceID || attempt.targetConnectionID != sender.connectionID || h.peers[attempt.target] != sender) {
		h.mutex.Unlock()
		return
	}
	initiator := (*peer)(nil)
	if ok && attempt.initiator != "" && attempt.initiator != sender.deviceID {
		initiator = h.peers[attempt.initiator]
		if !peerIsRoutable(initiator) || initiator.connectionID != attempt.initiatorConnectionID {
			initiator = nil
		}
	}
	if ok {
		h.removeV2AttemptLocked(ans.AttemptId)
	}
	h.mutex.Unlock()
	if !ok || initiator == nil {
		return
	}
	// The authenticated target connection is the only trusted source of the
	// responder identity.  The remaining answer discovery fields are opaque to
	// the relay and are consumed by the endpoint coordinator after its own
	// READY/epoch checks.
	ans.ResponderDeviceId = sender.deviceID
	h.sendV2Frame(initiator, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_ConnectivityAnswer{ConnectivityAnswer: ans},
	})
}

// handleRealtimeSignalV2 转发 WebRTC 风格的信令（不透明 payload，Relay 不解析）到
// target_device_id 的 v2 控制面连接。发送方身份由接收方的认证连接上下文确定。
func (h *hub) handleRealtimeSignalV2(sender *peer, sig *v2.RealtimeSignal) {
	if sig.SourceDeviceId != "" {
		h.sendV2ProtocolError(sender, sig.RequestId, v2.ErrorCode_ERROR_CODE_PROTOCOL, "client realtime source must be empty")
		return
	}
	if sig.TargetDeviceId == "" || sig.TargetDeviceId == sender.deviceID {
		h.sendV2ProtocolError(sender, sig.RequestId, v2.ErrorCode_ERROR_CODE_PROTOCOL, "invalid realtime target")
		return
	}
	h.mutex.Lock()
	target := h.peers[sig.TargetDeviceId]
	if !peerIsRoutable(target) {
		target = nil
	}
	h.mutex.Unlock()
	if target == nil {
		h.sendV2ProtocolError(sender, sig.RequestId, v2.ErrorCode_ERROR_CODE_PEER_OFFLINE, "target peer is not connected on the v2 control plane")
		return
	}
	forwarded, ok := proto.Clone(sig).(*v2.RealtimeSignal)
	if !ok {
		h.sendV2ProtocolError(sender, sig.RequestId, v2.ErrorCode_ERROR_CODE_PROTOCOL, "invalid realtime signal")
		return
	}
	forwarded.SourceDeviceId = sender.deviceID
	h.sendV2Frame(target, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_RealtimeSignal{RealtimeSignal: forwarded},
	})
}

// handleProtocolErrorV2 把带 attempt_id 的 ProtocolError 转发给该 attempt 的发起方
// （例如 B 对 A 的 offer 返回 PEER_NOT_READY）；无 attempt_id 或找不到发起方则丢弃。
func (h *hub) handleProtocolErrorV2(sender *peer, frame *v2.RelayFrame) {
	pe := frame.GetProtocolError()
	if pe == nil || pe.AttemptId == "" {
		return
	}
	h.mutex.Lock()
	attempt, ok := h.v2Attempts[pe.AttemptId]
	target := (*peer)(nil)
	if ok && !time.Now().Before(attempt.expiresAt) {
		h.removeV2AttemptLocked(pe.AttemptId)
		ok = false
	}
	if ok && (attempt.target != sender.deviceID || attempt.targetConnectionID != sender.connectionID || h.peers[attempt.target] != sender) {
		h.mutex.Unlock()
		return
	}
	if ok {
		target = h.peers[attempt.initiator]
		if !peerIsRoutable(target) || target.connectionID != attempt.initiatorConnectionID {
			target = nil
		}
		h.removeV2AttemptLocked(pe.AttemptId)
	}
	h.mutex.Unlock()
	if ok && target != nil && target != sender {
		h.sendV2Frame(target, frame)
	}
}

// handleRelayReserveRequestV2 创建一条 relay-data reservation（设计 §25）：
//  1. 一次性消费同一发起 Control connection 上成功转发的 Resolve→Offer gate；
//     attempt_id 与目标设备、两端 connection_id 必须精确匹配。
//  2. 目标必须 READY（权威 resolve，绝不 fail-open）。
//  3. 生成 16-byte hex reservation_id、两个独立 32-byte local_token，存活秒数夹到
//     [15,120]；落盘共享状态（Redis relay:reservation:{id}，TTL=expires_at）。
//  4. 给 A 回 RelayReserveResponse（含自包含 relay_data_endpoint），并给 B 推
//     IncomingRelayReservation——B 在 v2 控制面连接时才能收到。
func (h *hub) handleRelayReserveRequestV2(sender *peer, req *v2.RelayReserveRequest) {
	gate, authorized := h.consumeRelayReservationGate(sender, req.AttemptId, req.TargetDeviceId)
	if req.TargetDeviceId == "" || req.TargetDeviceId == sender.deviceID {
		h.sendV2ProtocolErrorWithAttempt(sender, req.RequestId, req.AttemptId, v2.ErrorCode_ERROR_CODE_PROTOCOL, "invalid reservation target")
		return
	}
	if !authorized {
		h.sendV2ProtocolErrorWithAttempt(sender, req.RequestId, req.AttemptId, v2.ErrorCode_ERROR_CODE_PROTOCOL,
			"relay reservation requires a successful connectivity offer")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	result := h.resolvePeer(ctx, req.TargetDeviceId)
	cancel()
	if result.status != v2.ResolveStatus_RESOLVE_STATUS_READY {
		code, message := resolveStatusError(result.status)
		h.sendV2ProtocolErrorWithAttempt(sender, req.RequestId, req.AttemptId, code, message)
		return
	}
	if h.presence == nil {
		h.sendV2ProtocolErrorWithAttempt(sender, req.RequestId, req.AttemptId, v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE, "reservation store unavailable")
		return
	}
	lifetime := clampReservationLifetime(req.DesiredLifetimeS)
	reservationID := hex.EncodeToString(randomBytes(v2.RESERVATION_ID_BYTES))
	initiatorToken := randomBytes(v2.RESERVATION_TOKEN_BYTES)
	responderToken := randomBytes(v2.RESERVATION_TOKEN_BYTES)
	now := time.Now()
	expiresAtMs := now.Add(time.Duration(lifetime) * time.Second).UnixMilli()
	// relay_data_endpoint 必须从服务端配置的公共源构造（RELAY_PUBLIC_URL，未配置时从
	// 监听地址派生），绝不使用客户端提供的 Host 头：Host 头攻击者可控，用它构造端点会
	// 把对端 B 的 32-byte ResponderToken 引导到攻击者选择的地址。
	endpoint := fmt.Sprintf("%s/v2/relay/%s", h.relayDataOrigin, reservationID)
	res := Reservation{
		ReservationID:     reservationID,
		AttemptID:         req.AttemptId,
		InitiatorDeviceID: sender.deviceID,
		ResponderDeviceID: req.TargetDeviceId,
		RelayDataEndpoint: endpoint,
		InitiatorToken:    initiatorToken,
		ResponderToken:    responderToken,
		ExpiresAtMs:       expiresAtMs,
		LifetimeS:         lifetime,
	}
	cctx, ccancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	err := h.presence.CreateReservation(cctx, res)
	ccancel()
	if err != nil {
		code := v2.ErrorCode_ERROR_CODE_RESERVATION_FAILED
		message := "Relay reservation storage is unavailable."
		if errors.Is(err, errReservationCapacity) {
			code = v2.ErrorCode_ERROR_CODE_RATE_LIMITED
			message = "Relay reservation capacity is temporarily exhausted."
		}
		if h.logger != nil {
			h.logger.Warn("relay reservation creation failed", "device_id", sender.deviceID, "error", err)
		}
		h.sendV2ProtocolErrorWithAttempt(sender, req.RequestId, req.AttemptId, code, message)
		return
	}
	// The reservation remains bound to the exact target control connection that
	// received the offer. A reconnect cannot inherit a token for an attempt it
	// never saw; it must perform a fresh Resolve -> Offer cycle.
	h.mutex.Lock()
	initiatorCurrent := h.peers[gate.initiatorDeviceID] == sender && peerControlOpen(sender)
	responder := h.peers[gate.targetDeviceID]
	if !peerControlOpen(responder) || responder.connectionID != gate.targetConnectionID {
		responder = nil
	}
	h.mutex.Unlock()
	if !initiatorCurrent || responder == nil {
		deleteCtx, deleteCancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		_ = h.presence.DeleteReservation(deleteCtx, reservationID)
		deleteCancel()
		if initiatorCurrent {
			h.sendV2ProtocolErrorWithAttempt(sender, req.RequestId, req.AttemptId, v2.ErrorCode_ERROR_CODE_PEER_OFFLINE,
				"target peer is not connected on the v2 control plane")
		}
		return
	}
	// Give B its role token first. If its exact control connection cannot accept
	// the notification, delete the still-secret reservation and fail A closed.
	if !h.sendV2Frame(responder, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_IncomingRelayReservation{IncomingRelayReservation: &v2.IncomingRelayReservation{
			AttemptId:         req.AttemptId,
			ReservationId:     reservationID,
			InitiatorDeviceId: sender.deviceID,
			RelayDataEndpoint: endpoint,
			ExpiresAtMs:       expiresAtMs,
			LocalToken:        responderToken,
		}},
	}) {
		deleteCtx, deleteCancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		_ = h.presence.DeleteReservation(deleteCtx, reservationID)
		deleteCancel()
		h.sendV2ProtocolErrorWithAttempt(sender, req.RequestId, req.AttemptId, v2.ErrorCode_ERROR_CODE_PEER_OFFLINE,
			"target peer is not connected on the v2 control plane")
		return
	}
	// Give A the initiator token only after B accepted its notification.
	if !h.sendV2Frame(sender, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_RelayReserveResponse{RelayReserveResponse: &v2.RelayReserveResponse{
			RequestId:         req.RequestId,
			AttemptId:         req.AttemptId,
			ReservationId:     reservationID,
			RelayDataEndpoint: endpoint,
			ExpiresAtMs:       expiresAtMs,
			LocalToken:        initiatorToken,
		}},
	}) {
		deleteCtx, deleteCancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		_ = h.presence.DeleteReservation(deleteCtx, reservationID)
		deleteCancel()
	}
}

// ---------------------------------------------------------------------------
// 帧发送辅助
// ---------------------------------------------------------------------------

// sendV2Frame 编码并投递一帧 v2 控制帧给指定 peer。编码失败或对端积压/已关闭时定向
// 关闭对端。
func (h *hub) sendV2Frame(peer *peer, frame *v2.RelayFrame) bool {
	if peer == nil {
		return false
	}
	data, err := v2.EncodeFrame(frame)
	if err != nil {
		return false
	}
	if !peer.enqueue(outboundFrame{websocket.BinaryMessage, data}) {
		closePeer(peer)
		return false
	}
	return true
}

// sendV2ProtocolError 向 peer 回一条 ProtocolError（request_id 回显失败请求，
// 0 表示服务端主动）。异步入队，用于非致命的错误通知。
func (h *hub) sendV2ProtocolError(peer *peer, requestID uint64, code v2.ErrorCode, message string) {
	h.sendV2ProtocolErrorWithAttempt(peer, requestID, "", code, message)
}

// sendV2ProtocolErrorWithAttempt preserves both correlation keys when a
// failure belongs to an asynchronous connectivity attempt.  The Rust client
// can then route a responder error to the attempt tracker even though the
// responder has its own request_id.
func (h *hub) sendV2ProtocolErrorWithAttempt(peer *peer, requestID uint64, attemptID string, code v2.ErrorCode, message string) {
	h.sendV2Frame(peer, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ProtocolError{ProtocolError: &v2.ProtocolError{
			RequestId: requestID,
			AttemptId: attemptID,
			Code:      code,
			Message:   message,
		}},
	})
}

// validateV2ClientRequest enforces the correlation fields that protobuf's
// scalar defaults cannot express.  A request without a non-zero request_id or
// an async operation without an attempt_id cannot be safely correlated, so it
// is a connection-level protocol violation.
func validateV2ClientRequest(frame *v2.RelayFrame) (uint64, error) {
	if frame == nil || frame.Kind == nil {
		return 0, nil
	}
	requestID := uint64(0)
	attemptID := ""
	switch kind := frame.Kind.(type) {
	case *v2.RelayFrame_Heartbeat:
		requestID = kind.Heartbeat.RequestId
	case *v2.RelayFrame_DiscoveryPublish:
		requestID = kind.DiscoveryPublish.RequestId
	case *v2.RelayFrame_ResolvePeerRequest:
		requestID = kind.ResolvePeerRequest.RequestId
	case *v2.RelayFrame_ConnectivityOffer:
		requestID, attemptID = kind.ConnectivityOffer.RequestId, kind.ConnectivityOffer.AttemptId
	case *v2.RelayFrame_ConnectivityAnswer:
		requestID, attemptID = kind.ConnectivityAnswer.RequestId, kind.ConnectivityAnswer.AttemptId
	case *v2.RelayFrame_RelayReserveRequest:
		requestID, attemptID = kind.RelayReserveRequest.RequestId, kind.RelayReserveRequest.AttemptId
	case *v2.RelayFrame_RealtimeSignal:
		requestID = kind.RealtimeSignal.RequestId
	default:
		// Server-direction messages and ProtocolError are handled by the
		// direction switch below; they are not client requests.
		return 0, nil
	}
	if requestID == 0 {
		return 0, errors.New("client request must carry a non-zero request_id")
	}
	if attemptID == "" {
		switch frame.Kind.(type) {
		case *v2.RelayFrame_ConnectivityOffer, *v2.RelayFrame_ConnectivityAnswer, *v2.RelayFrame_RelayReserveRequest:
			return requestID, errors.New("async control request must carry an attempt_id")
		}
	}
	return requestID, nil
}

// sendV2ProtocolErrorSync 在 peer.writeMutex 下同步写一条 ProtocolError，用于协议
// 违规后立即关连接的场景：read goroutine 先冲刷错误帧再让 defer 关闭 socket，保证
// 客户端能收到错误码（区别于异步 enqueue 可能被 closePeer 抢先丢弃）。
func (h *hub) sendV2ProtocolErrorSync(peer *peer, requestID uint64, code v2.ErrorCode, message string) {
	data, err := v2.EncodeFrame(&v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ProtocolError{ProtocolError: &v2.ProtocolError{
			RequestId: requestID,
			Code:      code,
			Message:   message,
		}},
	})
	if err != nil {
		return
	}
	peer.writeMutex.Lock()
	defer peer.writeMutex.Unlock()
	_ = peer.socket.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_ = peer.socket.WriteMessage(websocket.BinaryMessage, data)
}

// broadcastV2 把一帧 v2 控制帧推给除 exceptDeviceID 外的所有本地 v2 控制面 peer。
// 按 h.broadcast 的「锁内快照、锁外 enqueue」模式执行；enqueue 失败定向关闭。
func (h *hub) broadcastV2(exceptDeviceID string, frame *v2.RelayFrame) {
	data, err := v2.EncodeFrame(frame)
	if err != nil {
		return
	}
	h.mutex.Lock()
	peers := make([]*peer, 0, len(h.peers))
	for deviceID, p := range h.peers {
		if deviceID != exceptDeviceID && peerIsRoutable(p) {
			peers = append(peers, p)
		}
	}
	h.mutex.Unlock()
	for _, p := range peers {
		if !p.enqueue(outboundFrame{websocket.BinaryMessage, data}) {
			closePeer(p)
		}
	}
}

// discoveryToV2 把共享存储的 Discovery 反解成冻结契约的 DiscoverySnapshot，供
// ResolvePeerResponse（READY）与 ConnectivityOffer 的 initiator_snapshot 使用。
// candidates 以 base64 存储，这里解码回不透明字节；capabilities 以数字字符串存储，
// 解析回 TransportCapability 枚举。
func discoveryToV2(d Discovery) *v2.DiscoverySnapshot {
	s := &v2.DiscoverySnapshot{
		RuntimeEpoch:  &v2.RuntimeEpoch{High: d.RuntimeEpochHigh, Low: d.RuntimeEpochLow},
		Revision:      d.Revision,
		PublishedAtMs: d.UpdatedAt.UnixMilli(),
	}
	for _, capability := range d.Capabilities {
		if n, err := strconv.ParseUint(capability, 10, 32); err == nil {
			s.TransportCapabilities = append(s.TransportCapabilities, v2.TransportCapability(n))
		}
	}
	if len(d.Candidates) > 0 {
		bundle := &v2.CandidateBundle{}
		for _, candidate := range d.Candidates {
			if raw, err := base64.StdEncoding.DecodeString(candidate); err == nil {
				bundle.Candidates = append(bundle.Candidates, raw)
			}
		}
		s.CandidateBundle = bundle
	}
	return s
}
