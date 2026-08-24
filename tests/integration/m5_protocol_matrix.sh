#!/usr/bin/env bash
# Gate: mqtt311 final packet matrix matches supported contract
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

BROKER_PID=""
BROKER_LOG="$(mktemp)"
cleanup() {
  if [[ -n "${BROKER_PID}" ]] && kill -0 "${BROKER_PID}" 2>/dev/null; then
    kill -- "-${BROKER_PID}" 2>/dev/null || kill "${BROKER_PID}" 2>/dev/null || true
    wait "${BROKER_PID}" 2>/dev/null || true
  fi
  rm -f "${BROKER_LOG}"
}
trap cleanup EXIT

port="$(node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
setsid stdbuf -oL moon run --target native src/cmd/broker -- \
  --listen "127.0.0.1:${port}" --keep-alive-check-interval-ms 20 \
  --max-connections 64 --max-sessions 32 --max-inflight-total 128 \
  --max-pending-qos1-total 128 >"${BROKER_LOG}" 2>&1 &
BROKER_PID="$!"
for _ in $(seq 1 300); do
  grep -q 'MQTT broker listening' "${BROKER_LOG}" && break
  if ! kill -0 "${BROKER_PID}" 2>/dev/null; then
    sed -n '1,200p' "${BROKER_LOG}" >&2
    exit 1
  fi
  sleep 0.025
done
grep -q 'MQTT broker listening' "${BROKER_LOG}"
node tests/integration/m5_protocol_matrix.mjs "mqtt://127.0.0.1:${port}" full moonbit
echo 'M5 MQTT 3.1.1 final protocol matrix passed'
