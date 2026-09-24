#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
RELOAD_EVIDENCE_DIR="${RELOAD_EVIDENCE_DIR:-$REPO_ROOT/.local/reload-integration/reload-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
moon build --target native >/dev/null
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
  grep -E 'event=(broker_listening|reload_completed|reload_no_change|shutdown_requested|reload_failed)' \
    "$work/broker.log" >"$RELOAD_EVIDENCE_DIR/lifecycle-events.log" 2>/dev/null || true
  printf 'case=reload_lifecycle\nexit_code=%s\n' "$rc" \
    >"$RELOAD_EVIDENCE_DIR/lifecycle-summary.txt"
  rm -rf -- "$work"
  exit "$rc"
}
trap cleanup EXIT
mqtt_port="$(node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
admin_port="$(node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
cat >"$work/tokens" <<EOF
spike-token:dc211f3214c8dc9ccfdf0c2f2835ed515fc2e032d912934e1d700f8374747236:config_admin
EOF
chmod 600 "$work/tokens"
cat >"$work/config.toml" <<EOF
[server]
listen = "127.0.0.1:$mqtt_port"
[observability]
log_level = "info"
[management]
enabled = true
listen = "127.0.0.1:$admin_port"
token_file = "$work/tokens"
details_enabled = false
operations_enabled = false
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
node tests/integration/reload_lifecycle.mjs \
  "$admin_port" "$work/config.toml" "$work/manifest.toml" "$broker_pid"
kill -TERM "$broker_pid"
wait "$broker_pid"
broker_pid=""
echo 'reload lifecycle passed'

