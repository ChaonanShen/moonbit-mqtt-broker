#!/usr/bin/env bash
# Gate: reference brokers agree on common mqtt311 behavior
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

declare -a PIDS=()
declare -a FILES=()
cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    kill -- "-${pid}" 2>/dev/null || kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  rm -f "${FILES[@]:-}"
}
trap cleanup EXIT

free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}
wait_ready() {
  local pid="$1" log="$2" pattern="$3"
  for _ in $(seq 1 300); do
    grep -Eq "${pattern}" "${log}" && return
    kill -0 "${pid}" 2>/dev/null || { sed -n '1,160p' "${log}" >&2; return 1; }
    sleep 0.025
  done
  sed -n '1,160p' "${log}" >&2
  return 1
}
run_matrix() {
  local port="$1" label="$2" output="$3"
  node tests/integration/protocol_matrix.mjs "mqtt://127.0.0.1:${port}" common "${label}" \
    | sed -n 's/^RELEASE_MATRIX_RESULT=//p' >"${output}"
  test -s "${output}"
}

moon_port="$(free_port)"
moon_log="$(mktemp)"
moon_result="$(mktemp)"
FILES+=("${moon_log}" "${moon_result}")
setsid stdbuf -oL moon run --target native src/cmd/broker -- --listen "127.0.0.1:${moon_port}" >"${moon_log}" 2>&1 &
moon_pid="$!"
PIDS+=("${moon_pid}")
wait_ready "${moon_pid}" "${moon_log}" 'MQTT broker listening'
run_matrix "${moon_port}" moonbit "${moon_result}"

mosquitto_port="$(free_port)"
mosquitto_log="$(mktemp)"
mosquitto_config="$(mktemp)"
mosquitto_result="$(mktemp)"
FILES+=("${mosquitto_log}" "${mosquitto_config}" "${mosquitto_result}")
printf 'listener %s 127.0.0.1\nallow_anonymous true\npersistence false\n' "${mosquitto_port}" >"${mosquitto_config}"
mosquitto -c "${mosquitto_config}" -v >"${mosquitto_log}" 2>&1 &
mosquitto_pid="$!"
PIDS+=("${mosquitto_pid}")
wait_ready "${mosquitto_pid}" "${mosquitto_log}" 'mosquitto version .* running'
run_matrix "${mosquitto_port}" mosquitto "${mosquitto_result}"

aedes_port="$(free_port)"
aedes_log="$(mktemp)"
aedes_result="$(mktemp)"
FILES+=("${aedes_log}" "${aedes_result}")
node tools/reference_brokers/aedes_v1_server.mjs 127.0.0.1 "${aedes_port}" >"${aedes_log}" 2>&1 &
aedes_pid="$!"
PIDS+=("${aedes_pid}")
wait_ready "${aedes_pid}" "${aedes_log}" "AEDES_READY=${aedes_port}"
run_matrix "${aedes_port}" aedes "${aedes_result}"

diff -u "${mosquitto_result}" "${moon_result}"
diff -u "${mosquitto_result}" "${aedes_result}"
echo 'RELEASE MoonBit, Mosquitto, and Aedes normalized MQTT 3.1.1 behavior agrees'
