#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

BROKER_PID=""
BROKER_LOG=""
DATA_DIR=""

cleanup() {
  if [[ -n "${BROKER_PID}" ]] && kill -0 "${BROKER_PID}" 2>/dev/null; then
    kill -- "-${BROKER_PID}" 2>/dev/null || kill "${BROKER_PID}" 2>/dev/null || true
    wait "${BROKER_PID}" 2>/dev/null || true
  fi
  [[ -z "${BROKER_LOG}" ]] || rm -f "${BROKER_LOG}"
  [[ -z "${DATA_DIR}" ]] || rm -rf "${DATA_DIR}"
}
trap cleanup EXIT

free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

start_broker() {
  local port="$1"
  [[ -z "${BROKER_LOG}" ]] || rm -f "${BROKER_LOG}"
  BROKER_LOG="$(mktemp)"
  setsid stdbuf -oL moon run --target native src/cmd/broker -- \
    --listen "127.0.0.1:${port}" --data-dir "${DATA_DIR}" \
    --snapshot-debounce-ms 200 --snapshot-max-delay-ms 1000 \
    >"${BROKER_LOG}" 2>&1 &
  BROKER_PID="$!"
  for _ in $(seq 1 300); do
    grep -q 'MQTT broker listening' "${BROKER_LOG}" && return
    kill -0 "${BROKER_PID}" 2>/dev/null || {
      sed -n '1,160p' "${BROKER_LOG}" >&2
      return 1
    }
    sleep 0.025
  done
  return 1
}

stop_broker() {
  kill -- "-${BROKER_PID}" 2>/dev/null || kill "${BROKER_PID}" 2>/dev/null || true
  wait "${BROKER_PID}" 2>/dev/null || true
  BROKER_PID=""
}

wait_for_new_commit() {
  local previous_count="$1"
  for _ in $(seq 1 300); do
    local current_count
    current_count="$(grep -c 'snapshot committed revision=' "${BROKER_LOG}" || true)"
    [[ "${current_count}" -gt "${previous_count}" ]] && return
    sleep 0.025
  done
  sed -n '1,160p' "${BROKER_LOG}" >&2
  return 1
}

port="$(free_port)"
DATA_DIR="$(mktemp -d)"
start_broker "${port}"
mosquitto_pub -h 127.0.0.1 -p "${port}" -q 1 -r -t m4/mosquitto/retained -m retained
set +e
timeout 1 mosquitto_sub -h 127.0.0.1 -p "${port}" \
  -i m4-mosquitto-persistent -c -q 1 -t m4/mosquitto/offline >/dev/null 2>&1
status="$?"
set -e
[[ "${status}" -eq 0 || "${status}" -eq 124 ]]
commit_count="$(grep -c 'snapshot committed revision=' "${BROKER_LOG}" || true)"
mosquitto_pub -h 127.0.0.1 -p "${port}" -q 1 -t m4/mosquitto/offline -m offline
wait_for_new_commit "${commit_count}"
stop_broker

start_broker "${port}"
retained="$(timeout 5 mosquitto_sub -h 127.0.0.1 -p "${port}" -q 1 -t m4/mosquitto/retained -C 1)"
test "${retained}" = retained
offline="$(timeout 5 mosquitto_sub -h 127.0.0.1 -p "${port}" \
  -i m4-mosquitto-persistent -c -q 1 -t m4/mosquitto/offline -C 1)"
test "${offline}" = offline
stop_broker
echo 'Mosquitto M4 retained and persistent-session restart interoperability passed'
