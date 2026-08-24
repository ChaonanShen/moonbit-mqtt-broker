#!/usr/bin/env bash
# Gates:
# SIGTERM forces the latest snapshot before broker exit
# SIGINT forces the latest snapshot before broker exit
# server shutdown suppresses active client Wills
set -euo pipefail
ulimit -c 0

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
moon build --target native
readonly BROKER_EXECUTABLE="${REPO_ROOT}/_build/native/debug/build/cmd/broker/broker.exe"
test -x "${BROKER_EXECUTABLE}"

WORK_DIR="$(mktemp -d)"
BROKER_PID=""
SEED_PID=""

cleanup() {
  if [[ -n "${BROKER_PID}" ]] && kill -0 "${BROKER_PID}" 2>/dev/null; then
    kill -KILL -- "-${BROKER_PID}" 2>/dev/null || kill -KILL "${BROKER_PID}" 2>/dev/null || true
    wait "${BROKER_PID}" 2>/dev/null || true
  fi
  if [[ -n "${SEED_PID}" ]] && kill -0 "${SEED_PID}" 2>/dev/null; then
    kill -KILL "${SEED_PID}" 2>/dev/null || true
    wait "${SEED_PID}" 2>/dev/null || true
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

start_broker() {
  local port="$1"
  local data_dir="$2"
  local broker_log="$3"
  : >"${broker_log}"
  setsid stdbuf -oL "${BROKER_EXECUTABLE}" \
    --listen "127.0.0.1:${port}" \
    --data-dir "${data_dir}" \
    --snapshot-debounce-ms 60000 \
    --snapshot-max-delay-ms 60000 \
    --snapshot-retry-ms 20 \
    --keep-alive-check-interval-ms 20 \
    >"${broker_log}" 2>&1 &
  BROKER_PID="$!"
  for _ in $(seq 1 400); do
    if grep -q 'MQTT broker listening' "${broker_log}"; then
      return
    fi
    if ! kill -0 "${BROKER_PID}" 2>/dev/null; then
      sed -n '1,240p' "${broker_log}" >&2
      return 1
    fi
    sleep 0.025
  done
  sed -n '1,240p' "${broker_log}" >&2
  return 1
}

run_without_persistence() {
  local case_dir="${WORK_DIR}/memory-only"
  local broker_log="${case_dir}/broker.log"
  local port
  port="$(free_port)"
  mkdir -p "${case_dir}"
  : >"${broker_log}"
  setsid stdbuf -oL "${BROKER_EXECUTABLE}" \
    --listen "127.0.0.1:${port}" \
    --keep-alive-check-interval-ms 20 >"${broker_log}" 2>&1 &
  BROKER_PID="$!"
  for _ in $(seq 1 300); do
    grep -q 'MQTT broker listening' "${broker_log}" && break
    kill -0 "${BROKER_PID}" 2>/dev/null || return 1
    sleep 0.025
  done
  grep -q 'MQTT broker listening' "${broker_log}"
  mosquitto_pub -h 127.0.0.1 -p "${port}" -q 1 \
    -t m6/memory-only -m value
  kill -s TERM -- "-${BROKER_PID}"
  wait_for_exit "${BROKER_PID}" "${broker_log}"
  BROKER_PID=""
  grep -q 'broker shutdown requested' "${broker_log}"
  ! grep -q 'snapshot committed revision=' "${broker_log}"
}

wait_for_exit() {
  local pid="$1"
  local log="$2"
  for _ in $(seq 1 200); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" 2>/dev/null || true
      return
    fi
    sleep 0.025
  done
  sed -n '1,260p' "${log}" >&2
  echo "broker did not exit within five seconds" >&2
  return 1
}

run_signal_case() {
  local signal="$1"
  local case_name
  case_name="$(tr '[:upper:]' '[:lower:]' <<<"${signal}")"
  local case_dir="${WORK_DIR}/${case_name}"
  local data_dir="${case_dir}/data"
  local broker_log="${case_dir}/broker.log"
  local seed_log="${case_dir}/seed.log"
  local port
  port="$(free_port)"
  mkdir -p "${case_dir}"

  start_broker "${port}" "${data_dir}" "${broker_log}"
  node tests/integration/m6_shutdown.mjs seed \
    "mqtt://127.0.0.1:${port}" "${case_name}" >"${seed_log}" 2>&1 &
  SEED_PID="$!"
  for _ in $(seq 1 300); do
    if grep -q "M6_SEED_READY=${case_name}" "${seed_log}"; then
      break
    fi
    if ! kill -0 "${SEED_PID}" 2>/dev/null; then
      sed -n '1,200p' "${seed_log}" >&2
      return 1
    fi
    sleep 0.025
  done
  grep -q "M6_SEED_READY=${case_name}" "${seed_log}"

  # The long debounce proves the signal path, rather than the normal timer,
  # creates the first committed snapshot.
  test ! -e "${data_dir}/broker.snapshot"
  kill -s "${signal}" -- "-${BROKER_PID}"
  wait_for_exit "${BROKER_PID}" "${broker_log}"
  BROKER_PID=""
  wait_for_exit "${SEED_PID}" "${seed_log}"
  SEED_PID=""
  if [[ ! -s "${data_dir}/broker.snapshot" ]]; then
    sed -n '1,260p' "${broker_log}" >&2
    echo "signal shutdown did not commit a snapshot for ${case_name}" >&2
    return 1
  fi
  grep -q 'snapshot committed revision=' "${broker_log}"

  : >"${broker_log}"
  start_broker "${port}" "${data_dir}" "${broker_log}"
  node tests/integration/m6_shutdown.mjs verify \
    "mqtt://127.0.0.1:${port}" "${case_name}"
  kill -s TERM -- "-${BROKER_PID}"
  wait_for_exit "${BROKER_PID}" "${broker_log}"
  BROKER_PID=""
}

run_signal_case TERM
run_signal_case INT
run_without_persistence
echo 'M6 SIGTERM/SIGINT final snapshot and Will suppression passed'
