package relay

// Canonical route patterns and path constants for Relay endpoints.
const (
	RouteHealthz           = "GET /healthz"
	RouteEnrollV2          = "POST /v2/devices/enroll"
	RouteRefreshV2         = "POST /v2/devices/refresh"
	RouteTurnCredentialsV2 = "POST /v2/turn/credentials"
	RouteControlV2         = "GET /v2/control"
	RouteRelayDataV2       = "GET /v2/relay/{reservation_id}"

	RouteInternalStatusV2        = "GET /internal/v2/status"
	RouteInternalDevicesV2       = "GET /internal/v2/devices"
	RouteInternalRevokeDeviceV2  = "POST /internal/v2/devices/{deviceId}/revoke"
	RouteInternalTokenV2         = "GET /internal/v2/access/enrollment-token"
	RouteInternalRotateTokenV2   = "POST /internal/v2/access/enrollment-token/rotate"
	RouteInternalTelemetryAttest = "POST /internal/v2/telemetry/attest"

	PathHealthz           = "/healthz"
	PathEnrollV2          = "/v2/devices/enroll"
	PathRefreshV2         = "/v2/devices/refresh"
	PathTurnCredentialsV2 = "/v2/turn/credentials"
	PathControlV2         = "/v2/control"
	PathRelayDataV2       = "/v2/relay/"

	PathInternalStatusV2        = "/internal/v2/status"
	PathInternalDevicesV2       = "/internal/v2/devices"
	PathInternalRevokeDeviceV2  = "/internal/v2/devices/"
	PathInternalTokenV2         = "/internal/v2/access/enrollment-token"
	PathInternalRotateTokenV2   = "/internal/v2/access/enrollment-token/rotate"
	PathInternalTelemetryAttest = "/internal/v2/telemetry/attest"

	// PathPublicTelemetryEnroll is the public transcript target signed by a
	// device when it bootstraps its telemetry credential.
	PathPublicTelemetryEnroll = "/api/v1/telemetry/enroll"
	PathPublicTelemetryRotate = "/api/v1/telemetry/enroll/rotate"
)

const RoutePublicTelemetryEnroll = "/api/v1/telemetry/enroll"
