#!/usr/bin/env bash
# Gates:
# Argon2id authentication returns distinct MQTT 3.1.1 rejection codes
# ACLs enforce partial SUBACK, publish, retained, Will, and $SYS policy
# Principal ownership blocks active/offline/restart Client ID attacks
# Snapshot V2 preserves owner state while logs never contain credentials
set -euo pipefail
ulimit -c 0

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
moon build --target native
readonly BROKER_EXECUTABLE="${REPO_ROOT}/_build/native/debug/build/cmd/broker/broker.exe"

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
alice_hash="$(printf '%s' 'alice-secret' | argon2 'alice-salt-00001' -id -e -t 2 -m 12 -p 1)"
bob_hash="$(printf '%s' 'bob-secret' | argon2 'bob-salt-0000002' -id -e -t 2 -m 12 -p 1)"
printf 'alice:%s\nbob:%s\n' "${alice_hash}" "${bob_hash}" >"${WORK_DIR}/passwords"
chmod 0600 "${WORK_DIR}/passwords"
printf '%s\n' \
  'user alice' \
  'topic read allowed/#' \
  'topic write allowed/#' \
  'user bob' \
  'topic read denied/#' \
  'topic write bob/#' \
  >"${WORK_DIR}/acl"

expect_failure() {
  local expected="$1"
  shift
  local log="${WORK_DIR}/invalid.log"
  if "${BROKER_EXECUTABLE}" --listen 127.0.0.1:0 "$@" >"${log}" 2>&1; then
    echo 'invalid security configuration unexpectedly started' >&2
    return 1
  fi
  grep -qF -- "${expected}" "${log}"
  ! grep -qF 'MQTT broker listening' "${log}"
}

expect_failure '--allow-anonymous false requires --password-file' --allow-anonymous false
printf '%s\n' 'alice:plaintext' >"${WORK_DIR}/bad-passwords"
expect_failure 'invalid --password-file' --password-file "${WORK_DIR}/bad-passwords"
printf '%s\n' 'topic read orphan/#' >"${WORK_DIR}/bad-acl"
expect_failure 'invalid --acl-file' --acl-file "${WORK_DIR}/bad-acl"

port="$(free_port)"
broker_log="${WORK_DIR}/broker.log"
data_dir="${WORK_DIR}/data"
start_broker() {
  : >"${broker_log}"
  setsid stdbuf -oL "${BROKER_EXECUTABLE}" \
    --listen "127.0.0.1:${port}" \
    --data-dir "${data_dir}" \
    --snapshot-debounce-ms 60000 \
    --snapshot-max-delay-ms 60000 \
    --tls-cert "${WORK_DIR}/server.crt" \
    --tls-key "${WORK_DIR}/server.key" \
    --allow-anonymous false \
    --password-file "${WORK_DIR}/passwords" \
    --acl-file "${WORK_DIR}/acl" \
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
  return 1
}

start_broker
readonly URL="mqtts://localhost:${port}"
node tests/integration/security.mjs exercise "${URL}" "${WORK_DIR}/server.crt"

mosquitto_output="${WORK_DIR}/mosquitto.out"
mosquitto_sub -h localhost -p "${port}" --cafile "${WORK_DIR}/server.crt" \
  -u alice -P alice-secret -i security-mosquitto-sub -t allowed/mosquitto -q 1 -C 1 \
  >"${mosquitto_output}" &
SUB_PID="$!"
sleep 0.15
mosquitto_pub -h localhost -p "${port}" --cafile "${WORK_DIR}/server.crt" \
  -u alice -P alice-secret -i security-mosquitto-pub -t allowed/mosquitto -q 1 \
  -m authenticated-mosquitto
wait "${SUB_PID}"
SUB_PID=""
grep -qxF 'authenticated-mosquitto' "${mosquitto_output}"

node tests/integration/security.mjs seed "${URL}" "${WORK_DIR}/server.crt"
kill -s TERM -- "-${BROKER_PID}"
wait "${BROKER_PID}"
BROKER_PID=""
test -s "${data_dir}/broker.snapshot"
! grep -qF 'alice-secret' "${broker_log}"
! grep -qF 'bob-secret' "${broker_log}"

start_broker
node tests/integration/security.mjs verify "${URL}" "${WORK_DIR}/server.crt"
kill -s TERM -- "-${BROKER_PID}"
wait "${BROKER_PID}"
BROKER_PID=""
echo 'SECURITY Argon2id, ACL, Principal ownership, Snapshot V2, TLS, and restart passed'
