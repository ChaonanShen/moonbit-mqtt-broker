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
    --listen "127.0.0.1:${port}" \
    --data-dir "${DATA_DIR}" \
    --snapshot-debounce-ms 2000 \
    --snapshot-max-delay-ms 60000 \
    --snapshot-retry-ms 20 \
    --keep-alive-check-interval-ms 20 \
    --max-connections 64 \
    --max-sessions 64 \
    --max-inflight-per-session 8 \
    --max-inflight-total 256 \
    --max-pending-qos1-per-session 16 \
    --max-pending-qos1-total 512 \
    >"${BROKER_LOG}" 2>&1 &
  BROKER_PID="$!"
  for _ in $(seq 1 400); do
    if grep -q 'MQTT broker listening' "${BROKER_LOG}"; then
      return
    fi
    if ! kill -0 "${BROKER_PID}" 2>/dev/null; then
      sed -n '1,200p' "${BROKER_LOG}" >&2
      return 1
    fi
    sleep 0.025
  done
  sed -n '1,200p' "${BROKER_LOG}" >&2
  return 1
}

stop_broker() {
  kill -- "-${BROKER_PID}" 2>/dev/null || kill "${BROKER_PID}" 2>/dev/null || true
  wait "${BROKER_PID}" 2>/dev/null || true
  BROKER_PID=""
}

wait_for_new_commit() {
  local previous_count="$1"
  for _ in $(seq 1 500); do
    local current_count
    current_count="$(grep -c 'snapshot committed revision=' "${BROKER_LOG}" || true)"
    if [[ "${current_count}" -gt "${previous_count}" ]]; then
      return
    fi
    if ! kill -0 "${BROKER_PID}" 2>/dev/null; then
      sed -n '1,240p' "${BROKER_LOG}" >&2
      return 1
    fi
    sleep 0.025
  done
  sed -n '1,240p' "${BROKER_LOG}" >&2
  return 1
}

port="$(free_port)"
DATA_DIR="$(mktemp -d)"
start_broker "${port}"
commit_count="$(grep -c 'snapshot committed revision=' "${BROKER_LOG}" || true)"
seed_output="$(node tests/integration/m4_restart.mjs seed "mqtt://127.0.0.1:${port}")"
packet_id="$(sed -n 's/^M4_SEED_PACKET_ID=//p' <<<"${seed_output}")"
test -n "${packet_id}"
wait_for_new_commit "${commit_count}"
stop_broker

start_broker "${port}"
grep -Eq 'snapshot restored version=1 sessions=[1-9][0-9]* retained=[1-9][0-9]* bytes=[1-9][0-9]*' "${BROKER_LOG}"
commit_count="$(grep -c 'snapshot committed revision=' "${BROKER_LOG}" || true)"
node tests/integration/m4_restart.mjs verify "mqtt://127.0.0.1:${port}" "${packet_id}"
wait_for_new_commit "${commit_count}"
stop_broker

start_broker "${port}"
node tests/integration/m4_restart.mjs verify-cleared "mqtt://127.0.0.1:${port}"
stop_broker
echo 'M4 MQTT.js retained, session, offline QoS1, inflight DUP, packet ID, and capacity restart recovery passed'
