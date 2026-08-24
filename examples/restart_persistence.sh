#!/usr/bin/env bash
# Self-contained retained and persistent-Session restart example.
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

BROKER_PID=""
SUB_PID=""
BROKER_LOG=""
DATA_DIR="$(mktemp -d)"
SUB_LOG="$(mktemp)"
cleanup() {
  [[ -z "${SUB_PID}" ]] || { kill "${SUB_PID}" 2>/dev/null || true; wait "${SUB_PID}" 2>/dev/null || true; }
  if [[ -n "${BROKER_PID}" ]] && kill -0 "${BROKER_PID}" 2>/dev/null; then
    kill -- "-${BROKER_PID}" 2>/dev/null || kill "${BROKER_PID}" 2>/dev/null || true
    wait "${BROKER_PID}" 2>/dev/null || true
  fi
  [[ -z "${BROKER_LOG}" ]] || rm -f "${BROKER_LOG}"
  rm -f "${SUB_LOG}"
  rm -rf "${DATA_DIR}"
}
trap cleanup EXIT

port="$(node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
start_broker() {
  [[ -z "${BROKER_LOG}" ]] || rm -f "${BROKER_LOG}"
  BROKER_LOG="$(mktemp)"
  setsid stdbuf -oL moon run --target native src/cmd/broker -- \
    --listen "127.0.0.1:${port}" --data-dir "${DATA_DIR}" \
    --snapshot-debounce-ms 20 --snapshot-max-delay-ms 100 >"${BROKER_LOG}" 2>&1 &
  BROKER_PID="$!"
  for _ in $(seq 1 300); do
    grep -q 'MQTT broker listening' "${BROKER_LOG}" && return
    kill -0 "${BROKER_PID}" 2>/dev/null || { sed -n '1,160p' "${BROKER_LOG}" >&2; return 1; }
    sleep 0.025
  done
  return 1
}
stop_broker() {
  kill -- "-${BROKER_PID}" 2>/dev/null || kill "${BROKER_PID}" 2>/dev/null || true
  wait "${BROKER_PID}" 2>/dev/null || true
  BROKER_PID=""
}

start_broker
stdbuf -oL -eL mosquitto_sub -h 127.0.0.1 -p "${port}" -i m5-example-restart-session \
  -c -q 1 -t examples/restart/offline >"${SUB_LOG}" 2>&1 &
SUB_PID="$!"
for _ in $(seq 1 200); do
  mosquitto_pub -h 127.0.0.1 -p "${port}" -q 1 -t examples/restart/offline -m 'subscription ready'
  grep -q 'subscription ready' "${SUB_LOG}" && break
  sleep 0.025
done
grep -q 'subscription ready' "${SUB_LOG}"
kill "${SUB_PID}"
wait "${SUB_PID}" 2>/dev/null || true
SUB_PID=""
for _ in $(seq 1 300); do
  grep -q 'snapshot committed revision=' "${BROKER_LOG}" && break
  sleep 0.025
done
baseline_commits="$(grep -c 'snapshot committed revision=' "${BROKER_LOG}" || true)"
mosquitto_pub -h 127.0.0.1 -p "${port}" -q 1 -t examples/restart/offline -m 'offline across restart'
mosquitto_pub -h 127.0.0.1 -p "${port}" -q 1 -r -t examples/restart/retained -m 'retained across restart'
for _ in $(seq 1 300); do
  current_commits="$(grep -c 'snapshot committed revision=' "${BROKER_LOG}" || true)"
  [[ "${current_commits}" -gt "${baseline_commits}" ]] && break
  sleep 0.025
done
[[ "${current_commits}" -gt "${baseline_commits}" ]]
stop_broker

start_broker
retained="$(timeout 5 mosquitto_sub -h 127.0.0.1 -p "${port}" -q 1 -t examples/restart/retained -C 1)"
offline="$(timeout 5 mosquitto_sub -h 127.0.0.1 -p "${port}" -i m5-example-restart-session -c -q 1 -t examples/restart/offline -C 1)"
[[ "${retained}" = 'retained across restart' ]]
[[ "${offline}" = 'offline across restart' ]]
stop_broker
echo 'restart persistence example passes'
