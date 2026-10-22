> 最新更新时间：2026-10-22
> 状态：单实例 Phase 0–4 已实施；跨实例数据面仍 deferred
> 适用对象：Go Relay 控制面（`relay/`）后端

> **当前实现边界**：`RELAY_STORAGE_MODE=mysql` 使用 MySQL 持久化 enrollment /
> revocation，并强制配置 Redis 承载 presence、discovery、防重放 nonce、管理员会话、
> reservation 与共享事件。Redis 在该模式下是安全依赖，启动或鉴权/状态操作失败时
> fail closed，不回退到进程内防重放状态。数据面仍是单 Relay Control + 单 Relay Data
> 实例；权威当前状态见
> [`memory_docs/backend/current-state.md`](../../memory_docs/backend/current-state.md)。
>
> **2026-08-15 修订（对齐 transport-network v2）**：本计划原文按「多实例」设计
> 状态/缓存面。transport-network v2（Main 基线版 §26，
> [ADR-TRANSPORT-NETWORK-V2](../adr/ADR-TRANSPORT-NETWORK-V2.md)）第一阶段明确
> **单 Relay Control + 单 Relay Data 实例**；Redis 为外部共享 live state
> （跨实例 presence/discovery 同步）。`Global Control Routing` /
> `Relay Data Node Selection` 未完整实现前不得宣称 Multi-instance supported。
> 下文所有「多实例」表述已收敛为单实例部署语义。

# Redis + MySQL 会话存储接入计划

## 0. 摘要

Go Relay 控制面已引入 MySQL（持久化 source of truth）与 Redis（短生命周期共享状态），
形成**可持久化**的会话/鉴权/状态架构；随附 Compose 部署默认启用这两个服务并使用
持久化 named volume。部署拓扑为**单 Relay Control + 单 Relay Data 实例**，Redis
为外部共享 live state；进程级 `memory` 仍保留给显式的本地测试。

**本轮范围边界**：只做**状态/缓存面**接入 MySQL / Redis 共享 live state。数据面
（两个设备之间的 WS 控制帧转发）保持单实例；多实例部署与跨实例数据面转发
（`Global Control Routing` / `Relay Data Node Selection`）列为后续里程碑（见下文里程碑）。

**核心不变量**：
- MySQL 是 enrollment 与吊销的**唯一持久化 source of truth**。
- Redis 只承载**短期、可重建、高频**状态（在线 presence、防重放 nonce、admin 会话、传输会话元数据），全部带 TTL。
- MySQL/Redis 运行依赖或安全状态不可用时 **fail closed**；不得回退到
  会重新打开 replay window 的进程内 nonce 状态。
- 存储模式在进程启动时显式选择；Compose 默认注入 `mysql`，本地 memory 必须显式
  opt-in；不把进程内 enrollment 隐式导入持久层。

---

## 1. 已锁定决策（`/grill-me` 会话产出）

| # | 决策 | 结论 |
|---|------|------|
| Q1 | 会话范围 | 客户端↔Relay 鉴权 + 连接状态；SSH 隧道状态留在 native SDK 内存态；Admin 会话本轮一并覆盖 |
| Q2 | 部署拓扑 | 第一阶段**单实例**部署；Redis 承载共享 live state（其键结构支持跨实例 presence/discovery 同步） |
| Q3 | 持久化边界 | MySQL = enrollment/吊销唯一持久化准；Redis = 短期可重建态，全 TTL；审计表未进入当前交付 |
| Q4 | 一致性 | **cache-aside 失效式**：先写 MySQL → 删/失效 Redis key → TTL 兜底 |
| Q5 | 共享状态事件 | Redis Pub/Sub 广播 `session.invalidate` / `device.revoked` 等事件 |
| Q6 | Token 形态 | **适配现状**：不新造双 token 签发；enrollment（deviceID+公钥）落 MySQL，连接态/防重放/presence 落 Redis，保住无状态 HMAC 凭据 |
| Q7 | 降级 | **已按实现修正为 fail-closed**：mysql 模式强制 Redis，启动与安全状态操作失败均不得回退到进程内 nonce/cache |
| Q8 | 升级 | 统一鉴权校验入口；Compose 默认启用持久化存储，memory 仅显式 opt-in，不隐式迁移进程内状态 |
| Q9 | 数据面 | 本期数据面保持单实例（单 Relay Control + 单 Relay Data 实例）；跨实例转发后续里程碑 |

---

存储和管理面没有按当时拟议的独立子目录落地。MySQL/Redis 实现在
`relay/internal/relay/mysql_store.go`、`relay/internal/relay/cache.go`、
`relay/internal/relay/redis_cache.go`；管理面在 `relay/internal/admin/`。

## 2. 一致性 / 降级 / 安全

