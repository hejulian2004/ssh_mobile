// Relay 服务配置、环境变量解析和随机材料生成。

package relay

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultAddress                            = ":8080"
	defaultCredentialTTL                      = 24 * time.Hour
	defaultTurnCredentialTTL                  = 5 * time.Minute
	defaultMaxConnections                     = 2048
	defaultMaxTransferSessions                = 4096
	defaultMaxEnrolledDevices                 = 4096
	defaultMaxRevokedDevices                  = 4096
	defaultMaxPendingFramesPerDevice          = 64
	defaultMaxPendingBytesPerDevice    int64  = 16 * 1024 * 1024
	defaultMaxFramesPerSecondPerDevice        = 256
	defaultMaxBytesPerSecondPerDevice  int64  = 64 * 1024 * 1024
	defaultHTTPReadTimeout                    = 15 * time.Second
	defaultHTTPWriteTimeout                   = 15 * time.Second
	defaultHTTPIdleTimeout                    = 60 * time.Second
	defaultHTTPMaxHeaderBytes                 = 16 * 1024
	defaultPresenceTTL                        = 60 * time.Second
	RelayBootstrapProtocolVersion      uint32 = 2
	defaultProtocolVersion             uint32 = RelayBootstrapProtocolVersion
	// 服务端心跳监视器默认值镜像冻结契约常量：HEARTBEAT_INTERVAL_S=20、
	// SERVER_HEARTBEAT_MISSES_BEFORE_CLOSE=2（配合 PRESENCE_TTL_S=60：60/20）。
	defaultServerHeartbeatInterval = 20 * time.Second
	defaultServerHeartbeatMisses   = 2

	publishedExampleEnrollmentToken = "replace-with-a-one-time-random-enrollment-secret"
	publishedExampleCredentialKey   = "replace-with-a-32-byte-base64url-random-key"
	publishedExampleInternalToken   = "replace-with-a-32-byte-random-internal-token"
)

// relayEventsChannel is the Redis Pub/Sub channel carrying cross-instance
// device-lifecycle events.
const relayEventsChannel = "relay:events"

// Config 保存 Relay 服务器的监听、认证和资源边界。
type Config struct {
	Address     string
	StorageMode string
	DatabaseURL string
	RedisURL    string
	// RedisPassword is consumed only while opening the shared state client and
	// is cleared before the running Server retains its Config.
	RedisPassword string
	InstanceID    string
	// PublicURL 是服务端对外可达的公共源（wss://host[:port] 或 host[:port]），用于构造
	// 自包含的 relay_data_endpoint。未配置时从监听地址派生 dev 默认；无论哪种情况都绝不
	// 使用客户端提供的 Host 头（攻击者可控，会把对端 token 引导到任意地址）。
	PublicURL   string
	PresenceTTL time.Duration
	// ServerHeartbeatInterval 是服务端心跳监视器的检查周期：连续
	// ServerHeartbeatMisses 个周期未收到该连接的心跳帧即关闭连接并释放 presence 租约。
	// 客户端驱动的续期（心跳路径的 RenewPresence）不受影响。
	ServerHeartbeatInterval time.Duration
	ServerHeartbeatMisses   int
	EnrollmentToken         string
	InternalToken           string
	CredentialKey           []byte
	CredentialTTL           time.Duration
	// TurnURL and TurnSharedSecret are server-only relay credentials. They are
	// never serialized into a client config or retained by Feature code.
	TurnURL                     string
	TurnSharedSecret            []byte
	TurnCredentialTTL           time.Duration
	ProtocolVersion             uint32
	MaxConnections              int
	MaxTransferSessions         int
	MaxEnrolledDevices          int
	MaxRevokedDevices           int
	MaxPendingFramesPerDevice   int
	MaxPendingBytesPerDevice    int64
	MaxFramesPerSecondPerDevice int
	MaxBytesPerSecondPerDevice  int64
	HTTPReadTimeout             time.Duration
	HTTPWriteTimeout            time.Duration
	HTTPIdleTimeout             time.Duration
	HTTPMaxHeaderBytes          int
	TrustedProxyCIDRs           []netip.Prefix
}

