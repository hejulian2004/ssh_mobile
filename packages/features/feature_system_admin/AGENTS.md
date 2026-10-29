最新更新时间：2026-10-29

# feature_system_admin 维护约束

- Public API 只从 `feature_system_admin.dart` 使用。Connection catalogue, SSH
  sessions, monitoring, SFTP browsing, strings, and Host-Key UI arrive through
  Ports; never import another Feature/App `/src/`.
- `SystemAdminModule` owns management Service/session resources; Route VM owns
  only listeners/page state. Commands retain root, allowlisted actions,
  confirmation Token, cancellation, and timeout boundaries.
- No database or `system_admin.db`. Contract: allowed admin pages/VM/Module/
  command Service/Ports/tests; API changes sync App adapters/security tests;
  Module cancels commands before closing sessions, Route releases own listeners.
- The optional `monitoringConnectionId` page focus is presentation only. Never
  turn Widget navigation into selection, monitor start, SSH admission or a
  management command. Removed targets show an unavailable state and retain the
  existing public Port and Route-owned resource boundaries.

## 验证（代码变更）

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、
`flutter test`；local aggregate CI 仅按用户明确要求运行。
