#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
moon fmt --check
moon check --target native --deny-warn
moon test --target native --deny-warn
tests/integration/qos2_interop.sh
echo 'QOS2 verification passed'
