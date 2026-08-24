#!/usr/bin/env bash
# Self-contained QoS 0/1 publish/subscribe example.
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

BROKER_PID=""
SUB_PID=""
BROKER_LOG="$(mktemp)"
SUB_LOG="$(mktemp)"
cleanup() {
  [[ -z "${SUB_PID}" ]] || { kill "${SUB_PID}" 2>/dev/null || true; wait "${SUB_PID}" 2>/dev/null || true; }
  if [[ -n "${BROKER_PID}" ]] && kill -0 "${BROKER_PID}" 2>/dev/null; then
    kill -- "-${BROKER_PID}" 2>/dev/null || kill "${BROKER_PID}" 2>/dev/null || true
    wait "${BROKER_PID}" 2>/dev/null || true
  fi
  rm -f "${BROKER_LOG}" "${SUB_LOG}"
}
trap cleanup EXIT

port="$(node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
setsid stdbuf -oL moon run --target native src/cmd/broker -- --listen "127.0.0.1:${port}" >"${BROKER_LOG}" 2>&1 &
BROKER_PID="$!"
for _ in $(seq 1 300); do
  grep -q 'MQTT broker listening' "${BROKER_LOG}" && break
  kill -0 "${BROKER_PID}" 2>/dev/null || { sed -n '1,160p' "${BROKER_LOG}" >&2; exit 1; }
  sleep 0.025
done
grep -q 'MQTT broker listening' "${BROKER_LOG}"

stdbuf -oL -eL mosquitto_sub -h 127.0.0.1 -p "${port}" -i m5-example-basic-sub \
  -q 1 -t 'examples/basic/#' -C 3 >"${SUB_LOG}" 2>&1 &
SUB_PID="$!"
for _ in $(seq 1 200); do
  mosquitto_pub -h 127.0.0.1 -p "${port}" -t examples/basic/ready -m 'subscriber ready'
  grep -q 'subscriber ready' "${SUB_LOG}" && break
  kill -0 "${SUB_PID}" 2>/dev/null || { sed -n '1,120p' "${SUB_LOG}" >&2; exit 1; }
  sleep 0.025
done
grep -q 'subscriber ready' "${SUB_LOG}"
mosquitto_pub -h 127.0.0.1 -p "${port}" -i m5-example-basic-qos0 -q 0 \
  -t examples/basic/qos0 -m 'hello qos0'
mosquitto_pub -h 127.0.0.1 -p "${port}" -i m5-example-basic-qos1 -q 1 \
  -t examples/basic/qos1 -m 'hello qos1'
wait "${SUB_PID}"
SUB_PID=""
grep -q 'hello qos0' "${SUB_LOG}"
grep -q 'hello qos1' "${SUB_LOG}"
echo 'basic publish subscribe example passes'
