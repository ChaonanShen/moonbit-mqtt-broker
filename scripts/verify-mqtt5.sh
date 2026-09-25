#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
moon fmt --check
moon check --target native --deny-warn
moon test --target native --deny-warn
moon build --target native
tests/integration/mqtt5.sh --prepared
echo 'MQTT5 verification passed'
