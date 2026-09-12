#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
python3 -B tools/runtime_reference_test.py
moon build --target native
timeout 240 node tests/integration/resource_limits.mjs "$REPO_ROOT/_build/native/debug/build/cmd/broker/broker.exe"
echo 'RESOURCE LIMITS verification passed'
