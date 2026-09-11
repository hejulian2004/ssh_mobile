// Relay server composition and route registration.
//
// The transport network and bootstrap are v2-only: /v2/control is the long-lived control plane
// (protobuf RelayFrame), /v2/relay/{reservation_id} is the reservation-scoped
// opaque data plane (RelayDataFrame), and device bootstrap uses /v2/devices/enroll
// and /v2/devices/refresh. The internal management API (/internal/v2/*) is authenticated
// with the internal token and serves status, device listing, revocation, and enrollment
// token rotation. The standalone admin backend (internal/admin) consumes these
// endpoints on behalf of operators.

package relay

import (
	"context"
	"encoding/hex"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type Server struct {
	config   Config
	hub      *hub
	upgrader websocket.Upgrader
	store    Storage
	cache    Cache
	// relayData 是 /v2/relay/{reservation_id} 数据面端点的链接注册表（设计 §25）。
	// 它与 hub 的 peer 表完全独立：数据面连接没有 presence 租约，只按 reservation 配对。
	relayData    *relayDataRegistry
	startedAt    time.Time
	eventsCtx    context.Context
	eventsCancel context.CancelFunc
	eventsWG     sync.WaitGroup
	closeOnce    sync.Once
	logger       *slog.Logger

	// deviceLocks 是 per-device 分片锁（与 hub 的 admission 条纹同构）：同设备复合
	// 操作（enroll/revoke/authenticate）在同一条纹上串行以保留原子性，不同设备
	// 并行访问存储——MySQL 模式不再被全局 devicesMutex 退化成单并发。tokenMutex
	// 单独保护无 deviceID 可锁的 EnrollmentToken 标量。
	deviceLocks [deviceLockStripeCount]deviceStripeLock
	tokenMutex  sync.Mutex
}

// deviceLockStripeCount 是 per-device 分片锁的条纹数。同一设备的操作经 fnv-1a
// 哈希落到同一条纹上串行（保留复合原子性），不同设备极少碰撞且只短暂等待。
const deviceLockStripeCount = 128

// deviceStripeLock is a context-aware binary semaphore. Cross-instance event
// handling and reconciliation must be able to stop waiting when Server.Close
// cancels eventsCtx; a plain sync.Mutex would make that shutdown path
// uninterruptible behind a stalled request holding the same stripe.
type deviceStripeLock struct {
	once      sync.Once
	semaphore chan struct{}
}

func (lock *deviceStripeLock) acquire(ctx context.Context) (func(), bool) {
	lock.once.Do(func() { lock.semaphore = make(chan struct{}, 1) })
	select {
	case lock.semaphore <- struct{}{}:
		return func() { <-lock.semaphore }, true
	case <-ctx.Done():
		return nil, false
	}
}

// serverDependencyStartupTimeout bounds the complete MySQL + Redis startup
// sequence. The two dependencies deliberately share one deadline so a slow
// first dependency cannot reset the budget before the second one opens.
const serverDependencyStartupTimeout = 15 * time.Second

// serverCloseTimeout bounds all RelayData, Control/event, and dependency close
// phases together. The command's 15-second HTTP shutdown plus this budget stays
// below the Compose 30-second stop_grace_period.
const serverCloseTimeout = 10 * time.Second

type mysqlStorageOpener func(context.Context, string, int) (Storage, error)
type redisCacheOpener func(context.Context, string, Config) (Cache, error)

// lockDevice 为 deviceID 串行化复合设备操作并返回解锁函数。单个存储调用不需要
// 它——memoryStore 与 mysqlStore 均已内部并发安全；它只保护跨多个 store/cache
// 调用的原子单元（revoke/enroll/authenticate）。
func (s *Server) lockDevice(deviceID string) func() {
	unlock, _ := s.lockDeviceContext(context.Background(), deviceID)
	return unlock
}

func (s *Server) lockDeviceContext(ctx context.Context, deviceID string) (func(), bool) {
	stripe := deviceLockStripe(deviceID) % deviceLockStripeCount
	return s.deviceLocks[stripe].acquire(ctx)
}

// upgradeWithinContext copies the shared upgrader so this handshake uses the
// caller's remaining composite-operation budget. Gorilla clears HTTP-server
// deadlines after hijacking, so relying on r.Context alone would let a client
// that stops reading the 101 response hold an admission stripe indefinitely.
func (s *Server) upgradeWithinContext(ctx context.Context, w http.ResponseWriter, r *http.Request) (*websocket.Conn, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	upgrader := s.upgrader
	if deadline, ok := ctx.Deadline(); ok {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil, context.DeadlineExceeded
		}
		if upgrader.HandshakeTimeout <= 0 || remaining < upgrader.HandshakeTimeout {
			upgrader.HandshakeTimeout = remaining
		}
	}
	return upgrader.Upgrade(w, r, nil)
}