// ConfigFromEnvironment 从环境变量加载并校验生产 Relay 配置。
func ConfigFromEnvironment() (Config, error) {
	address := os.Getenv("RELAY_ADDR")
	if address == "" {
		address = ":8080"
	}
	enrollment := os.Getenv("RELAY_ENROLLMENT_TOKEN")
	if len(enrollment) < 16 || enrollment == publishedExampleEnrollmentToken {
		return Config{}, errors.New("RELAY_ENROLLMENT_TOKEN must be set and contain at least 16 characters")
	}

	var decoded []byte
	key := os.Getenv("RELAY_CREDENTIAL_KEY")
	if key == "" || key == publishedExampleCredentialKey {
		return Config{}, errors.New("RELAY_CREDENTIAL_KEY must be set")
	} else {
		var err error
		decoded, err = base64.RawURLEncoding.DecodeString(key)
		if err != nil || len(decoded) < 32 {
			return Config{}, errors.New("RELAY_CREDENTIAL_KEY must be base64url encoded and at least 32 bytes")
		}
	}
	var turnSharedSecret []byte
	if rawTurnSecret := strings.TrimSpace(os.Getenv("RELAY_TURN_SHARED_SECRET")); rawTurnSecret != "" {
		var err error
		turnSharedSecret, err = base64.RawURLEncoding.DecodeString(rawTurnSecret)
		if err != nil || len(turnSharedSecret) < 32 {
			return Config{}, errors.New("RELAY_TURN_SHARED_SECRET must be base64url encoded and at least 32 bytes")
		}
	}

	storageMode := os.Getenv("RELAY_STORAGE_MODE")
	if storageMode == "" {
		storageMode = "memory"
	}
	publicURL := os.Getenv("RELAY_PUBLIC_URL")
	if err := validateRelayPublicURL(publicURL); err != nil {
		return Config{}, err
	}
	if storageMode != "memory" && storageMode != "mysql" {
		return Config{}, errors.New("RELAY_STORAGE_MODE must be \"memory\" or \"mysql\"")
	}
	databaseURL := os.Getenv("RELAY_DATABASE_URL")
	redisURL := os.Getenv("RELAY_REDIS_URL")
	redisPassword := os.Getenv("RELAY_REDIS_PASSWORD")
	instanceID := os.Getenv("RELAY_INSTANCE_ID")
	if storageMode == "mysql" && databaseURL == "" {
		return Config{}, errors.New("RELAY_DATABASE_URL must be set when RELAY_STORAGE_MODE=mysql")
	}
	if storageMode == "mysql" && redisURL == "" {
		// Without Redis the nonce replay cache is process-local while enrollment
		// is durable, so a restart silently reopens the replay window; require
		// Redis so mysql mode always keeps the full shared state layer.
		return Config{}, errors.New("RELAY_REDIS_URL must be set when RELAY_STORAGE_MODE=mysql")
	}
	if storageMode == "mysql" && len(redisPassword) < 16 {
		return Config{}, errors.New("RELAY_REDIS_PASSWORD must be set and contain at least 16 characters when RELAY_STORAGE_MODE=mysql")
	}

	internalToken := os.Getenv("RELAY_INTERNAL_TOKEN")
	if len(internalToken) < 32 || internalToken == publishedExampleInternalToken {
		return Config{}, errors.New("RELAY_INTERNAL_TOKEN must be set and contain at least 32 characters")
	}

	var parseErr error
	readDuration := func(name string, fallback time.Duration) time.Duration {
		if parseErr != nil {
			return fallback
		}
		value, err := durationEnv(name, fallback)
		if err != nil {
			parseErr = err
		}
		return value
	}
	readInt := func(name string, fallback int) int {
		if parseErr != nil {
			return fallback
		}
		value, err := intEnv(name, fallback)
		if err != nil {
			parseErr = err
		}
		return value
	}
	readInt64 := func(name string, fallback int64) int64 {
		if parseErr != nil {
			return fallback
		}
		value, err := int64Env(name, fallback)
		if err != nil {
			parseErr = err
		}
		return value
	}

	config := Config{
		Address:                     address,
		StorageMode:                 storageMode,
		DatabaseURL:                 databaseURL,
		RedisURL:                    redisURL,
		RedisPassword:               redisPassword,
		InstanceID:                  instanceID,
		PublicURL:                   publicURL,
		PresenceTTL:                 readDuration("RELAY_PRESENCE_TTL", defaultPresenceTTL),
		ServerHeartbeatInterval:     readDuration("RELAY_SERVER_HEARTBEAT_INTERVAL", defaultServerHeartbeatInterval),
		ServerHeartbeatMisses:       readInt("RELAY_SERVER_HEARTBEAT_MISSES", defaultServerHeartbeatMisses),
		EnrollmentToken:             enrollment,
		InternalToken:               internalToken,
		CredentialKey:               decoded,
		CredentialTTL:               readDuration("RELAY_CREDENTIAL_TTL", defaultCredentialTTL),
		TurnURL:                     strings.TrimSpace(os.Getenv("RELAY_TURN_URL")),
		TurnSharedSecret:            turnSharedSecret,
		TurnCredentialTTL:           readDuration("RELAY_TURN_CREDENTIAL_TTL", defaultTurnCredentialTTL),
		MaxConnections:              readInt("RELAY_MAX_CONNECTIONS", defaultMaxConnections),
		MaxTransferSessions:         readInt("RELAY_MAX_TRANSFER_SESSIONS", defaultMaxTransferSessions),
		MaxEnrolledDevices:          readInt("RELAY_MAX_ENROLLED_DEVICES", defaultMaxEnrolledDevices),
		MaxRevokedDevices:           readInt("RELAY_MAX_REVOKED_DEVICES", defaultMaxRevokedDevices),
		MaxPendingFramesPerDevice:   readInt("RELAY_MAX_PENDING_FRAMES_PER_DEVICE", defaultMaxPendingFramesPerDevice),
		MaxPendingBytesPerDevice:    readInt64("RELAY_MAX_PENDING_BYTES_PER_DEVICE", defaultMaxPendingBytesPerDevice),
		MaxFramesPerSecondPerDevice: readInt("RELAY_MAX_FRAMES_PER_SECOND_PER_DEVICE", defaultMaxFramesPerSecondPerDevice),
		MaxBytesPerSecondPerDevice:  readInt64("RELAY_MAX_BYTES_PER_SECOND_PER_DEVICE", defaultMaxBytesPerSecondPerDevice),
		HTTPReadTimeout:             readDuration("RELAY_HTTP_READ_TIMEOUT", defaultHTTPReadTimeout),
		HTTPWriteTimeout:            readDuration("RELAY_HTTP_WRITE_TIMEOUT", defaultHTTPWriteTimeout),
		HTTPIdleTimeout:             readDuration("RELAY_HTTP_IDLE_TIMEOUT", defaultHTTPIdleTimeout),
		HTTPMaxHeaderBytes:          readInt("RELAY_HTTP_MAX_HEADER_BYTES", defaultHTTPMaxHeaderBytes),
		TrustedProxyCIDRs:           cidrListEnv("RELAY_TRUSTED_PROXY_CIDRS"),
	}
	if parseErr != nil {
		return Config{}, parseErr
	}
	return config, nil
}

