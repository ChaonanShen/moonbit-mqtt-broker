#!/usr/bin/env bash
# Gate: startup rejects corrupt snapshot before listen
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

BROKER_PID=""
BROKER_LOG=""
DATA_DIR=""

cleanup() {
  if [[ -n "${BROKER_PID}" ]] && kill -0 "${BROKER_PID}" 2>/dev/null; then
    kill -KILL -- "-${BROKER_PID}" 2>/dev/null || kill -KILL "${BROKER_PID}" 2>/dev/null || true
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
    --snapshot-debounce-ms 50 --snapshot-max-delay-ms 200 \
    >"${BROKER_LOG}" 2>&1 &
  BROKER_PID="$!"
  for _ in $(seq 1 300); do
    grep -q 'MQTT broker listening' "${BROKER_LOG}" && return
    kill -0 "${BROKER_PID}" 2>/dev/null || return 1
    sleep 0.025
  done
  return 1
}

kill_broker() {
  kill -KILL -- "-${BROKER_PID}" 2>/dev/null || kill -KILL "${BROKER_PID}" 2>/dev/null || true
  wait "${BROKER_PID}" 2>/dev/null || true
  BROKER_PID=""
}

port="$(free_port)"
DATA_DIR="$(mktemp -d)"
start_broker "${port}"
mosquitto_pub -h 127.0.0.1 -p "${port}" -q 1 -r -t m4/crash/value -m committed-a
for _ in $(seq 1 300); do
  grep -q 'snapshot committed revision=' "${BROKER_LOG}" && break
  sleep 0.025
done
grep -q 'snapshot committed revision=' "${BROKER_LOG}"
test "$(stat -c '%a' "${DATA_DIR}")" = 700
test "$(stat -c '%a' "${DATA_DIR}/broker.snapshot")" = 600
test "$(stat -c '%a' "${DATA_DIR}/broker.snapshot.lock")" = 600
main_sha="$(sha256sum "${DATA_DIR}/broker.snapshot" | awk '{print $1}')"
kill_broker

# A killed writer may leave any temp bytes; startup must delete, never promote them.
printf '\x00\x01truncated-temp' >"${DATA_DIR}/broker.snapshot.tmp"
start_broker "${port}"
test ! -e "${DATA_DIR}/broker.snapshot.tmp"
test "$(sha256sum "${DATA_DIR}/broker.snapshot" | awk '{print $1}')" = "${main_sha}"
value="$(timeout 5 mosquitto_sub -h 127.0.0.1 -p "${port}" -q 1 -t m4/crash/value -C 1)"
test "${value}" = committed-a
kill_broker

# Corrupt main is fatal before listen and must not fall back to empty/temp state.
cp "${DATA_DIR}/broker.snapshot" "${DATA_DIR}/broker.snapshot.saved"
printf corrupt >"${DATA_DIR}/broker.snapshot"
BROKER_LOG="$(mktemp)"
set +e
moon run --target native src/cmd/broker -- \
  --listen "127.0.0.1:${port}" --data-dir "${DATA_DIR}" >"${BROKER_LOG}" 2>&1
status="$?"
set -e
test "${status}" -ne 0
grep -q 'snapshot recovery:' "${BROKER_LOG}"
! grep -q 'MQTT broker listening' "${BROKER_LOG}"

# Special files are rejected from metadata without attempting a blocking read.
rm -f "${DATA_DIR}/broker.snapshot"
mkfifo "${DATA_DIR}/broker.snapshot"
BROKER_LOG="$(mktemp)"
set +e
timeout 2 moon run --target native src/cmd/broker -- \
  --listen "127.0.0.1:${port}" --data-dir "${DATA_DIR}" >"${BROKER_LOG}" 2>&1
status="$?"
set -e
test "${status}" -ne 0
test "${status}" -ne 124
grep -q 'snapshot recovery: filesystem' "${BROKER_LOG}"
! grep -q 'MQTT broker listening' "${BROKER_LOG}"
echo 'M4 crash-window stale-temp and corrupt-main policy passed'
