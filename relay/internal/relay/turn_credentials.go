package relay

import (
	"crypto/hmac"
	"crypto/sha1" // #nosec G505 -- TURN REST credentials require HMAC-SHA1.
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	turnCredentialOperation = "issue_turn_credential"
	maxTurnCredentialTTL    = 15 * time.Minute
	minTurnCredentialTTL    = time.Minute
)

type turnCredentialRequest struct {
	RealtimeID string `json:"realtime_id"`
	Generation uint64 `json:"generation"`
}

type turnCredentialResponse struct {
	URLs      []string `json:"urls"`
	Username  string   `json:"username"`
	Password  string   `json:"password"`
	ExpiresAt int64    `json:"expires_at"`
}

// turnCredentials issues an ephemeral coturn REST credential after the same
// device-authenticated proof used by the V2 control plane. The shared secret
// remains server-only; this response is never persisted or logged.
func (s *Server) turnCredentials(w http.ResponseWriter, r *http.Request) {
	// Credential responses and authentication failures must never be cached by
	// an intermediary; the endpoint carries short-lived bearer material.
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		writeNetworkError(w, http.StatusMethodNotAllowed, relayErrorInvalidArgument, "TURN credential method is unsupported.", turnCredentialOperation, "")
		return
	}
	claims, _, code, authenticated := s.authenticatedRequest(r)
	if !authenticated {
		status := http.StatusUnauthorized
		if code == relayErrorCredentialExpired {
			status = http.StatusUnauthorized
		}
		writeNetworkError(w, status, code, "TURN credential authentication failed.", turnCredentialOperation, "")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var request turnCredentialRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument, "TURN credential request is invalid.", turnCredentialOperation, claims.DeviceID)
		return
	}
	if err := validateTurnCredentialRequest(request); err != nil {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument, err.Error(), turnCredentialOperation, claims.DeviceID)
		return
	}
	if len(s.config.TurnSharedSecret) < 32 || strings.TrimSpace(s.config.TurnURL) == "" {
		writeNetworkError(w, http.StatusServiceUnavailable, relayErrorRelayError, "TURN service is unavailable.", turnCredentialOperation, claims.DeviceID)
		return
	}
	ttl := s.config.TurnCredentialTTL
	if ttl < minTurnCredentialTTL {
		ttl = minTurnCredentialTTL
	}
	if ttl > maxTurnCredentialTTL {
		ttl = maxTurnCredentialTTL
	}
	now := time.Now()
	expiresAt := now.Add(ttl).Unix()
	username := strconv.FormatInt(expiresAt, 10) + ":" + claims.DeviceID + ":" + request.RealtimeID + ":" + strconv.FormatUint(request.Generation, 10)
	password := issueTurnPassword(s.config.TurnSharedSecret, username)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(turnCredentialResponse{
		URLs:      []string{strings.TrimSpace(s.config.TurnURL)},
		Username:  username,
		Password:  password,
		ExpiresAt: expiresAt,
	})
}

func validateTurnCredentialRequest(request turnCredentialRequest) error {
	if len(request.RealtimeID) != 32 {
		return errors.New("TURN realtime ID is invalid")
	}
	for _, value := range request.RealtimeID {
		if !((value >= '0' && value <= '9') || (value >= 'a' && value <= 'f')) {
			return errors.New("TURN realtime ID is invalid")
		}
	}
	if request.Generation == 0 {
		return errors.New("TURN generation is invalid")
	}
	return nil
}

func issueTurnPassword(sharedSecret []byte, username string) string {
	mac := hmac.New(sha1.New, sharedSecret) // #nosec G401 -- coturn REST API algorithm.
	_, _ = mac.Write([]byte(username))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}
