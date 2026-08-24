#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

BROKER_PID=""
BROKER_LOG=""
SUB_PID=""

cleanup() {
  if [[ -n "${SUB_PID}" ]] && kill -0 "${SUB_PID}" 2>/dev/null; then
    kill "${SUB_PID}" 2>/dev/null || true
    wait "${SUB_PID}" 2>/dev/null || true
  fi
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
    --max-packet-size 1048576 \
    --max-receive-buffer-size 1048576 \
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
node tests/integration/qos0.mjs "mqtt://127.0.0.1:${port}"

mosquitto_output="$(mktemp)"
mosquitto_sub -h 127.0.0.1 -p "${port}" -i network-mosquitto-sub \
  -t 'network/mosquitto/live' -C 1 >"${mosquitto_output}" &
SUB_PID="$!"
sleep 0.1
mosquitto_pub -h 127.0.0.1 -p "${port}" -i network-mosquitto-pub \
  -t 'network/mosquitto/live' -m 'mosquitto-live'
wait "${SUB_PID}"
SUB_PID=""
grep -qx 'mosquitto-live' "${mosquitto_output}"

mosquitto_pub -h 127.0.0.1 -p "${port}" -i network-mosquitto-retain-pub \
  -t 'network/mosquitto/retained' -m 'mosquitto-retained' -r
retained="$(timeout 5 mosquitto_sub -h 127.0.0.1 -p "${port}" \
  -i network-mosquitto-retain-sub -t 'network/mosquitto/retained' -C 1)"
test "${retained}" = 'mosquitto-retained'
rm -f "${mosquitto_output}"
echo 'Mosquitto NETWORK QoS 0 and retained interoperability passed'
