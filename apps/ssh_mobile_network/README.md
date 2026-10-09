最新更新时间：2026-10-09

# ssh_mobile_network

网络传输 App 组合 `feature_lan_share` 的网络传输页。页面包含设备列表、传输历史、
扫码和手动添加、配对、聊天、网页快传、设置，以及传入传输和配对导航宿主。

它装配 `app_core`、`app_ui`、`feature_lan_share`、`network_sdk` 和
`network_transport`。完整版 `ssh_mobile_full` 保持原有组合根，本 App 不复制
`NativeNetworkService`。因此 `borrowFacade` 返回 null：发现、配对和 LAN 控制面
可以运行，原生文件传输和 Relay 数据面仍只在完整 App 中可用。屏幕共享保持关闭。

## 生命周期

- `NetworkTransportAppRuntime` 持有 Logger、`NetworkRuntime`、LAN 设置、身份、
  数据保护和 Bootstrap 客户端；
- `LanShareModule` 持有 `lan_share.db`。生产启动启用接收器，接收器只会确保
  `NetworkCapability.runtime`，不会从本 Shell 启用 QUIC、WebSocket Relay 或
  Realtime，也不会调用 `NetworkFacade.start`；
- `NetworkTransportAppState` 是可等待、幂等的 Widget Owner。退出时先卸载页面，
  再释放 Module、设置、NetworkRuntime 和 Logger。单项失败仍继续，并重新抛出
  第一个错误；
- 身份和数据保护使用本 App 自己的 `network_app_*_v1` 安全存储键。

## 验证

```bash
flutter pub deps
flutter analyze
flutter test
```

本包依赖树必须包含 `feature_lan_share`、`network_sdk` 和 `network_transport`，
并且不能包含 `ssh_core`、`feature_terminal`、`feature_connection`、
`feature_sftp`、`feature_ai`、`feature_screen_share` 或 `dartssh2`。

## 覆盖率排除

下列入口会打开平台安全存储或平台数据库，widget 测试改走 `open`。
页面测试在 App 外提供 Feature 已支持的 `LanShareViewModel`，因此不会启动真实
mDNS/UDP。生产 `create()` 仍启用接收器，并且只确保 `NetworkCapability.runtime`。

- `lib/main.dart`：委托给 `NetworkAppBootstrap.run`，用 `coverage:ignore` 标记。
- `lib/app/network_app_bootstrap.dart`：绑定 Flutter 并 `runApp`。
- `NetworkTransportAppRuntime.create`：创建平台 `NetworkRuntime`、安全存储和
  平台 `LanShareDatabase`。
- `FlutterNetworkSecretStore`：只转发到 `FlutterSecureStorage`。

## Package contract

- 职责：作为网络传输页的组合根，注入 LAN Port 并展示 `LanShareScreen`。
- 不负责：SSH、终端、连接配置、SFTP、AI、屏幕共享，以及原生 `SessionClient`。
- Public API：`NetworkTransportAppRuntime` 及应用入口。
- 依赖：`app_core`、`app_ui`、`feature_lan_share`、`network_sdk`、
  `network_transport`、`cryptography`、`flutter_secure_storage`、`provider`。
- 数据库：`LanShareModule` 拥有 `lan_share.db`。生产打开失败不会退回内存库。
- 生命周期与资源 Owner：Runtime 拥有网络运行时、设置、身份、数据保护和 Logger。
  Module 拥有数据库和接收器。Feature 不释放 Runtime。
- 测试命令：`flutter pub deps`、`flutter analyze`、`flutter test`。
