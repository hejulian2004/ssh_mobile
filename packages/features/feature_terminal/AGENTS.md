最新更新时间：2026-10-22

# feature_terminal 维护约束

- Owns terminal page/interactive VM, history model, and `terminal.db`.
  SSH comes from injected `ssh_core.SshSessionManager` into
  `TerminalFeatureScope` and the ViewModel. Presentation reads only that
  ViewModel and does not import `ssh_core`. Never create
  `SshService`/`SshSessionManagerImpl`/a global connection owner. Public API is
  only `lib/feature_terminal.dart`; text/settings/commands/connection/logs arrive through
  Ports. `TerminalFeatureScope` owns Provider composition; App/Terminal-only
  inject public Ports but cannot close other App resources.
- Route Scope creates VM and releases listeners/Timers/Controllers/SSH listeners.
  `TerminalModule` owns DB/Repository and stops active work before close; one
  generation/serial barrier prevents late initialization publication and closes
  a late local DB. History service uses injected protection/log/path Ports;
  compatibility facade is App-provided and SSH Owner disposes it. History loading
  and renderer backpressure retain latest tail under a hard bound; old plaintext
  history migrates by streaming encrypted same-filesystem replacement and never
  replaces source before success.
- Contract: allowed terminal pages/VM/history Repository/Module/Scope/Ports/tests;
  no other Feature/App `/src/`, unified storage, or self-created App SSH Manager.
  API changes sync Terminal-only App; Module owns `terminal.db`, Route owns page
  resources, AppRuntime owns SSH.

## 验证（代码变更）

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、
`flutter test`；local aggregate CI 仅按用户明确要求运行。