// cidrListEnv parses a comma-separated list of CIDRs (or bare IP addresses)
// into prefixes. An empty or unset variable yields no trusted proxies, which is
// the secure default: the relay never honors forwarding headers in that case.
// Malformed entries are ignored, degrading toward the secure no-proxy default
// rather than silently trusting a misconfigured boundary.
func cidrListEnv(name string) []netip.Prefix {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return nil
	}
	var prefixes []netip.Prefix
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if prefix, err := netip.ParsePrefix(part); err == nil {
			prefixes = append(prefixes, prefix)
			continue
		}
		if addr, err := netip.ParseAddr(part); err == nil {
			prefixes = append(prefixes, netip.PrefixFrom(addr, addr.BitLen()))
		}
	}
	return prefixes
}

// withConfigDefaults supplies safe finite defaults for programmatic callers as
// well as environment-backed production configuration. Secrets are intentionally
// not generated here because NewServer owns their process-local initialization.
func withConfigDefaults(config Config) Config {
	if config.Address == "" {
		config.Address = defaultAddress
	}
	if config.ProtocolVersion == 0 {
		config.ProtocolVersion = defaultProtocolVersion
	}
	if config.InternalToken == "" {
		config.InternalToken = hex.EncodeToString(randomBytes(16))
	}
	if config.CredentialTTL <= 0 {
		config.CredentialTTL = defaultCredentialTTL
	}
	if config.TurnCredentialTTL <= 0 {
		config.TurnCredentialTTL = defaultTurnCredentialTTL
	}
	if config.MaxConnections <= 0 {
		config.MaxConnections = defaultMaxConnections
	}
	if config.MaxTransferSessions <= 0 {
		config.MaxTransferSessions = defaultMaxTransferSessions
	}
	if config.MaxEnrolledDevices <= 0 {
		config.MaxEnrolledDevices = defaultMaxEnrolledDevices
	}
	if config.MaxRevokedDevices <= 0 {
		config.MaxRevokedDevices = defaultMaxRevokedDevices
	}
	if config.MaxPendingFramesPerDevice <= 0 {
		config.MaxPendingFramesPerDevice = defaultMaxPendingFramesPerDevice
	}
	if config.MaxPendingBytesPerDevice <= 0 {
		config.MaxPendingBytesPerDevice = defaultMaxPendingBytesPerDevice
	}
	if config.MaxFramesPerSecondPerDevice <= 0 {
		config.MaxFramesPerSecondPerDevice = defaultMaxFramesPerSecondPerDevice
	}
	if config.MaxBytesPerSecondPerDevice <= 0 {
		config.MaxBytesPerSecondPerDevice = defaultMaxBytesPerSecondPerDevice
	}
	if config.PresenceTTL <= 0 {
		config.PresenceTTL = defaultPresenceTTL
	}
	if config.ServerHeartbeatInterval <= 0 {
		config.ServerHeartbeatInterval = defaultServerHeartbeatInterval
	}
	if config.ServerHeartbeatMisses <= 0 {
		config.ServerHeartbeatMisses = defaultServerHeartbeatMisses
	}
	if config.HTTPReadTimeout <= 0 {
		config.HTTPReadTimeout = defaultHTTPReadTimeout
	}
	if config.HTTPWriteTimeout <= 0 {
		config.HTTPWriteTimeout = defaultHTTPWriteTimeout
	}
	if config.HTTPIdleTimeout <= 0 {
		config.HTTPIdleTimeout = defaultHTTPIdleTimeout
	}
	if config.HTTPMaxHeaderBytes <= 0 {
		config.HTTPMaxHeaderBytes = defaultHTTPMaxHeaderBytes
	}
	return config
}

