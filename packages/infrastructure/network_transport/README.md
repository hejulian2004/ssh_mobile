最新更新时间：2026-09-07

# network_transport

`network_transport` 是 App Scope 唯一网络运行时的稳定 Facade。它包装
`ssh_mobile_network_native` 提供的原生运行时，不在 Dart 层复制 TCP、UDP、QUIC
或 WebRTC 协议实现。

## 边界

- `NetworkRuntime` 由 AppRuntime 创建和释放，Feature 只能通过依赖注入使用；
- Capability 初始化按需进行，支持并发共享、失败重试和 dispose 后拒绝使用；
  `NetworkCapability.runtime` 只表示 native command-worker handle 存在，与
  QUIC、WSS Relay 和 Realtime 等具体 transport capability 分离；
- Wave 1 中唯一的数据面配置仍走现有 `ConfigureRuntime`，该入口会无条件初始化
  直接 QUIC/TCP 基础设施；真正的 QUIC-free WSS-only 数据面路径推迟到后续协议
  能力切换（Wave 2），当前并不存在。`runtime` 就绪并不代表 WSS 数据面已独立配置；
- `NetworkRuntime.diagnostics` 只报告 Facade 自己拥有的 ready Capability、native
  handle 和已登记连接；当前具体协议连接仍由各协议 Service Owner 管理，因此
  `activeConnections` 在尚未登记连接时为零；
- 原生 handle 的 `create -> start -> stop -> destroy` 由底层 adapter 明确拥有；
- `NetworkRuntime.diagnostics.boundLocalPort` 只读投影 native 实际绑定端口，供
  App Shell 将独立的可靠传输端点适配给 LAN Share；Feature 不直接读取 native
  handle，也不据此取得 Runtime 所有权；
- `TransportEndpoint`、`TransportConnection` 和 metrics 是供上层模块使用的稳定
  基础合约；具体 LAN、SSH、SFTP 业务协议不归本包所有；
- `NetworkCommandGateway` 是连接 App Scope Runtime 与现有 Network Protocol V2 命令/事件服务的
  非拥有型桥接；它可以被 App Shell adapter 借用，但不会复制或关闭 native handle；
  `openCommandGateway()` 只要求 `runtime` capability，不会隐式启用 QUIC；
- `openRealtimeGateway()` 返回同一 Runtime-owned native handle 上的非拥有型 typed
  Realtime gateway；start/stop 返回带 `commandId` 和 queue status 的
  `NativeCommandTicket`，App Shell 负责关联 `NativeCommandResultEvent` 和映射状态，
  Feature 不得直接消费该 gateway。其 media endpoint create/release 还必须接收
  native-authoritative generation，并只返回 opaque endpoint/status。
- LAN Share 通过公共合约消费注入的 Runtime/Gateway；配对、传输和 Feature
  生命周期仍由 `feature_lan_share` 拥有，本 Facade 不复制其业务协议。

## 验证

```bash
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

## Package contract

- 职责：提供 App Scope 网络 Facade、Capability 初始化、native handle 适配和传输契约。
- 不负责：具体 LAN/SSH/SFTP 业务协议、Feature 连接 Owner 或第二套 native 实现。
- Public API：`package:network_transport/network_transport.dart`，包括
  `NetworkRuntime`、`NetworkCommandGateway`、`NetworkRealtimeGateway`、
  `NativeCommandTicket` 和传输契约。
- 依赖：`app_core` 和 `ssh_mobile_network_native`。
- 数据库：不拥有数据库。
- 生命周期与资源 Owner：AppRuntime 拥有 `NetworkRuntime`；Runtime/adapter 负责
  native handle 的 `create/start/stop/destroy`，Feature 只能使用注入的 Capability。
  Gateway 及其事件订阅由借用方释放，但借用方不得停止或销毁 Runtime/native handle；
  Realtime session 必须在 Runtime dispose 前停止；App Shell adapter 还必须清理
  pending command tickets、取消结果超时和释放事件订阅。
- 测试命令：`flutter analyze --no-pub`、`flutter test --no-pub`；native hook 变更时
  还需运行对应 Rust toolchain 检查。
