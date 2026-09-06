#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
moon build --target native
timeout 180 node tests/integration/qos2.mjs "$REPO_ROOT/_build/native/debug/build/cmd/broker/broker.exe"
