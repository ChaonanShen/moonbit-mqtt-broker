#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
mode="${RELOAD_TEST_MODE:-off}"
case "$mode" in off|snapshot|strict) ;; *) echo "invalid reload test mode: $mode" >&2; exit 2 ;; esac
RELOAD_EVIDENCE_DIR="${RELOAD_EVIDENCE_DIR:-$REPO_ROOT/.local/reload-integration/security-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
moon build --target native >/dev/null
if [[ ! -d tests/integration/node_modules/mqtt ]]; then
  npm ci --prefix tests/integration --ignore-scripts >/dev/null
fi
readonly BROKER="$REPO_ROOT/_build/native/debug/build/cmd/broker/broker.exe"
work="$(mktemp -d)"
broker_pid=""
cleanup() {
  rc=$?
  if [[ -n "$broker_pid" ]]; then
    kill -TERM "$broker_pid" 2>/dev/null || true
    wait "$broker_pid" 2>/dev/null || true
  fi
  mkdir -p "$RELOAD_EVIDENCE_DIR"
  grep -E 'event=(broker_listening|reload_completed|reload_failed|shutdown_requested)' \
    "$work/broker.log" >"$RELOAD_EVIDENCE_DIR/security-$mode-events.log" 2>/dev/null || true
  printf 'case=reload_security\nmode=%s\nexit_code=%s\n' "$mode" "$rc" \
    >"$RELOAD_EVIDENCE_DIR/security-$mode-summary.txt"
  rm -rf -- "$work"
  exit "$rc"
}
trap cleanup EXIT
port="$(node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
cat >"$work/config.toml" <<EOF
[server]
listen = "127.0.0.1:$port"
EOF
if [[ "$mode" != off ]]; then
  cat >>"$work/config.toml" <<EOF
[persistence]
mode = "$mode"
data_dir = "$work/data"
EOF
fi
cat >>"$work/config.toml" <<EOF
[security]
allow_anonymous = true
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
: >"$work/broker.log"
setsid stdbuf -oL -eL "$BROKER" --config "$work/config.toml" \
  >"$work/broker.log" 2>&1 &
broker_pid=$!
for _ in $(seq 1 800); do
  if grep -q broker_listening "$work/broker.log"; then break; fi
  if ! kill -0 "$broker_pid" 2>/dev/null; then cat "$work/broker.log" >&2; exit 1; fi
  sleep 0.025
done
grep -q broker_listening "$work/broker.log"
node tests/integration/reload_security.mjs \
  "$port" "$work/config.toml" "$work/manifest.toml" \
  "$work/passwords" "$work/acl.txt" "$work/broker.log" "$broker_pid" "$mode" "$work/data"
kill -TERM "$broker_pid"
wait "$broker_pid"
broker_pid=""
echo "reload security $mode passed"