// NewServer 根据给定配置创建仅驻留内存的 Relay 服务。
func NewServer(config Config) *Server {
	config = withConfigDefaults(config)
	// NewServer is the memory-only composition root. External-store endpoints
	// and credentials have no runtime purpose here, so discard accidentally
	// supplied values just as the mysql startup path does after opening them.
	config.DatabaseURL = ""
	config.RedisURL = ""
	config.RedisPassword = ""
	if config.EnrollmentToken == "" {
		config.EnrollmentToken = hex.EncodeToString(randomBytes(16))
	}
	if len(config.CredentialKey) == 0 {
		config.CredentialKey = randomBytes(32)
	}
	if config.InstanceID == "" {
		config.InstanceID = "relay-" + hex.EncodeToString(randomBytes(6))
	}

	// Phase 0 ships the in-memory store only; RELAY_STORAGE_MODE selects it and
	// Phase 1/2 add the MySQL/Redis implementations behind the same contract.
	memory := newMemoryStore(config)
	eventsCtx, eventsCancel := context.WithCancel(context.Background())

	server := &Server{
		config:       config,
		hub:          newHub(config),
		upgrader:     websocket.Upgrader{},
		store:        memory,
		cache:        memory,
		relayData:    newRelayDataRegistry(config.MaxTransferSessions),
		startedAt:    time.Now(),
		eventsCtx:    eventsCtx,
		eventsCancel: eventsCancel,
		logger:       slog.Default(),
	}
	server.hub.presence = server.cache
	return server
}

// Close 停止 Relay hub，释放活跃设备连接与底层存储。
func (s *Server) Close() {
	s.closeOnce.Do(func() {
		closeCtx, closeCancel := context.WithTimeout(context.Background(), serverCloseTimeout)
		defer closeCancel()
		s.eventsCancel()
		// RelayData, Control, and event reconciliation have independent ownership
		// and can converge concurrently. Each socket registry closes its admission
		// gate before touching shared dependency capabilities.
		var runtimeWG sync.WaitGroup
		runtimeWG.Add(3)
		go func() {
			defer runtimeWG.Done()
			relayDataCtx, relayDataCancel := context.WithTimeout(closeCtx, relayDataCloseTimeout)
			defer relayDataCancel()
			s.relayData.closeAllWithContext(relayDataCtx)
		}()
		go func() {
			defer runtimeWG.Done()
			s.hub.close()
		}()
		go func() {
			defer runtimeWG.Done()
			s.eventsWG.Wait()
		}()
		runtimeDone := make(chan struct{})
		go func() {
			runtimeWG.Wait()
			close(runtimeDone)
		}()
		select {
		case <-runtimeDone:
		case <-closeCtx.Done():
		}

		// Close external capabilities concurrently. If a buggy dependency ignores
		// Close, the same total server budget still lets the process exit path return.
		var dependencyWG sync.WaitGroup
		dependencyWG.Add(2)
		go func() { defer dependencyWG.Done(); _ = s.cache.Close() }()
		go func() { defer dependencyWG.Done(); _ = s.store.Close() }()
		dependenciesDone := make(chan struct{})
		go func() {
			dependencyWG.Wait()
			close(dependenciesDone)
		}()
		select {
		case <-dependenciesDone:
		case <-closeCtx.Done():
		}
	})
}

// OpenServer 根据 config.StorageMode 构建 Relay 服务：memory 模式与 NewServer
// 等价；mysql 模式额外打开数据库（并在配置 RELAY_REDIS_URL 时激活 Redis 缓存层）。
func OpenServer(config Config) (*Server, error) {
	return openServerWithStores(
		config,
		func(ctx context.Context, dsn string, maxEnrolled int) (Storage, error) {
			return openMySQLStore(ctx, dsn, maxEnrolled)
		},
		func(ctx context.Context, redisURL string, config Config) (Cache, error) {
			return openRedisStore(ctx, redisURL, config)
		},
	)
}

