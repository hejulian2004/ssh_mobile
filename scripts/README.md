> Last updated: 2026-10-12

# Repository scripts

Agents choose the tree matching the actual host:

- `bash/` for Linux and WSL;
- `powershell/` for native Windows PowerShell 7.

Both trees use the same functional layout: `ci`, `coverage`, `contracts`,
`e2e`, `terminal`, `platform`, and `common`. A `.sh` and `.ps1` at the same
relative path and with the same base name form one maintenance unit. Update
their parameters, environment variables, steps, timeouts, cleanup, exit
semantics, and validation scope together.

`powershell/platform/` contains Windows-only toolchain and MSI packaging tasks,
and `powershell/common/` contains the shared native-process runtime. Their Bash
directories are intentionally documentation-only until Linux-specific
counterparts are needed.

The native network quality pair runs the common Rust format, workspace-test,
and Clippy gates on both platforms. Its coturn host-network fallback test is a
Linux-only capability: the PowerShell aggregate reports that step as an explicit
environment GAP after completing the common checks.

The CI aggregate entrypoints are intentionally thin dispatchers:
`ci/full_test.sh` and `ci/full_test.ps1` load paired configuration, runtime,
runner, App, and workspace/service helper modules. Each helper stays below the
500-line review limit by keeping functional and responsibility boundaries
cohesive; mechanically numbered chunks (`part_01`, `file_01`) and gratuitous
over-splitting are prohibited. The helpers preserve the same job names,
arguments, timeout behavior, cleanup, and exit statuses across hosts. The
GitHub Actions workflow is the authoritative full gate. Ordinary changes use
focused owner checks; run `bash scripts/bash/ci/full_test.sh` (or its native
PowerShell counterpart) only when aggregate local CI is explicitly requested.

The hosted Android build caches Cargo dependencies with an Android-specific key;
it does not restore host test `target` artifacts. Other native jobs retain their
platform/architecture target caches. Android still builds the full APK ABI set.

`e2e/online_e2e.sh` and `e2e/online_e2e.ps1` are an explicit external-deployment
gate. They are manual-only and never start Compose or join the routine CI
aggregate.
