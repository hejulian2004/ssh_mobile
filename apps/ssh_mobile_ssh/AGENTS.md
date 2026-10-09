最新更新时间：2026-10-09

# SSH-only App Guidelines

- This App owns the direct TCP SSH composition. Do not copy Full App
  business Services or create a `NetworkRuntime`.
- `SshOnlyAppRuntime` owns App Scope resources. The root State is an
  awaitable, idempotent exit owner: release the route first, then
  ViewModel → Terminal Module → SSH → database → ports → logger.
- Use only public package entry points. Do not import another package's
  `/src/` or add `network_transport`, `network_sdk`, LAN Share, SFTP, AI,
  RAG, MCP, WebView, screen share, or realtime media.
- Unknown host keys fail closed unless the visible page confirms them.
  A configured jump host fails before a socket opens.
- `TerminalModule` owns `terminal.db`. Connection structure stays in
  `connection_core`; passwords and private keys stay in secure storage.

## Validation for code changes

`flutter pub deps`, `flutter analyze`, and `flutter test` (package-local;
local aggregate CI remains user-opt-in). Dependency output must not contain
`network_transport`, `network_sdk`, `ssh_mobile_network_native`,
`feature_lan_share`, `feature_sftp`, or `feature_ai`.

`lib/main.dart`, `SshAppBootstrap.run`, and `SshOnlyAppRuntime.create` are
recorded process-entry exclusions. They bind Flutter, open the platform
Connection database and secure storage, and call `runApp`. Do not add a
test-only hook to execute them. `forTesting` covers the release order.
