#!/usr/bin/env bash
# Gates:
# MQTT.js and Mosquitto interoperate over the TLS-only listener
# invalid CA and plaintext MQTT are rejected without stopping the listener
# malformed or mismatched PEM material fails before the listener starts
# stalled TLS handshakes are bounded and concurrent TLS clients remain healthy
set -euo pipefail
ulimit -c 0

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
moon build --target native
readonly BROKER_EXECUTABLE="${REPO_ROOT}/_build/native/debug/build/cmd/broker/broker.exe"
test -x "${BROKER_EXECUTABLE}"

WORK_DIR="$(mktemp -d)"
BROKER_PID=""
SUB_PID=""

cleanup() {
  if [[ -n "${SUB_PID}" ]] && kill -0 "${SUB_PID}" 2>/dev/null; then
    kill "${SUB_PID}" 2>/dev/null || true
    wait "${SUB_PID}" 2>/dev/null || true
  fi
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

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
  -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout "${WORK_DIR}/server.key" -out "${WORK_DIR}/server.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
  -subj '/CN=wrong-ca' -keyout "${WORK_DIR}/wrong.key" \
  -out "${WORK_DIR}/wrong.crt" >/dev/null 2>&1
printf '%s\n' 'not a PEM certificate' >"${WORK_DIR}/malformed.crt"
cp "${WORK_DIR}/server.key" "${WORK_DIR}/unsafe.key"
chmod 0644 "${WORK_DIR}/unsafe.key"
ln -s server.key "${WORK_DIR}/linked.key"

expect_startup_failure() {
  local expected="$1"
  shift
  local log="${WORK_DIR}/startup-failure.log"
  if "${BROKER_EXECUTABLE}" --listen '127.0.0.1:0' "$@" >"${log}" 2>&1; then
    echo "Broker unexpectedly accepted invalid TLS arguments" >&2
    return 1
  fi
  grep -qF -- "${expected}" "${log}"
  ! grep -qF 'MQTT broker listening' "${log}"
}

expect_startup_failure '--tls-cert requires --tls-key' --tls-cert "${WORK_DIR}/server.crt"
expect_startup_failure '--tls-key requires --tls-cert' --tls-key "${WORK_DIR}/server.key"
expect_startup_failure '--tls-handshake-timeout-ms requires --tls-cert and --tls-key' --tls-handshake-timeout-ms 100
expect_startup_failure 'TLS certificate/private key validation failed' \
  --tls-cert "${WORK_DIR}/malformed.crt" --tls-key "${WORK_DIR}/server.key"
expect_startup_failure 'TLS certificate/private key validation failed' \
  --tls-cert "${WORK_DIR}/server.crt" --tls-key "${WORK_DIR}/wrong.key"
expect_startup_failure '--tls-key must not grant permissions to group or other users' \
  --tls-cert "${WORK_DIR}/server.crt" --tls-key "${WORK_DIR}/unsafe.key"
expect_startup_failure '--tls-key must be a regular file, not a symlink or special file' \
  --tls-cert "${WORK_DIR}/server.crt" --tls-key "${WORK_DIR}/linked.key"

port="$(free_port)"
broker_log="${WORK_DIR}/broker.log"
data_dir="${WORK_DIR}/data"

start_tls_broker() {
  : >"${broker_log}"
  setsid stdbuf -oL "${BROKER_EXECUTABLE}" \
    --listen "127.0.0.1:${port}" \
    --max-connections 128 \
    --data-dir "${data_dir}" \
    --snapshot-debounce-ms 60000 \
    --snapshot-max-delay-ms 60000 \
    --tls-cert "${WORK_DIR}/server.crt" \
    --tls-key "${WORK_DIR}/server.key" \
    --tls-handshake-timeout-ms 150 \
    >"${broker_log}" 2>&1 &
  BROKER_PID="$!"
  for _ in $(seq 1 300); do
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

start_tls_broker

readonly TLS_URL="mqtts://localhost:${port}"
node tests/integration/m7_tls.mjs functional "${TLS_URL}" "${WORK_DIR}/server.crt"

mosquitto_output="${WORK_DIR}/mosquitto.out"
mosquitto_sub -h localhost -p "${port}" --cafile "${WORK_DIR}/server.crt" \
  -i m7-mosquitto-sub -t m7/mosquitto/live -q 1 -C 1 >"${mosquitto_output}" &
SUB_PID="$!"
sleep 0.15
mosquitto_pub -h localhost -p "${port}" --cafile "${WORK_DIR}/server.crt" \
  -i m7-mosquitto-pub -t m7/mosquitto/live -q 1 -m encrypted-mosquitto
wait "${SUB_PID}"
SUB_PID=""
grep -qxF 'encrypted-mosquitto' "${mosquitto_output}"

node tests/integration/m7_tls.mjs reject-ca "${TLS_URL}" "${WORK_DIR}/wrong.crt"
node tests/integration/m7_tls.mjs plaintext "mqtt://127.0.0.1:${port}"
node tests/integration/m7_tls.mjs stall "mqtt://127.0.0.1:${port}"
node tests/integration/m7_tls.mjs concurrency "${TLS_URL}" "${WORK_DIR}/server.crt"
node tests/integration/m7_tls.mjs functional "${TLS_URL}" "${WORK_DIR}/server.crt"
node tests/integration/m7_tls.mjs restart-seed "${TLS_URL}" "${WORK_DIR}/server.crt"

kill -s TERM -- "-${BROKER_PID}"
wait "${BROKER_PID}"
BROKER_PID=""
grep -qF 'broker shutdown requested' "${broker_log}"
grep -qF 'event=tls_handshake_failed' "${broker_log}"
test -s "${data_dir}/broker.snapshot"

start_tls_broker
node tests/integration/m7_tls.mjs restart-verify "${TLS_URL}" "${WORK_DIR}/server.crt"
kill -s TERM -- "-${BROKER_PID}"
wait "${BROKER_PID}"
BROKER_PID=""
echo 'M7 TLS listener, validation, timeout, rejection, concurrency, and interoperability passed'
