#!/usr/bin/env bash
# Gates: maintained TOML parser, unknown/duplicate rejection, CLI precedence,
# side-effect-free validation, redacted output, and a real TLS/auth startup.
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
password_hash="$(printf '%s' 'config-secret' | argon2 'config-salt-0001' -id -e -t 2 -m 12 -p 1)"
printf 'config-user:%s\n' "${password_hash}" >"${WORK_DIR}/passwords"
chmod 0600 "${WORK_DIR}/passwords"
printf '%s\n' \
  'user config-user' \
  'topic read config/#' \
  'topic write config/#' \
  >"${WORK_DIR}/acl"

config_file="${WORK_DIR}/broker.toml"
cat >"${config_file}" <<EOF
[server]
listen = "127.0.0.1:1"
max_connections = 42
keep_alive_check_interval_ms = 20

[broker]
persistent_session_expiry = "2h"
max_session_expirations_per_tick = 16

[persistence]
data_dir = "${WORK_DIR}/data"
snapshot_debounce_ms = 20
snapshot_max_delay_ms = 100

[tls]
cert = "${WORK_DIR}/server.crt"
key = "${WORK_DIR}/server.key"
handshake_timeout_ms = 500

[security]
allow_anonymous = false
password_file = "${WORK_DIR}/passwords"
acl_file = "${WORK_DIR}/acl"

[observability]
system_metrics_interval_ms = 100
log_format = "text"
log_level = "info"
EOF

check_output="$(${BROKER_EXECUTABLE} --config "${config_file}" --check-config)"
grep -qxF 'configuration valid' <<<"${check_output}"
test ! -e "${WORK_DIR}/data"

effective="${WORK_DIR}/effective.toml"
"${BROKER_EXECUTABLE}" --config "${config_file}" \
  --max-connections 7 --print-effective-config >"${effective}"
grep -qxF 'max_connections = 7' "${effective}"
grep -qxF 'persistent_session_expiry = "7200000ms"' "${effective}"
grep -qxF 'key = "<redacted>"' "${effective}"
grep -qxF 'password_file = "<redacted>"' "${effective}"
! grep -qF "${WORK_DIR}/server.key" "${effective}"
! grep -qF "${WORK_DIR}/passwords" "${effective}"
test ! -e "${WORK_DIR}/data"

printf '[server]\nunknown = 1\n' >"${WORK_DIR}/unknown.toml"
if "${BROKER_EXECUTABLE}" --config "${WORK_DIR}/unknown.toml" --check-config >/dev/null 2>&1; then
  echo 'unknown TOML key unexpectedly accepted' >&2
  exit 1
fi
printf '[server]\nmax_connections = 1\nmax_connections = 2\n' >"${WORK_DIR}/duplicate.toml"
if "${BROKER_EXECUTABLE}" --config "${WORK_DIR}/duplicate.toml" --check-config >/dev/null 2>&1; then
  echo 'duplicate TOML key unexpectedly accepted' >&2
  exit 1
fi

port="$(free_port)"
broker_log="${WORK_DIR}/broker.log"
setsid stdbuf -oL "${BROKER_EXECUTABLE}" --config "${config_file}" \
  --listen "127.0.0.1:${port}" >"${broker_log}" 2>&1 &
BROKER_PID="$!"
for _ in $(seq 1 400); do
  grep -qF 'MQTT broker listening' "${broker_log}" && break
  if ! kill -0 "${BROKER_PID}" 2>/dev/null; then
    sed -n '1,200p' "${broker_log}" >&2
    exit 1
  fi
  sleep 0.025
done
mosquitto_pub -h localhost -p "${port}" --cafile "${WORK_DIR}/server.crt" \
  -u config-user -P config-secret -i m11-config-client \
  -t config/live -q 1 -m configured
kill -s TERM -- "-${BROKER_PID}"
wait "${BROKER_PID}"
BROKER_PID=""
test -d "${WORK_DIR}/data"
! grep -qF 'config-secret' "${broker_log}"
echo 'M11 TOML validation, precedence, redaction, and configured startup passed'
