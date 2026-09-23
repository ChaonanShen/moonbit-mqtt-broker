#!/usr/bin/env bash
# Gates: maintained TOML parser, unknown/duplicate rejection, CLI precedence,
# side-effect-free validation, redacted output, and a real TLS/auth startup.
set -euo pipefail
trap 'echo "configuration gate failed at line $LINENO" >&2' ERR
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
auth_workers = 2
auth_queue_limit = 3
auth_timeout_ms = 9000
auth_poll_interval_ms = 4
auth_result_batch_limit = 5
auth_shutdown_grace_ms = 8000
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
grep -qxF 'auth_workers = 2' "${effective}"
grep -qxF 'auth_queue_limit = 3' "${effective}"
grep -qxF 'auth_timeout_ms = 9000' "${effective}"
grep -qxF 'auth_poll_interval_ms = 4' "${effective}"
grep -qxF 'auth_result_batch_limit = 5' "${effective}"
grep -qxF 'auth_shutdown_grace_ms = 8000' "${effective}"
! grep -qF "${WORK_DIR}/server.key" "${effective}"
! grep -qF "${WORK_DIR}/passwords" "${effective}"
test ! -e "${WORK_DIR}/data"

# Management is default-off. Configuration validation must not read the
# token file or bind a management port until the backend is implemented.
management_config="${WORK_DIR}/management.toml"
cat >"${management_config}" <<EOF
[management]
enabled = false
listen = "127.0.0.1:9191"
token_file = "${WORK_DIR}/absent-management.tokens"
max_connections = 8
max_header_bytes = 8192
max_header_count = 16
max_response_bytes = 32768
request_timeout_ms = 9000
write_timeout_ms = 3000
snapshot_interval_ms = 2000
snapshot_max_age_ms = 9000
ready_require_snapshot_healthy = true
request_rate = 40
request_burst = 80
connection_rate = 30
connection_burst = 60
max_bytes_total = 16777216
EOF
test ! -e "${WORK_DIR}/absent-management.tokens"
"${BROKER_EXECUTABLE}" --config "${management_config}" --check-config | grep -qxF 'configuration valid'
"${BROKER_EXECUTABLE}" --config "${management_config}" \
  --management-max-connections 9 --print-effective-config >"${WORK_DIR}/management-effective.toml"
grep -qxF 'max_connections = 9' "${WORK_DIR}/management-effective.toml"
grep -qxF 'listen = "127.0.0.1:9191"' "${WORK_DIR}/management-effective.toml"
grep -qxF 'max_bytes_total = 16777216' "${WORK_DIR}/management-effective.toml"
grep -qxF 'token_file = "<redacted>"' "${WORK_DIR}/management-effective.toml"
! grep -qF "${WORK_DIR}/absent-management.tokens" "${WORK_DIR}/management-effective.toml"
test ! -e "${WORK_DIR}/absent-management.tokens"
if "${BROKER_EXECUTABLE}" --management-enabled true --management-token-file "${WORK_DIR}/absent-management.tokens" \
    --check-config >"${WORK_DIR}/management-unavailable.log" 2>&1; then
  echo 'unimplemented management listener unexpectedly validated' >&2
  exit 1
fi
grep -qF 'management token file is unavailable' "${WORK_DIR}/management-unavailable.log"
if "${BROKER_EXECUTABLE}" --management-enabled true --management-token-file "${WORK_DIR}/absent-management.tokens" \
    --once --check-config >"${WORK_DIR}/management-once.log" 2>&1; then
  echo 'management and once were accepted together' >&2
  exit 1
fi
grep -qF -- '--once cannot be combined with management.enabled' "${WORK_DIR}/management-once.log"
for bad_args in \
  '--management-listen 0.0.0.0:9091' \
  '--management-max-header-bytes 1023' \
  '--management-max-response-bytes 262145' \
  '--management-enabled yes'; do
  read -r -a fields <<<"${bad_args}"
  if "${BROKER_EXECUTABLE}" "${fields[@]}" --check-config >/dev/null 2>&1; then
    echo "invalid management setting accepted: ${bad_args}" >&2
    exit 1
  fi
done

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

# QoS 1/2 pending aliases share one value; conflicts within one source are fatal.
"$BROKER_EXECUTABLE" --max-pending-total 3 --max-inbound-qos2-per-session 7 \
  --print-effective-config >"$WORK_DIR/qos2-effective.toml"
grep -qxF 'max_pending_total = 3' "$WORK_DIR/qos2-effective.toml"
grep -qxF 'max_inbound_qos2_per_session = 7' "$WORK_DIR/qos2-effective.toml"
if "$BROKER_EXECUTABLE" --max-pending-total 3 --max-pending-qos1-total 3 --check-config >/dev/null 2>&1; then
  echo 'conflicting CLI pending aliases accepted' >&2
  exit 1
fi
printf '[broker]\nmax_pending_total = 3\nmax_pending_qos1_total = 3\n' >"$WORK_DIR/qos2-conflict.toml"
if "$BROKER_EXECUTABLE" --config "$WORK_DIR/qos2-conflict.toml" --check-config >/dev/null 2>&1; then
  echo 'conflicting TOML pending aliases accepted' >&2
  exit 1
fi
printf '[broker]\nmax_pending_total = 3\n' >"$WORK_DIR/qos2-valid.toml"
"$BROKER_EXECUTABLE" --config "$WORK_DIR/qos2-valid.toml" --max-pending-qos1-total 5 \
  --print-effective-config >"$WORK_DIR/qos2-override.toml"
grep -qxF 'max_pending_total = 5' "$WORK_DIR/qos2-override.toml"

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
  -u config-user -P config-secret -i release-config-client \
  -t config/live -q 1 -m configured
kill -s TERM -- "-${BROKER_PID}"
wait "${BROKER_PID}"
BROKER_PID=""
test -d "${WORK_DIR}/data"
! grep -qF 'config-secret' "${broker_log}"
echo 'RELEASE TOML validation, precedence, redaction, and configured startup passed'
