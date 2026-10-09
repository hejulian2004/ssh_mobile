> Last updated: 2026-10-09

# Repository Bootstrap

SSH Mobile is a Flutter SSH/SFTP client with Client Features, a Rust network
SDK, Go Relay/control plane, and React administration console. This file is the
mandatory entry point, not an architecture or command catalogue.

## Required reading chain

Before any scoped knowledge, local contract, ADR, or Architecture document:

1. read this bootstrap;
2. read the [canonical maintenance Skill](.agents/skills/ssh-mobile-maintenance/SKILL.md);
3. use the [Memory Map](.agents/skills/ssh-mobile-maintenance/references/memory-map.md)
   to load only relevant knowledge;
4. inspect `git status`, locate real owning paths, then read every nearer
   `AGENTS.md` and each Workspace Member `README.md`.

Code/tests define current behavior; Accepted ADRs define decisions; a nearer
`AGENTS.md` may tighten but never relax these rules. Ownership and update rules
are in [Skill & Memory Maintenance](docs/agent/skill-memory-maintenance.md).

## Domains and local contracts

- Client: `apps/`, `packages/core/`, `packages/features/`,
  `packages/infrastructure/ssh_core/`.
- SDK: `native/network_core/`, `protocol/`, `network_sdk`, `network_transport`,
  `ssh_mobile_network_native`.
- Backend: `relay/`; Front: `front/`; `docs/`, `tool/`, `scripts/`, `.github/`,
  and platform/installer paths follow the owner of the behavior they verify.

Each App/Package Workspace Member keeps a `README.md` and `AGENTS.md`: README
owns responsibility, public API, dependencies, storage, lifecycle owner, and
validation entry points; AGENTS owns edit scope, forbidden dependencies,
API/storage/release constraints, and required checks. Keep every Workspace
Member local contract; Memory is not a replacement.

## Non-negotiable boundaries

- Implement in the owning layer and call other packages only through public
  entry points; never import another package's `/src/` or duplicate its owner.
- App/Module/Route resources have explicit owners and release paths. Borrowers
  release only their lease/subscription, not an owner's session, database,
  native handle, or runtime.
- Structured data stays in its owning database; App diagnostics stay separate;
  production database-open failure never silently chooses an in-memory fallback.
- Secrets and user-private data stay out of source, logs, tests, fixtures,
  screenshots, traces, exports, Skill, and Memory; use platform secure storage.
- Remote writes and sensitive reads use immutable target/action approval,
  redaction, host-key verification, and fail-closed execution. Do not weaken
  destructive-command, sensitive-path, sandbox, transport-auth, Delivery,
  Session-routing, or E2EE protections.
- Test instrumentation belongs in independent test files; do not add test-only
  fields/hooks/observers to production modules. Edit generator inputs, not only
  generated output; route diagnostics through the injected logger.
- Hand-written production files over 500 lines require responsibility-based
  decomposition, never numbered chunks or gratuitous splitting. Tests/fixtures
  use `test/` or `tests/`; native exceptions are Go `_test.go`, Rust
  `#[cfg(test)]`/`src/tests`, and TypeScript `.test`/`.spec`.
- Preserve unrelated worktree changes and do not broaden diagnosis, review, or
  docs-only work into implementation.

## Test-first rule

Observable/automatable behavior uses Red → Green → Refactor at the lowest
reasonable layer; bugs start with a regression test, new behavior with an
observable failure, and risky uncovered code with a characterization test.
Assert public results/invariants, never weaken or skip a failure. Pure docs,
formatting, generated output, behavior-free configuration, and visual-only
changes are the documented exceptions. Details and owner focus are in
[Maintenance Workflow](.agents/skills/ssh-mobile-maintenance/references/workflow.md).

## Documentation, validation, and CI

Maintained Markdown begins with `Last updated: YYYY-MM-DD` (English) or
`最新更新时间：YYYY-MM-DD` (Chinese), updated with content. Select checks from
[Validation](.agents/skills/ssh-mobile-maintenance/references/validation.md);
always run `git diff --check`, inspect status/final diff, and report only checks
actually run with exact gaps.

本地 CI 仅在用户明确提及时运行；常规改动按受影响 Owner 做 format/diff/focused
检查。用户要求发起 PR 时，完成最小门禁后可提交、推送并发起 PR，由 GitHub
Actions 的并行 jobs 作为 CI 基准。推送/发起 PR 后立即按 commit/run 绑定启动后台
watcher；watcher 失败时读取失败 job 日志、自动完成最小修复并重新推送，然后重启
watcher，直到通过或遇到明确阻塞。遗漏、GAP、超时或失败都不是 PASS；不自动批准
或合并，合并权只属于用户。
四大领域 coverage 门禁及新手写生产文件的独立测试/90% 文件覆盖率要求仍适用；
coverage 旧别名保持兼容。Bash/PowerShell 同相对路径脚本须同步参数、环境、
步骤、超时、清理、退出语义和范围，且按实际主机使用 Linux/WSL Bash 或原生
Windows PowerShell 7。

Windows/WSL 双 checkout 是两套独立代码树：WSL 工作树位于 Linux 文件系统，
Windows 原生 checkout 固定为 `E:\coding\ssh_mobile`。两套代码只通过 Git 的
提交、推送、拉取或切换分支同步，禁止直接复制文件、共用工作树或把 `/mnt/e`
当作 WSL 的编辑目录。WSL 与 Windows 的 Flutter/Dart、Rust/MSVC、Android、
Gradle、Cargo/Pub/SDK 缓存、TEMP/TMP 和构建输出必须分别归属各自主机；默认不
交叉调用工具链。只有明确执行 Windows 端打包/设备测试时，才允许通过 WSL
interop 调用原生 Windows PowerShell，并且命令必须指向该 Windows checkout 和
Windows 工具链，不能把 Windows 产物写回 WSL checkout。

`CLAUDE.md` 只是指向本文件的薄入口；canonical Skill 只维护在 `.agents/`。
仅在用户要求或批准计划需要时提交；显式 stage，绝不带入无关工作。

异步工具：空 `write_stdin`/`functions.wait` 使用至少 180 秒（无中间输出时优先
300 秒），外层 `functions.exec` 比最长嵌套等待多 30 秒；交互式写入例外，完成
前不为“仍在运行”唤醒模型。
