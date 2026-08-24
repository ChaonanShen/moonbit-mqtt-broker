#!/usr/bin/env bash
set -euo pipefail

readonly HOST="${1:-127.0.0.1}"
readonly PORT="${2:-1883}"
readonly CLIENT_ID="moonbit-persistent-example"
readonly TOPIC="examples/persistent/qos1"
readonly FIRST_LOG="$(mktemp)"
SUB_PID=""
trap '[[ -z "${SUB_PID}" ]] || { kill "${SUB_PID}" 2>/dev/null || true; wait "${SUB_PID}" 2>/dev/null || true; }; rm -f "${FIRST_LOG}"' EXIT

stdbuf -oL -eL mosquitto_sub -h "${HOST}" -p "${PORT}" -i "${CLIENT_ID}" \
  -c -q 1 -t "${TOPIC}" >"${FIRST_LOG}" 2>&1 &
SUB_PID="$!"
for _ in $(seq 1 200); do
  mosquitto_pub -h "${HOST}" -p "${PORT}" -q 1 -t "${TOPIC}" -m 'subscription ready'
  grep -q 'subscription ready' "${FIRST_LOG}" && break
  kill -0 "${SUB_PID}" 2>/dev/null || { sed -n '1,120p' "${FIRST_LOG}" >&2; exit 1; }
  sleep 0.025
done
grep -q 'subscription ready' "${FIRST_LOG}"
kill "${SUB_PID}"
wait "${SUB_PID}" 2>/dev/null || true
SUB_PID=""

mosquitto_pub -h "${HOST}" -p "${PORT}" -i moonbit-persistent-publisher \
  -q 1 -t "${TOPIC}" -m 'queued while subscriber is offline'
timeout 5 mosquitto_sub -h "${HOST}" -p "${PORT}" -i "${CLIENT_ID}" \
  -c -q 1 -t "${TOPIC}" -C 1