// openServerWithStores owns the external-store startup transaction. The
// injectable openers keep the deadline and retained-config contract directly
// testable without requiring live MySQL/Redis services.
func openServerWithStores(config Config, openMySQL mysqlStorageOpener, openRedis redisCacheOpener) (*Server, error) {
	config = withConfigDefaults(config)
	switch config.StorageMode {
	case "", "memory":
		return NewServer(config), nil
	case "mysql":
		if config.DatabaseURL == "" {
			return nil, fmt.Errorf("RELAY_DATABASE_URL must be set when RELAY_STORAGE_MODE=mysql")
		}
		if config.RedisURL == "" {
			// Required: durable enrollment with a process-local nonce cache would
			// reopen the replay window on restart (see config validation).
			return nil, fmt.Errorf("RELAY_REDIS_URL must be set when RELAY_STORAGE_MODE=mysql")
		}
		startupCtx, startupCancel := context.WithTimeout(context.Background(), serverDependencyStartupTimeout)
		defer startupCancel()
		store, err := openMySQL(startupCtx, config.DatabaseURL, config.MaxEnrolledDevices)
		if err != nil {
			return nil, fmt.Errorf("open mysql store: %w", err)
		}
		redis, err := openRedis(startupCtx, config.RedisURL, config)
		if err != nil {
			// The MySQL store is already open; without this close its connection
			// pool (and the prune goroutine started by openMySQLStore) would be
			// leaked. mysqlStore.Close is idempotent, so this is safe even if the
			// store was never used.
			_ = store.Close()
			return nil, fmt.Errorf("open redis store: %w", err)
		}
		// Connection endpoints and the password are needed only while opening the
		// external stores. Do not retain them in the long-lived Server config or
		// expose them through diagnostics.
		config.DatabaseURL = ""
		config.RedisURL = ""
		config.RedisPassword = ""
		server := NewServer(config)
		server.store = store
		server.cache = redis
		server.hub.presence = redis
		server.startEventSubscribers()
		// Redis 激活时额外启动僵尸 peer 清扫，与事件订阅共用生命周期。
		server.startPresenceSweeper()
		return server, nil
	default:
		return nil, fmt.Errorf("unsupported storage mode %q", config.StorageMode)
	}
}

// RegisterRoutes 注册公开端点、内部管理端点、设备凭据端点和 v2 传输网络端点。
func (s *Server) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc(RouteHealthz, s.health)

	// Relay Internal Management API (/internal/v2/*).
	internalAuth := func(next http.HandlerFunc) http.HandlerFunc {
		return s.internalAuthMiddleware(next)
	}
	mux.HandleFunc(RouteInternalStatusV2, internalAuth(s.internalStatusHandler))
	mux.HandleFunc(RouteInternalDevicesV2, internalAuth(s.internalDevicesHandler))
	mux.HandleFunc(RouteInternalRevokeDeviceV2, internalAuth(s.internalRevokeDeviceHandler))
	mux.HandleFunc(RouteInternalTokenV2, internalAuth(s.internalTokenHandler))
	mux.HandleFunc(RouteInternalRotateTokenV2, internalAuth(s.internalRotateTokenHandler))
	mux.HandleFunc(RouteInternalTelemetryAttest, internalAuth(s.internalTelemetryAttestationHandler))

	// Device credential endpoints (V2 only).
	mux.HandleFunc(RouteEnrollV2, s.enroll)
	mux.HandleFunc(RouteRefreshV2, s.refresh)
	mux.HandleFunc(RouteTurnCredentialsV2, s.turnCredentials)

	// Transport Network V2（设计 §24）：控制面与数据面物理拆开。
	// GET /v2/control —— 长期存活的控制面，只走 RelayFrame（protobuf）。
	mux.HandleFunc(RouteControlV2, s.connectControlV2)
	// GET /v2/relay/{reservation_id} —— reservation 作用域的不透明数据面，只走
	// RelayDataFrame；reservation 由 /v2/control 的 RelayReserveRequest 创建（§25）。
	mux.HandleFunc(RouteRelayDataV2, s.connectRelayData)
}

// health 提供无需认证的存活检查端点。
func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}
