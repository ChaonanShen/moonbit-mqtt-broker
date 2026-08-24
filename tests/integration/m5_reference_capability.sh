#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

declare -a PIDS=()
declare -a LOGS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  rm -f "${LOGS[@]:-}"
}
trap cleanup EXIT

free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

wait_ready() {
  local pid="$1"
  local log="$2"
  local pattern="$3"
  for _ in $(seq 1 200); do
    grep -q "${pattern}" "${log}" && return
    if ! kill -0 "${pid}" 2>/dev/null; then
      sed -n '1,160p' "${log}" >&2
      return 1
    fi
    sleep 0.025
  done
  sed -n '1,160p' "${log}" >&2
  return 1
}

aedes_port="$(free_port)"
aedes_log="$(mktemp)"
LOGS+=("${aedes_log}")
node tools/reference_brokers/aedes_v1_server.mjs 127.0.0.1 "${aedes_port}" >"${aedes_log}" 2>&1 &
aedes_pid="$!"
PIDS+=("${aedes_pid}")
wait_ready "${aedes_pid}" "${aedes_log}" "AEDES_READY=${aedes_port}"
node tools/reference_brokers/capability_probe.mjs "mqtt://127.0.0.1:${aedes_port}" aedes-v1.1.1
kill "${aedes_pid}"
wait "${aedes_pid}" || true
PIDS=()

mosquitto_port="$(free_port)"
mosquitto_log="$(mktemp)"
mosquitto_config="$(mktemp)"
LOGS+=("${mosquitto_log}" "${mosquitto_config}")
printf 'listener %s 127.0.0.1\nallow_anonymous true\npersistence false\n' "${mosquitto_port}" >"${mosquitto_config}"
mosquitto -c "${mosquitto_config}" -v >"${mosquitto_log}" 2>&1 &
mosquitto_pid="$!"
PIDS+=("${mosquitto_pid}")
wait_ready "${mosquitto_pid}" "${mosquitto_log}" "mosquitto version .* running"
node tools/reference_brokers/capability_probe.mjs "mqtt://127.0.0.1:${mosquitto_port}" mosquitto-2.0.18

echo 'M5 reference Broker capability gate passed'
