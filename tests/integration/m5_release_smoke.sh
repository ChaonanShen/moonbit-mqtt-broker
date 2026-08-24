#!/usr/bin/env bash
# Gates:
# broker help has no filesystem or listener side effects
# basic publish subscribe example passes
# persistent session example passes
# restart persistence example passes
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

side_effect_dir="$(mktemp -d)"
trap 'rm -rf "${side_effect_dir}"' EXIT
help_output="$(moon run --target native src/cmd/broker -- --data-dir "${side_effect_dir}/help-data" --help)"
version_output="$(moon run --target native src/cmd/broker -- --data-dir "${side_effect_dir}/version-data" --version)"
grep -q '^Usage: broker \[OPTIONS\]$' <<<"${help_output}"
grep -q -- '--max-pending-qos1-total' <<<"${help_output}"
grep -q -- '--snapshot-retry-ms' <<<"${help_output}"
grep -q -- '--tls-handshake-timeout-ms' <<<"${help_output}"
[[ "${version_output}" = '0.1.0' ]]
[[ -z "$(find "${side_effect_dir}" -mindepth 1 -print -quit)" ]]

examples/basic_pubsub.sh

BROKER_LOG="$(mktemp)"
BROKER_PID=""
cleanup_broker() {
  if [[ -n "${BROKER_PID}" ]] && kill -0 "${BROKER_PID}" 2>/dev/null; then
    kill -- "-${BROKER_PID}" 2>/dev/null || kill "${BROKER_PID}" 2>/dev/null || true
    wait "${BROKER_PID}" 2>/dev/null || true
  fi
  rm -f "${BROKER_LOG}"
}
trap 'cleanup_broker; rm -rf "${side_effect_dir}"' EXIT
port="$(node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
setsid stdbuf -oL moon run --target native src/cmd/broker -- --listen "127.0.0.1:${port}" >"${BROKER_LOG}" 2>&1 &
BROKER_PID="$!"
for _ in $(seq 1 300); do
  grep -q 'MQTT broker listening' "${BROKER_LOG}" && break
  sleep 0.025
done
grep -q 'MQTT broker listening' "${BROKER_LOG}"
examples/persistent_session.sh 127.0.0.1 "${port}" | grep -q 'queued while subscriber is offline'
cleanup_broker
BROKER_PID=""

examples/restart_persistence.sh
echo 'M5 CLI and release examples smoke passed'
