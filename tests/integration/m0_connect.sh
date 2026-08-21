#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

BROKER_PID=""
BROKER_LOG=""

cleanup() {
  if [[ -n "${BROKER_PID}" ]] && kill -0 "${BROKER_PID}" 2>/dev/null; then
    kill "${BROKER_PID}" 2>/dev/null || true
    wait "${BROKER_PID}" 2>/dev/null || true
  fi
  if [[ -n "${BROKER_LOG}" ]]; then
    rm -f "${BROKER_LOG}"
  fi
}
trap cleanup EXIT

free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

start_broker() {
  local port="$1"
  BROKER_LOG="$(mktemp)"
  stdbuf -oL moon run --target native src/cmd/broker -- \
    --listen "127.0.0.1:${port}" --max-packet-size 1048576 --once \
    >"${BROKER_LOG}" 2>&1 &
  BROKER_PID="$!"
  for _ in $(seq 1 100); do
    if grep -q 'M0 broker listening' "${BROKER_LOG}"; then
      return
    fi
    if ! kill -0 "${BROKER_PID}" 2>/dev/null; then
      sed -n '1,120p' "${BROKER_LOG}" >&2
      return 1
    fi
    sleep 0.02
  done
  sed -n '1,120p' "${BROKER_LOG}" >&2
  return 1
}

wait_broker() {
  wait "${BROKER_PID}"
  BROKER_PID=""
  rm -f "${BROKER_LOG}"
  BROKER_LOG=""
}

mqttjs_port="$(free_port)"
start_broker "${mqttjs_port}"
node tests/integration/m0_connect.mjs "mqtt://127.0.0.1:${mqttjs_port}"
wait_broker

mosquitto_port="$(free_port)"
start_broker "${mosquitto_port}"
mosquitto_log="$(mktemp)"
if timeout 3 mosquitto_sub -h 127.0.0.1 -p "${mosquitto_port}" \
  -i m0-mosquitto-smoke -t m0/smoke -d >"${mosquitto_log}" 2>&1; then
  :
fi
wait_broker
if ! grep -q 'received CONNACK (0)' "${mosquitto_log}"; then
  sed -n '1,120p' "${mosquitto_log}" >&2
  rm -f "${mosquitto_log}"
  exit 1
fi
rm -f "${mosquitto_log}"
echo 'Mosquitto received accepted MQTT 3.1.1 CONNACK'