func durationEnv(name string, fallback time.Duration) (time.Duration, error) {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback, nil
	}
	val, err := time.ParseDuration(raw)
	if err != nil || val <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration", name)
	}
	return val, nil
}

func intEnv(name string, fallback int) (int, error) {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback, nil
	}
	val, err := strconv.Atoi(raw)
	if err != nil || val <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", name)
	}
	return val, nil
}

func int64Env(name string, fallback int64) (int64, error) {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback, nil
	}
	val, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || val <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", name)
	}
	return val, nil
}

// validateRelayPublicURL keeps production endpoint publication on an explicit
// origin. Plain HTTP/WS is accepted only for loopback integration tests.
func validateRelayPublicURL(value string) error {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return errors.New("RELAY_PUBLIC_URL must be set to the externally reachable Relay origin")
	}
	if !strings.Contains(raw, "://") {
		raw = "wss://" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" || parsed.Hostname() == "" {
		return errors.New("RELAY_PUBLIC_URL must be a valid origin")
	}
	if parsed.User != nil || (parsed.Path != "" && parsed.Path != "/") || parsed.RawQuery != "" || parsed.Fragment != "" {
		return errors.New("RELAY_PUBLIC_URL must not contain credentials, a path, query, or fragment")
	}
	switch parsed.Scheme {
	case "https", "wss":
		if relayPublicHostIsLoopback(parsed.Hostname()) {
			return errors.New("RELAY_PUBLIC_URL must not publish a loopback HTTPS/WSS origin")
		}
	case "http", "ws":
		if !relayPublicHostIsLoopback(parsed.Hostname()) {
			return errors.New("RELAY_PUBLIC_URL permits HTTP/WS only for loopback integration tests")
		}
	default:
		return errors.New("RELAY_PUBLIC_URL scheme must be https or wss")
	}
	return nil
}

func relayPublicHostIsLoopback(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	address := net.ParseIP(host)
	return address != nil && address.IsLoopback()
}

// relayDataEndpointOrigin 返回构造自包含 relay_data_endpoint 的公共源（wss://host[:port]）。
// 优先使用显式配置的 PublicURL（RELAY_PUBLIC_URL，可带或不带 scheme）；未配置时从监听
// 地址派生 dev 默认（通配主机退化到 localhost）。它绝不读取客户端提供的 Host 头——Host 头
// 攻击者可控，用它构造端点会把对端 B 的 32-byte ResponderToken 引导到攻击者选择的地址。
func relayDataEndpointOrigin(config Config) string {
	if config.PublicURL != "" {
		origin := strings.TrimSpace(config.PublicURL)
		origin = strings.TrimSuffix(origin, "/")
		if !strings.Contains(origin, "://") {
			origin = "wss://" + origin
		}
		if parsed, err := url.Parse(origin); err == nil && parsed.Host != "" {
			switch parsed.Scheme {
			case "https":
				parsed.Scheme = "wss"
			case "http":
				parsed.Scheme = "ws"
			}
			parsed.Path = ""
			parsed.RawPath = ""
			parsed.RawQuery = ""
			parsed.Fragment = ""
			return strings.TrimSuffix(parsed.String(), "/")
		}
		return origin
	}
	host, port, err := net.SplitHostPort(config.Address)
	if err != nil {
		// 异常监听地址：以 localhost 前缀兜底，保留原端口串。
		if strings.HasPrefix(config.Address, ":") {
			return "wss://localhost" + config.Address
		}
		return "wss://localhost:" + config.Address
	}
	switch host {
	case "", "0.0.0.0", "::":
		host = "localhost"
	}
	return "wss://" + net.JoinHostPort(host, port)
}

func randomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}
