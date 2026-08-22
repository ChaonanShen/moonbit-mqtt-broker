#!/usr/bin/env bash
set -euo pipefail

readonly HOST="${1:-127.0.0.1}"
readonly PORT="${2:-1883}"
readonly CLIENT_ID="moonbit-persistent-example"
readonly TOPIC="examples/persistent/qos1"
readonly FIRST_LOG="$(mktemp)"
trap 'rm -f "${FIRST_LOG}"' EXIT

set +e
timeout 1 mosquitto_sub -h "${HOST}" -p "${PORT}" -i "${CLIENT_ID}" \
  -c -q 1 -t "${TOPIC}" >"${FIRST_LOG}" 2>&1
status="$?"
set -e
if [[ "${status}" -ne 0 && "${status}" -ne 124 ]]; then
  sed -n '1,120p' "${FIRST_LOG}" >&2
  exit "${status}"
fi

mosquitto_pub -h "${HOST}" -p "${PORT}" -i moonbit-persistent-publisher \
  -q 1 -t "${TOPIC}" -m 'queued while subscriber is offline'
timeout 5 mosquitto_sub -h "${HOST}" -p "${PORT}" -i "${CLIENT_ID}" \
  -c -q 1 -t "${TOPIC}" -C 1
