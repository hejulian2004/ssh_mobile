> 最新更新时间：2026-10-22

# Relay 控制面

## 定位

Go Relay（`relay/`）负责鉴权、presence、discovery 存储、peer 信令转发和 Relay
可达性。候选可达性、NAT、QUIC 和路径选择属于 native SDK。Relay 是 fallback，
不承载大流量业务明文。

当前行为以 [Backend current state](../../memory_docs/backend/current-state.md)、
[Relay README](../../relay/README.md) 和下面列出的 ADR 为准。

## 当前边界

- Bootstrap 只有 `POST /v2/devices/enroll` 与 `POST /v2/devices/refresh`
  （`protocol_version=2`）。`/v1/*` bootstrap 已清退。
- 控制面与数据面物理分离：`/v2/control` 与
  `/v2/relay/{reservation_id}`。控制连接不承载文件块或 Delivery payload。
- 部署是单 Relay Control + 单 Relay Data 实例。`RELAY_STORAGE_MODE=mysql`
  用 MySQL 持久化 enrollment/revocation，并要求 Redis 承载 presence、discovery、
  防重放 nonce、reservation 和共享事件。依赖或安全状态失败时 fail closed。
- 在线判定以 `ResolvePeer` 为准。Presence 只提供 hint。连接建立时选定 Route，
  之后不做 Relay 到 Direct 的后台原子升级。
- `Global Control Routing` 与 `Relay Data Node Selection` 未实现，不能把当前
  部署说成多实例数据面。

## 已从主链移除

这些 v1 行为不再代表当前实现：

- 单 socket `/v1/connect` 同时承载控制 JSON 和 binary 数据帧。
- 控制帧 `channel_message`、`channel_ack`、`crypto_handshake`。
- 用 Unix-ms `generation` 作为 discovery 版本。当前是 `runtime_epoch` 加
  同一 epoch 内的 revision。
- lookup 的 fail-open `online` 布尔。
- Relay 建连后的 2 秒 direct-upgrade 探针和原子换路。ADR-018 已取代。
- 把 presence 当作在线权威。

取代关系见 [ADR-DISCOVERY-V2](../adr/ADR-DISCOVERY-V2.md)、
[ADR-CONNECTION-LIFECYCLE-V2](../adr/ADR-CONNECTION-LIFECYCLE-V2.md)、
[ADR-RELAY-DATA-PLANE-V2](../adr/ADR-RELAY-DATA-PLANE-V2.md) 和
[ADR-TRANSPORT-NETWORK-V2](../adr/ADR-TRANSPORT-NETWORK-V2.md)。
存储面见 [Redis 与 MySQL 会话存储](REDIS_MYSQL_SESSION_STORAGE_PLAN.md)。
