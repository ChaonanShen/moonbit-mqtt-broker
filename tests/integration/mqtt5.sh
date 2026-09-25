#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
if [[ "${1:-}" != "--prepared" ]]; then
  moon build --target native
fi
if [[ ! -d tests/integration/node_modules/mqtt ]]; then
  npm ci --prefix tests/integration --ignore-scripts
fi
readonly BROKER="$REPO_ROOT/_build/native/debug/build/cmd/broker/broker.exe"
test -x "$BROKER"
readonly BASE="${MQTT5_EVIDENCE_DIR:-${RELEASE_ARTIFACT_DIR:-$REPO_ROOT/.local/mqtt5-integration}/run-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
mkdir -p "$BASE"
MQTT5_EVIDENCE_DIR="$BASE" timeout 180 node tests/integration/mqtt5.mjs "$BROKER"
MQTT5_EVIDENCE_DIR="$BASE" tests/integration/mqtt5_migration.sh --prepared
