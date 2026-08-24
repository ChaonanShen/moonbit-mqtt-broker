#!/usr/bin/env bash
# Gates: complete $SYS metric set, exact non-feedback counters, explicit ACL,
# TLS/auth/ACL failure metrics, JSON schema, log-level validation and redaction.
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

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
  -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout "${WORK_DIR}/server.key" -out "${WORK_DIR}/server.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
  -subj '/CN=wrong-ca' -keyout "${WORK_DIR}/wrong.key" \
  -out "${WORK_DIR}/wrong.crt" >/dev/null 2>&1
observer_hash="$(printf '%s' 'observer-secret' | argon2 'observer-salt-01' -id -e -t 2 -m 12 -p 1)"
ordinary_hash="$(printf '%s' 'ordinary-secret' | argon2 'ordinary-salt-01' -id -e -t 2 -m 12 -p 1)"
printf 'observer:%s\nordinary:%s\n' "${observer_hash}" "${ordinary_hash}" >"${WORK_DIR}/passwords"
chmod 0600 "${WORK_DIR}/passwords"
printf '%s\n' \
  'user observer' \
  'topic read $SYS/broker/#' \
  'topic read allowed/#' \
  'topic write allowed/#' \
  'user ordinary' \
  'topic read #' \
  >"${WORK_DIR}/acl"

port="$(free_port)"
broker_log="${WORK_DIR}/broker.jsonl"
setsid stdbuf -oL "${BROKER_EXECUTABLE}" \
  --listen "127.0.0.1:${port}" \
  --data-dir "${WORK_DIR}/data" \
  --snapshot-debounce-ms 20 \
  --snapshot-max-delay-ms 100 \
  --keep-alive-check-interval-ms 20 \
  --system-metrics-interval-ms 100 \
  --tls-cert "${WORK_DIR}/server.crt" \
  --tls-key "${WORK_DIR}/server.key" \
  --tls-handshake-timeout-ms 250 \
  --allow-anonymous false \
  --password-file "${WORK_DIR}/passwords" \
  --acl-file "${WORK_DIR}/acl" \
  --log-format json \
  --log-level debug \
  >"${broker_log}" 2>&1 &
BROKER_PID="$!"
for _ in $(seq 1 400); do
  grep -qF '"event":"broker_listening"' "${broker_log}" && break
  if ! kill -0 "${BROKER_PID}" 2>/dev/null; then
    sed -n '1,200p' "${broker_log}" >&2
    exit 1
  fi
  sleep 0.025
done
grep -qF '"event":"broker_listening"' "${broker_log}"

node tests/integration/m10_observability.mjs \
  "mqtts://localhost:${port}" "${WORK_DIR}/server.crt" "${WORK_DIR}/wrong.crt"
kill -s TERM -- "-${BROKER_PID}"
wait "${BROKER_PID}"
BROKER_PID=""

node - "${broker_log}" <<'NODE'
const fs = require('fs')
const lines = fs.readFileSync(process.argv[2], 'utf8').trim().split('\n')
const required = ['timestamp_ms', 'level', 'event', 'message', 'connection_id', 'client_id', 'principal', 'peer', 'reason', 'snapshot_revision']
for (const line of lines) {
  const record = JSON.parse(line)
  for (const field of required) if (!(field in record)) throw new Error(`missing ${field}: ${line}`)
}
for (const event of ['broker_listening', 'authentication_failed', 'acl_denied', 'tls_handshake_failed', 'snapshot_committed', 'shutdown_requested']) {
  if (!lines.some(line => JSON.parse(line).event === event)) throw new Error(`missing event ${event}`)
}
NODE
! grep -qF 'observer-secret' "${broker_log}"
! grep -qF 'ordinary-secret' "${broker_log}"
! grep -qF 'M10_PAYLOAD_SECRET_MARKER' "${broker_log}"
! grep -qF 'M10_FORGED_SECRET_MARKER' "${broker_log}"
! grep -qF '${argon2' "${broker_log}"

invalid_log="${WORK_DIR}/invalid.log"
if "${BROKER_EXECUTABLE}" --log-format yaml >"${invalid_log}" 2>&1; then
  echo 'invalid log format unexpectedly accepted' >&2
  exit 1
fi
grep -qF -- '--log-format requires text or json' "${invalid_log}"
echo 'M10 system metrics, JSON logs, levels, ACL isolation, and redaction passed'
