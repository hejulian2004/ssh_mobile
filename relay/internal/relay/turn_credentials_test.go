package relay

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestValidateTurnCredentialRequest(t *testing.T) {
	if err := validateTurnCredentialRequest(turnCredentialRequest{
		RealtimeID: "00112233445566778899aabbccddeeff",
		Generation: 7,
	}); err != nil {
		t.Fatalf("valid request rejected: %v", err)
	}
	for _, request := range []turnCredentialRequest{
		{RealtimeID: "not-a-realtime-id", Generation: 1},
		{RealtimeID: "00112233445566778899aabbccddeeff", Generation: 0},
		{RealtimeID: "00112233445566778899aabbccddeefg", Generation: 1},
	} {
		if err := validateTurnCredentialRequest(request); err == nil {
			t.Fatalf("invalid request accepted: %+v", request)
		}
	}
}

func TestIssueTurnPasswordIsDeterministicAndNonEmpty(t *testing.T) {
	secret := []byte("01234567890123456789012345678901")
	first := issueTurnPassword(secret, "1700000000:device:realtime:7")
	second := issueTurnPassword(secret, "1700000000:device:realtime:7")
	if first == "" || first != second {
		t.Fatalf("unexpected password result: %q %q", first, second)
	}
	if _, err := base64.StdEncoding.DecodeString(first); err != nil {
		t.Fatalf("password is not base64: %v", err)
	}
}

func TestTurnCredentialsRejectsUnauthenticatedRequest(t *testing.T) {
	server := NewServer(Config{
		TurnURL:          "turns:example.invalid",
		TurnSharedSecret: []byte("01234567890123456789012345678901"),
	})
	t.Cleanup(server.Close)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, PathTurnCredentialsV2, nil)
	server.turnCredentials(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusUnauthorized)
	}
}

func TestTurnCredentialsIssuesBoundEphemeralCredential(t *testing.T) {
	publicKey, privateKey := newTestKeyPair(t)
	const deviceID = "device-turn"
	server := NewServer(Config{
		CredentialKey:    []byte(TestCredentialKeyHex),
		TurnURL:          "turns:relay.example.invalid",
		TurnSharedSecret: []byte("01234567890123456789012345678901"),
	})
	t.Cleanup(server.Close)
	enrolledAt := time.Now().Truncate(time.Microsecond)
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	result, generation := server.replaceEnrollmentContext(
		server.eventsCtx,
		deviceID,
		encodedKey,
		"test",
		server.config.ProtocolVersion,
		enrolledAt,
	)
	if result != enrollmentOK {
		t.Fatalf("enrollment result = %v", result)
	}
	bearer, err := issueCredential(
		server.config.CredentialKey,
		deviceID,
		publicKey,
		generation,
		server.config.CredentialTTL,
	)
	if err != nil {
		t.Fatalf("issue bearer credential: %v", err)
	}
	body := `{"realtime_id":"00112233445566778899aabbccddeeff","generation":7}`
	request := httptest.NewRequest(
		http.MethodPost,
		PathTurnCredentialsV2,
		bytes.NewBufferString(body),
	)
	request.Header.Set("Authorization", "Bearer "+bearer)
	setCurrentSignedDeviceProof(
		request.Header,
		http.MethodPost,
		PathTurnCredentialsV2,
		privateKey,
		base64.RawURLEncoding.EncodeToString(randomBytes(32)),
	)
	recorder := httptest.NewRecorder()
	server.turnCredentials(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	if got := recorder.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("cache-control = %q, want no-store", got)
	}
	var response turnCredentialResponse
	if err := json.NewDecoder(strings.NewReader(recorder.Body.String())).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(response.URLs) != 1 || response.URLs[0] != server.config.TurnURL {
		t.Fatalf("unexpected TURN URLs: %#v", response.URLs)
	}
	if response.Username == "" || response.Password == "" || response.ExpiresAt <= time.Now().Unix() {
		t.Fatalf("incomplete ephemeral credential: %#v", response)
	}
	wantPassword := issueTurnPassword(server.config.TurnSharedSecret, response.Username)
	if response.Password != wantPassword {
		t.Fatal("TURN password was not derived from the server-only secret")
	}
}

func TestTurnCredentialsRejectsMalformedAuthenticatedRequest(t *testing.T) {
	publicKey, privateKey := newTestKeyPair(t)
	const deviceID = "device-turn-invalid"
	server := NewServer(Config{
		CredentialKey:    []byte(TestCredentialKeyHex),
		TurnURL:          "turns:relay.example.invalid",
		TurnSharedSecret: []byte("01234567890123456789012345678901"),
	})
	t.Cleanup(server.Close)
	enrolledAt := time.Now().Truncate(time.Microsecond)
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	result, generation := server.replaceEnrollmentContext(
		server.eventsCtx,
		deviceID,
		encodedKey,
		"test",
		server.config.ProtocolVersion,
		enrolledAt,
	)
	if result != enrollmentOK {
		t.Fatalf("enrollment result = %v", result)
	}
	bearer, err := issueCredential(
		server.config.CredentialKey,
		deviceID,
		publicKey,
		generation,
		server.config.CredentialTTL,
	)
	if err != nil {
		t.Fatalf("issue bearer credential: %v", err)
	}
	request := httptest.NewRequest(
		http.MethodPost,
		PathTurnCredentialsV2,
		bytes.NewBufferString(`{"realtime_id":"not-hex","generation":0}`),
	)
	request.Header.Set("Authorization", "Bearer "+bearer)
	setCurrentSignedDeviceProof(
		request.Header,
		http.MethodPost,
		PathTurnCredentialsV2,
		privateKey,
		base64.RawURLEncoding.EncodeToString(randomBytes(32)),
	)
	recorder := httptest.NewRecorder()
	server.turnCredentials(recorder, request)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	if got := recorder.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("cache-control = %q, want no-store", got)
	}
}
