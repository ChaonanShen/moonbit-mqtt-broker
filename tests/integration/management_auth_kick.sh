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
password_hash="$(printf 'correct horse' | argon2 'management-salt1' -id -e -t 10 -m 16 -p 1)"
printf 'hold:%s\n' "$password_hash" >"$work/passwords"
chmod 0600 "$work/passwords"
token='heldadmin.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
node -e 'const c=require("crypto");const t=process.argv[1];console.log("heldadmin:"+c.createHash("sha256").update("moonbit-mqtt-broker/admin/v1:"+t).digest("hex")+":read,operator")' "$token" >"$work/tokens"
chmod 0600 "$work/tokens"
"$ROOT/_build/native/debug/build/cmd/broker/broker.exe" \
  --listen "127.0.0.1:$mqtt_port" \
  --allow-anonymous false --password-file "$work/passwords" \
  --rate-limits-enabled false --per-ip-limits-enabled false \
  --auth-workers 1 --auth-queue-limit 1 \
  --auth-timeout-ms 30000 --connect-timeout-ms 30000 \
  --auth-poll-interval-ms 2 --auth-result-batch-limit 2 \
  --management-enabled true --management-details-enabled true \
  --management-operations-enabled true --management-max-bytes-total 33554432 \
  --management-listen "127.0.0.1:$admin_port" \
  --management-token-file "$work/tokens" >"$work/broker.log" 2>&1 &
pid="$!"
for _ in $(seq 1 100); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$admin_port/health/live" >/dev/null 2>&1; then break; fi
  if ! kill -0 "$pid" 2>/dev/null; then cat "$work/broker.log" >&2; exit 1; fi
  sleep 0.05
done
node tests/integration/management_auth_kick.mjs "$admin_port" "$mqtt_port" "$token"
kill -TERM "$pid"
wait "$pid"
pid=""
! grep -qF 'correct horse' "$work/broker.log"
! grep -qF "$password_hash" "$work/broker.log"
echo 'MANAGEMENT authenticating kick waits for native reap and rejects late hash'
