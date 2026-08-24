#!/usr/bin/env bash
# Twenty independent SIGTERM final-snapshot/restart recovery cycles.
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
free_port() { node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }
start() {
  local port="$1" data_dir="$2" log="$3"
  : >"${log}"
  setsid stdbuf -oL "${BROKER_EXECUTABLE}" --listen "127.0.0.1:${port}" \
    --data-dir "${data_dir}" --snapshot-debounce-ms 60000 \
    --snapshot-max-delay-ms 60000 --keep-alive-check-interval-ms 20 \
    >"${log}" 2>&1 &
  BROKER_PID="$!"
  for _ in $(seq 1 300); do
    grep -qF 'MQTT broker listening' "${log}" && return
    sleep 0.02
  done
  sed -n '1,160p' "${log}" >&2
  return 1
}
stop() {
  local log="$1"
  kill -s TERM -- "-${BROKER_PID}"
  wait "${BROKER_PID}"
  BROKER_PID=""
  grep -qF 'snapshot committed revision=' "${log}"
}
for cycle in $(seq 1 20); do
  port="$(free_port)"
  data_dir="${WORK_DIR}/cycle-${cycle}"
  log="${WORK_DIR}/cycle-${cycle}.log"
  start "${port}" "${data_dir}" "${log}"
  node tests/integration/shutdown_cycle.mjs seed "mqtt://127.0.0.1:${port}" "${cycle}"
  test ! -e "${data_dir}/broker.snapshot"
  stop "${log}"
  test -s "${data_dir}/broker.snapshot"
  start "${port}" "${data_dir}" "${log}"
  node tests/integration/shutdown_cycle.mjs verify "mqtt://127.0.0.1:${port}" "${cycle}"
  stop "${log}"
done
echo 'RELEASE_SIGTERM_SNAPSHOT_CYCLES=20'
