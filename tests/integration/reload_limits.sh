#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
RELOAD_EVIDENCE_DIR="${RELOAD_EVIDENCE_DIR:-$REPO_ROOT/.local/reload-integration/limits-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
moon build --target native >/dev/null
readonly BROKER="$REPO_ROOT/_build/native/debug/build/cmd/broker/broker.exe"
work="$(mktemp -d)"
cleanup() {
  rc=$?
  mkdir -p "$RELOAD_EVIDENCE_DIR"
  printf 'case=reload_limits\nexit_code=%s\n' "$rc" >"$RELOAD_EVIDENCE_DIR/limits-summary.txt"
  rm -rf -- "$work"
  exit "$rc"
}
trap cleanup EXIT
check_limit() {
  local count="$1"
  cat >"$work/config.toml" <<EOF
[server]
listen = "127.0.0.1:1883"
[broker]
max_pending_per_session = $count
max_pending_total = $count
[reload]
enabled = true
manifest_file = "$work/manifest.toml"
EOF
  cat >"$work/manifest.toml" <<EOF
version = 1
[[materials]]
role = "config"
path = "$work/config.toml"
sha256 = "$(sha256sum "$work/config.toml" | cut -d' ' -f1)"
EOF
  chmod 600 "$work/manifest.toml"
}
check_limit 4096
"$BROKER" --check-config --config "$work/config.toml" >"$work/accepted.log" 2>&1
grep -q 'configuration valid' "$work/accepted.log"
check_limit 4097
if "$BROKER" --check-config --config "$work/config.toml" >"$work/rejected.log" 2>&1; then
  echo 'oversized reload queue configuration accepted' >&2
  exit 1
fi
grep -q 'reload requires max_pending_per_session at most 4096' "$work/rejected.log"
echo 'reload queue bound accepted at 4096 and rejected at 4097'
