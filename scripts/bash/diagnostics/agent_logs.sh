#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd -- "$repository_root"
exec dart run "$repository_root/tool/agent_logs.dart" "$@"