- **一致性**：写路径统一"先 MySQL → 失效 Redis 读缓存 → 发事件"。不引入分布式事务/锁；enrollment 与吊销以 MySQL 行为准，Redis 读缓存 TTL 兜底防脏。防重放靠 Redis SETNX 原子性，无竞态窗口。
- **降级（fail-closed）**：mysql 模式要求 Redis。启动时无法建立 MySQL/Redis
  连接则拒绝启动；运行中的 nonce、鉴权、presence、discovery、reservation 或管理
  会话操作失败时拒绝对应请求，不回退到会重新打开 replay window 的进程内状态。
- **MySQL 故障**：鉴权是裁决路径 → **fail-closed**（无法裁决即拒绝），加告警与熔断；不把 MySQL 当缓存层弱化其权威地位。
- **凭据安全**：`CredentialKey` 与 DB/Redis 口令经 env/密钥管理注入，**不得入库、日志、文档**（遵循仓库 CLAUDE.md 规则）。审计表不存凭据明文。

---

## 3. 配置与部署

- 当前 env：`RELAY_DATABASE_URL`（MySQL DSN）、`RELAY_REDIS_URL`、
  `RELAY_STORAGE_MODE`（Go 进程默认 `memory`；bundled Compose 默认注入
  `mysql`）。完整配置归属 `relay/.env.example` 与 `relay/README.md`。
- 根 `compose.yaml`：Relay 默认启用 `mysql`、`redis` 服务 + 数据卷与健康依赖；
  `storage` profile 仅额外启用 Analytics 服务；Caddy 拓扑保持。
- **第一阶段部署为单 Relay Control + 单 Relay Data 实例**：单实例共享同一 `CredentialKey`（env）；presence 路由与 Pub/Sub 事件在同一实例内闭环。多实例部署（`Global Control Routing` 与 `Relay Data Node Selection`）未完整实现前不支持，也不在 compose 中提供 LB 实例亲和路由。
- 密钥/口令走环境注入或密钥管理，不进 compose 明文（生产用 secret 文件/外部注入）。

---

## 4. 已实施顺序与剩余边界

1. **Phase 0 — 已完成**：`Storage`/`Cache` 接口与默认 `memory` 实现（供显式本地测试）。
2. **Phase 1 — 已完成**：MySQL 持久化 enrollment/revocation；bundled Compose 默认
   启用 MySQL/Redis，不提供隐式进程内状态迁移。
3. **Phase 2 — 已完成当前范围**：Redis 承载 presence、discovery、nonce、admin
   session、reservation 与共享事件；活跃 Relay Data pair 仍由单实例内存 owner 持有。
4. **Phase 3 — 已完成**：设备鉴权收敛到统一入口，README 与 Backend Memory 记录
   两种存储模式的重启语义。
5. **Phase 4 — 已完成单实例范围**：MySQL/Redis 状态面在**单 Relay Control + 单
   Relay Data 实例**拓扑下由存储/缓存与 Compose integration tests 守卫；Pub/Sub
   踢人/吊销在同一实例内闭环。多实例
   部署（`Global Control Routing` / `Relay Data Node Selection`）列为后续里程碑
   （见下文里程碑），不在第一阶段范围。

每 Phase 完成必须回到"可分析、可测试"状态再进入下一 Phase（对齐仓库维护 Skill 的验证门禁）。

---

## 5. 验证方案

- **单元**：`Storage`/`Cache` 接口用内存实现做 fake；现有 `relay/` Go 测试全部通过；新增存储层单测（upsert/吊销/缓存失效）。
- **集成**（compose 起 mysql+redis）：重启存活（enroll → 重启 relay → 凭据仍有效，
  不再需要重新 enroll）；吊销会断开设备；依赖或安全状态错误 fail closed；重复登录
  踢旧连接。多实例跨实例行为不在第一阶段验证范围。
- **工具**：`go test ./...`、`go vet ./...`；CI 视需要新增 Go 存储 job（对齐现有 `.github/workflows/`）。
- **手动回归**：对照 `relay/README.md` 部署文档走一遍 enroll → 连接 → 传输 → 吊销全流程。

---

## 6. 里程碑与范围边界

- **本期（M1）**：Phase 0–4 全部落地，交付可持久化的会话/鉴权/状态面；部署拓扑为单 Relay Control + 单 Relay Data 实例，Redis 为共享 live state；数据面保持单实例。
- **后续（M2，显式 deferred）**：多实例部署与跨实例数据面转发（两个设备落在不同实例时控制帧的桥接/路由）——需先完整实现 `Global Control Routing` + `Relay Data Node Selection` 再开放（见 [ADR-TRANSPORT-NETWORK-V2](../adr/ADR-TRANSPORT-NETWORK-V2.md)）；独立工程，等真实多实例流量需要时再启动。
- 传输会话迁 Redis（`transfer:{session_id}`）为**可选**：若短期内传输会话无需跨连接/跨实例接管，可保留进程内实现，presence 与鉴权先行。
