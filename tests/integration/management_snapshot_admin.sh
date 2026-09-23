#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
readonly ROOT
cd "$ROOT"
moon build --target native
if [[ "$#" -eq 0 || "$1" != "--prepared" ]]; then
  npm ci --prefix tests/integration --ignore-scripts >/dev/null
fi
work="$(mktemp -d)"
pid=""
cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf -- "$work"
}
trap cleanup EXIT
free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}
mqtt_port="$(free_port)"
admin_port="$(free_port)"
token='snapshotadmin.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
node -e 'const c=require("crypto");const t=process.argv[1];console.log("snapshotadmin:"+c.createHash("sha256").update("moonbit-mqtt-broker/admin/v1:"+t).digest("hex")+":read,operator")' "$token" >"$work/tokens"
chmod 0600 "$work/tokens"
broker="$ROOT/_build/native/debug/build/cmd/broker/broker.exe"
start_broker() {
  local phase="$1" debounce="$2"
  "$broker" --listen "127.0.0.1:$mqtt_port" --data-dir "$work/data" \
    --rate-limits-enabled false --per-ip-limits-enabled false \
    --snapshot-debounce-ms "$debounce" --snapshot-max-delay-ms "$debounce" \
    --management-enabled true --management-details-enabled true \
    --management-operations-enabled true --management-max-bytes-total 33554432 \
    --management-listen "127.0.0.1:$admin_port" \
    --management-token-file "$work/tokens" >"$work/$phase.log" 2>&1 &
  pid="$!"
  for _ in $(seq 1 100); do
    if curl -fsS --max-time 1 "http://127.0.0.1:$admin_port/health/live" >/dev/null 2>&1; then return; fi
    if ! kill -0 "$pid" 2>/dev/null; then cat "$work/$phase.log" >&2; exit 1; fi
    sleep 0.05
  done
  echo "snapshot broker failed to start: $phase" >&2
  exit 1
}
stop_broker() {
  kill -TERM "$pid"
  wait "$pid"
  pid=""
}
run_action() {
  node tests/integration/management_snapshot_admin.mjs "$1" \
    "$mqtt_port" "$admin_port" "$token" "$2"
}
start_broker normal 100
run_action create normal-session
run_action delete normal-session
stop_broker
start_broker normal-restart 100
run_action absent normal-session
run_action create crash-session
stop_broker
start_broker crash-window 60000
run_action delete crash-session
kill -KILL "$pid"
wait "$pid" 2>/dev/null || true
pid=""
start_broker crash-restart 100
run_action present crash-session
stop_broker
echo 'MANAGEMENT snapshot runtime completion and SIGKILL restore boundary passed'
