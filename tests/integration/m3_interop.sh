#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

BROKER_PID=""
BROKER_LOG=""

cleanup() {
  if [[ -n "${BROKER_PID}" ]] && kill -0 "${BROKER_PID}" 2>/dev/null; then
    kill -- "-${BROKER_PID}" 2>/dev/null || kill "${BROKER_PID}" 2>/dev/null || true
    wait "${BROKER_PID}" 2>/dev/null || true
  fi
  [[ -z "${BROKER_LOG}" ]] || rm -f "${BROKER_LOG}"
}
trap cleanup EXIT

free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

start_broker() {
  local port="$1"
  BROKER_LOG="$(mktemp)"
  setsid stdbuf -oL moon run --target native src/cmd/broker -- \
    --listen "127.0.0.1:${port}" \
    --max-connections 64 \
    --max-sessions 64 \
    --max-inflight-per-session 8 \
    --max-inflight-total 128 \
    --max-pending-qos1-per-session 16 \
    --max-pending-qos1-total 256 \
    >"${BROKER_LOG}" 2>&1 &
  BROKER_PID="$!"
  for _ in $(seq 1 200); do
    if grep -q 'MQTT broker listening' "${BROKER_LOG}"; then
      return
    fi
    if ! kill -0 "${BROKER_PID}" 2>/dev/null; then
      sed -n '1,160p' "${BROKER_LOG}" >&2
      return 1
    fi
    sleep 0.025
  done
  sed -n '1,160p' "${BROKER_LOG}" >&2
  return 1
}

port="$(free_port)"
start_broker "${port}"
node tests/integration/m3_qos1.mjs "mqtt://127.0.0.1:${port}"

first_log="$(mktemp)"
set +e
timeout 1 mosquitto_sub -h 127.0.0.1 -p "${port}" \
  -i m3-mosquitto-persistent -c -q 1 -t 'm3/mosquitto/offline' \
  >"${first_log}" 2>&1
first_status="$?"
set -e
if [[ "${first_status}" -ne 0 && "${first_status}" -ne 124 ]]; then
  sed -n '1,120p' "${first_log}" >&2
  exit "${first_status}"
fi
rm -f "${first_log}"

mosquitto_pub -h 127.0.0.1 -p "${port}" -i m3-mosquitto-publisher \
  -q 1 -t 'm3/mosquitto/offline' -m 'mosquitto-qos1'
resumed="$(timeout 5 mosquitto_sub -h 127.0.0.1 -p "${port}" \
  -i m3-mosquitto-persistent -c -q 1 -t 'm3/mosquitto/offline' -C 1)"
test "${resumed}" = 'mosquitto-qos1'
echo 'Mosquitto M3 QoS 1 persistent-session interoperability passed'
