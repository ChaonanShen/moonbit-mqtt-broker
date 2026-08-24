#!/usr/bin/env bash
# Gates: default Sessions never expire; active Sessions are preserved; reconnect
# resets the deadline; detached Sessions expire and remain absent after restart.
set -euo pipefail
ulimit -c 0

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
moon build --target native
readonly BROKER_EXECUTABLE="${REPO_ROOT}/_build/native/debug/build/cmd/broker/broker.exe"

WORK_DIR="$(mktemp -d)"
BROKER_PID=""
cleanup() {
  if [[ -n "${BROKER_PID}" ]] && kill -0 "${BROKER_PID}" 2>/dev/null; then
    kill -- "-${BROKER_PID}" 2>/dev/null || kill "${BROKER_PID}" 2>/dev/null || true
    wait "${BROKER_PID}" 2>/dev/null || true
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

port="$(free_port)"
broker_log="${WORK_DIR}/broker.log"
data_dir="${WORK_DIR}/data"
start_broker() {
  local expiry="$1"
  : >"${broker_log}"
  setsid stdbuf -oL "${BROKER_EXECUTABLE}" \
    --listen "127.0.0.1:${port}" \
    --data-dir "${data_dir}" \
    --persistent-session-expiry "${expiry}" \
    --max-session-expirations-per-tick 2 \
    --keep-alive-check-interval-ms 20 \
    --snapshot-debounce-ms 20 \
    --snapshot-max-delay-ms 100 \
    >"${broker_log}" 2>&1 &
  BROKER_PID="$!"
  for _ in $(seq 1 400); do
    grep -qF 'MQTT broker listening' "${broker_log}" && return
    if ! kill -0 "${BROKER_PID}" 2>/dev/null; then
      sed -n '1,200p' "${broker_log}" >&2
      return 1
    fi
    sleep 0.025
  done
  sed -n '1,200p' "${broker_log}" >&2
  return 1
}
stop_broker() {
  kill -s TERM -- "-${BROKER_PID}"
  wait "${BROKER_PID}"
  BROKER_PID=""
}

start_broker never
node tests/integration/session_expiry.mjs never "mqtt://127.0.0.1:${port}"
stop_broker

rm -rf "${data_dir}"
start_broker 250ms
node tests/integration/session_expiry.mjs timing "mqtt://127.0.0.1:${port}"
node tests/integration/session_expiry.mjs seed "mqtt://127.0.0.1:${port}"
for _ in $(seq 1 200); do
  grep -qF 'persistent Session expired client_id=session_expiry-persisted-expiry' "${broker_log}" && break
  sleep 0.025
done
grep -qF 'persistent Session expired client_id=session_expiry-persisted-expiry' "${broker_log}"
stop_broker
test -s "${data_dir}/broker.snapshot"

start_broker 250ms
node tests/integration/session_expiry.mjs verify-absent "mqtt://127.0.0.1:${port}"
stop_broker

invalid_log="${WORK_DIR}/invalid.log"
if "${BROKER_EXECUTABLE}" --persistent-session-expiry 0ms >"${invalid_log}" 2>&1; then
  echo 'zero Session expiry unexpectedly accepted' >&2
  exit 1
fi
grep -qF 'invalid --persistent-session-expiry' "${invalid_log}"
echo 'SESSION_EXPIRY Session expiry timing, reset, default, and restart deletion passed'
