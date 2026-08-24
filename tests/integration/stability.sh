#!/usr/bin/env bash
# Gates:
# one hundred clients connect ping and disconnect concurrently
# ten thousand qos0 messages preserve sequence without global stall
# ten persistent sessions drain one hundred offline qos1 messages each
# slow consumer is isolated while healthy clients continue
# connection churn returns file descriptors to bounded baseline
# repeated committed restarts preserve current state without snapshot growth
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

BROKER_PID=""
BROKER_LOG=""
DATA_DIR="$(mktemp -d)"
cleanup() {
  if [[ -n "${BROKER_PID}" ]] && kill -0 "${BROKER_PID}" 2>/dev/null; then
    kill -- "-${BROKER_PID}" 2>/dev/null || kill "${BROKER_PID}" 2>/dev/null || true
    wait "${BROKER_PID}" 2>/dev/null || true
  fi
  [[ -z "${BROKER_LOG}" ]] || rm -f "${BROKER_LOG}"
  rm -rf "${DATA_DIR}"
}
trap cleanup EXIT

free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}
start_broker() {
  local port="$1" persistence="${2:-0}"
  [[ -z "${BROKER_LOG}" ]] || rm -f "${BROKER_LOG}"
  BROKER_LOG="$(mktemp)"
  local -a persistence_args=()
  if [[ "${persistence}" -eq 1 ]]; then
    persistence_args=(--data-dir "${DATA_DIR}" --snapshot-debounce-ms 20 --snapshot-max-delay-ms 100 --snapshot-retry-ms 20)
  fi
  setsid stdbuf -oL moon run --target native src/cmd/broker -- \
    --listen "127.0.0.1:${port}" --max-connections 160 \
    --max-packet-size 4096 --max-receive-buffer-size 4096 \
    --max-outbound-queue 1024 --max-runtime-events 2048 \
    --max-sessions 256 --max-inflight-per-session 128 --max-inflight-total 2048 \
    --max-pending-qos1-per-session 128 --max-pending-qos1-total 2048 \
    "${persistence_args[@]}" >"${BROKER_LOG}" 2>&1 &
  BROKER_PID="$!"
  for _ in $(seq 1 400); do
    grep -q 'MQTT broker listening' "${BROKER_LOG}" && return
    kill -0 "${BROKER_PID}" 2>/dev/null || { sed -n '1,200p' "${BROKER_LOG}" >&2; return 1; }
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
wait_commit() {
  local previous_count="$1"
  local observed_count="${previous_count}"
  local quiet_ticks=0
  for _ in $(seq 1 500); do
    current_count="$(grep -c 'snapshot committed revision=' "${BROKER_LOG}" || true)"
    if [[ "${current_count}" -gt "${observed_count}" ]]; then
      observed_count="${current_count}"
      quiet_ticks=0
    elif [[ "${observed_count}" -gt "${previous_count}" ]]; then
      quiet_ticks=$((quiet_ticks + 1))
      [[ "${quiet_ticks}" -ge 12 ]] && return
    fi
    kill -0 "${BROKER_PID}" 2>/dev/null || { sed -n '1,240p' "${BROKER_LOG}" >&2; return 1; }
    sleep 0.025
  done
  sed -n '1,240p' "${BROKER_LOG}" >&2
  return 1
}

port="$(free_port)"
start_broker "${port}"
warm_fd="$(find "/proc/${BROKER_PID}/fd" -mindepth 1 -maxdepth 1 | wc -l)"
node tests/integration/stability.mjs quick "mqtt://127.0.0.1:${port}"
for index in $(seq 1 500); do
  mosquitto_pub -h 127.0.0.1 -p "${port}" -i "release-churn-${index}" -t release/churn -n
done
for _ in $(seq 1 100); do
  current_fd="$(find "/proc/${BROKER_PID}/fd" -mindepth 1 -maxdepth 1 | wc -l)"
  [[ "${current_fd}" -le $((warm_fd + 16)) ]] && break
  sleep 0.025
done
[[ "${current_fd}" -le $((warm_fd + 16)) ]]
peak_rss_kib="$(awk '/VmHWM:/ {print $2}' "/proc/${BROKER_PID}/status")"
[[ "${peak_rss_kib}" -lt 524288 ]]
stop_broker
echo "RELEASE_CHURN_FD=${warm_fd}->${current_fd} RSS_KIB=${peak_rss_kib}"

restart_rounds=5
if [[ "${RELEASE_SOAK:-0}" -eq 1 ]]; then restart_rounds=25; fi
max_snapshot_size=0
for round in $(seq 0 $((restart_rounds - 1))); do
  start_broker "${port}" 1
  if [[ "${round}" -gt 0 ]]; then
    node tests/integration/stability.mjs restart-verify "mqtt://127.0.0.1:${port}" $((round - 1))
  fi
  commit_count="$(grep -c 'snapshot committed revision=' "${BROKER_LOG}" || true)"
  node tests/integration/stability.mjs restart-seed "mqtt://127.0.0.1:${port}" "${round}"
  wait_commit "${commit_count}"
  snapshot_size="$(stat -c %s "${DATA_DIR}/broker.snapshot")"
  [[ "${snapshot_size}" -le $((max_snapshot_size + 4096)) || "${max_snapshot_size}" -eq 0 ]]
  (( snapshot_size > max_snapshot_size )) && max_snapshot_size="${snapshot_size}"
  stop_broker
done
start_broker "${port}" 1
node tests/integration/stability.mjs restart-verify "mqtt://127.0.0.1:${port}" $((restart_rounds - 1))
stop_broker
echo "RELEASE_RESTART_ROUNDS=${restart_rounds} MAX_SNAPSHOT_BYTES=${max_snapshot_size}"

if [[ "${RELEASE_SOAK:-0}" -eq 1 ]]; then
  start_broker "${port}"
  node tests/integration/stability.mjs extended "mqtt://127.0.0.1:${port}"
  stop_broker
fi

echo 'RELEASE bounded workload stability profile passed'
