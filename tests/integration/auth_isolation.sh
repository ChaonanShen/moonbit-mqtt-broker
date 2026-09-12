#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
moon build --target native
readonly BROKER="${REPO_ROOT}/_build/native/debug/build/cmd/broker/broker.exe"
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

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
  -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout "${WORK_DIR}/server.key" -out "${WORK_DIR}/server.crt" >/dev/null 2>&1
readonly PASSWORD='isolation-secret'
password_hash="$(printf '%s' "${PASSWORD}" | argon2 'isolation-salt1' -id -e -t 10 -m 15 -p 1)"
printf 'isolation:%s\n' "${password_hash}" >"${WORK_DIR}/passwords"
chmod 0600 "${WORK_DIR}/passwords"
printf '%s\n' \
  'user isolation' \
  'topic read allowed/#' \
  'topic write allowed/#' \
  >"${WORK_DIR}/acl"

port="$(free_port)"
log="${WORK_DIR}/broker.log"
setsid stdbuf -oL "${BROKER}" \
  --listen "127.0.0.1:${port}" \
  --rate-limits-enabled false \
  --per-ip-limits-enabled false \
  --connect-timeout-ms 30000 \
  --keep-alive-check-interval-ms 20 \
  --auth-workers 1 \
  --auth-queue-limit 1 \
  --auth-timeout-ms 30000 \
  --auth-poll-interval-ms 2 \
  --auth-result-batch-limit 2 \
  --auth-shutdown-grace-ms 30000 \
  --tls-cert "${WORK_DIR}/server.crt" \
  --tls-key "${WORK_DIR}/server.key" \
  --allow-anonymous false \
  --password-file "${WORK_DIR}/passwords" \
  --acl-file "${WORK_DIR}/acl" \
  >"${log}" 2>&1 &
BROKER_PID="$!"
for _ in $(seq 1 800); do
  grep -qF 'MQTT broker listening' "${log}" && break
  if ! kill -0 "${BROKER_PID}" 2>/dev/null; then
    sed -n '1,200p' "${log}" >&2
    exit 1
  fi
  sleep 0.025
done
sleep 0.05
node tests/integration/auth_isolation.mjs \
  "mqtts://localhost:${port}" "${WORK_DIR}/server.crt" isolation "${PASSWORD}"
kill -s TERM -- "-${BROKER_PID}"
wait "${BROKER_PID}"
BROKER_PID=""
! grep -qF "${PASSWORD}" "${log}"
! grep -qF "${password_hash}" "${log}"
echo 'AUTH ISOLATION real Argon2 progress, saturation, recovery, and shutdown passed'
