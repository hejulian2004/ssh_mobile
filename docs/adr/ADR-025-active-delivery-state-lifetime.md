> 最新更新时间：2026-10-22

# ADR-025：Active Delivery State Lifetime

## 背景

`DeliveryManager` 的接收端同时承担应用 ACK、重复消息判断和
`SessionBoundOrdered` 顺序门控。此前 `InFlight`、ordered buffer 与已完成的
processed dedup history 共用一张带 TTL/容量淘汰的表；长时间运行的应用 handler
可能因此丢失 ACK 所需的记录，ordered channel 也可能永久卡在缺失的序号上。

## 决策

- `DeliveryManager` 分开保存 `incoming_active` 与 `processed_dedup`。
  `InFlight` 和 `OrderedBuffered` 只允许在应用 ACK、明确拒绝/abandon、逻辑
  Session close 或应用 ACK timeout 时清理。
- `dedup_ttl` 与 `dedup_max_entries` 只作用于 processed history。容量压力下
  不淘汰 active record；达到 active 上限时拒绝新消息，保留已有 ACK 合同。
- `SessionBoundOrdered` 的每个 `reorder_buffer` MessageId 必须同时存在于
  `incoming_active`。当前消息完成 ACK 时，状态转换和下一个 buffered 消息提升
  在同一个 Delivery store 锁内完成，并在 debug 构建中检查 invariant。
- `APPLICATION_ACK_TIMEOUT` 是独立于 processed dedup TTL 的策略。普通消息超时
  释放其 active record；严格 ordered channel 超时会整体进入 Failed 并清空
  buffer，不自动跳过 Sequence。关闭 Session 会清除其接收端 active、processed、
  ordered 和 failed-channel 状态，但不替调用方取消 outgoing pending。

## 后果

长 handler 即使超过 processed dedup TTL 也能正常提交应用 ACK，ordered 消息会按
`0 → 1 → 2` 继续推进。Processed history 仍然有界，因此不会承诺永久 Exactly
Once；历史窗口之外的旧 duplicate 可能重新成为新消息。Active timeout 的失败
语义显式可观察，避免通过静默删除或跳序掩盖应用未完成状态。

## 验证

`native/network_core/crates/network-core/src/tests/delivery.rs` 覆盖 active 超过 TTL、
ordered buffer 超过 TTL、processed capacity 淘汰、application ACK timeout 和
Session close；`src/tests/runtime_integration/relay_data_and_runtime_lifecycle.rs`
通过 Runtime owner 验证 TTL 扫描不会清理 active
state，显式 peer disconnect 会清空接收端状态。

## 状态

Accepted
