#!/usr/bin/env bash
set -Eeuo pipefail
readonly ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
readonly BROKER="${BROKER_EXECUTABLE:-$ROOT/_build/native/debug/build/cmd/broker/broker.exe}"
readonly ARTIFACT_ROOT="${RELEASE_ARTIFACT_DIR:-$ROOT/.local/durability-tests}"
mkdir -p "$ARTIFACT_ROOT"
readonly RUN_DIR="$(mktemp -d "$ARTIFACT_ROOT/transports-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
printf 'DURABILITY_RUN_DIR=%s\n' "$RUN_DIR"
candidate_sha="${CANDIDATE_SHA:-$(git rev-parse HEAD)}"
[[ "$candidate_sha" =~ ^[0-9a-f]{40}$ ]]
printf 'sha=%s\nbroker=%s\n' "$candidate_sha" "$BROKER" >"$RUN_DIR/metadata.txt"
free_port() {
  node -e 'const s=require("node:net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}
readonly TCP_PORT="$(free_port)"
readonly TLS_PORT="$(free_port)"
readonly WS_PORT="$(free_port)"
readonly WSS_PORT="$(free_port)"
printf 'tcp=%s\ntls=%s\nws=%s\nwss=%s\n' "$TCP_PORT" "$TLS_PORT" "$WS_PORT" "$WSS_PORT" >>"$RUN_DIR/metadata.txt"
mkdir -m 700 "$RUN_DIR/data"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
  -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout "$RUN_DIR/server.key" -out "$RUN_DIR/server.crt" >/dev/null 2>&1
chmod 0600 "$RUN_DIR/server.key"
cat >"$RUN_DIR/broker.toml" <<EOF
[persistence]
mode = "strict"
data_dir = "$RUN_DIR/data"
[server]
max_connections = 32
[[listeners]]
id = "tcp"
transport = "tcp"
listen = "127.0.0.1:$TCP_PORT"
max_connections = 32
[[listeners]]
id = "tls"
transport = "tls"
listen = "127.0.0.1:$TLS_PORT"
max_connections = 32
tls_cert = "$RUN_DIR/server.crt"
tls_key = "$RUN_DIR/server.key"
[[listeners]]
id = "ws"
transport = "ws"
listen = "127.0.0.1:$WS_PORT"
max_connections = 32
[[listeners]]
id = "wss"
transport = "wss"
listen = "127.0.0.1:$WSS_PORT"
max_connections = 32
tls_cert = "$RUN_DIR/server.crt"
tls_key = "$RUN_DIR/server.key"
EOF
broker_pid=''
current_phase=''
stop_broker() {
  if [[ -z "$broker_pid" ]]; then return 0; fi
  if kill -0 "$broker_pid" 2>/dev/null; then
    kill -- "-$broker_pid" 2>/dev/null || kill "$broker_pid" 2>/dev/null || true
  fi
  set +e
  wait "$broker_pid"
  local rc=$?
  set -e
  printf '%s\n' "$rc" >"$RUN_DIR/$current_phase.exit-code"
  broker_pid=''
  [[ "$rc" -eq 0 ]]
}
trap stop_broker EXIT
start_broker() {
  current_phase="$1"
  setsid stdbuf -oL "$BROKER" --config "$RUN_DIR/broker.toml" \
    >"$RUN_DIR/$current_phase.broker.log" 2>&1 &
  broker_pid=$!
  for _ in $(seq 1 400); do
    if [[ "$(grep -c 'MQTT broker listening' "$RUN_DIR/$current_phase.broker.log" || true)" -ge 4 ]]; then
      return 0
    fi
    if ! kill -0 "$broker_pid" 2>/dev/null; then
      cat "$RUN_DIR/$current_phase.broker.log" >&2
      return 1
    fi
    sleep 0.025
  done
  cat "$RUN_DIR/$current_phase.broker.log" >&2
  return 1
}
args=("$TCP_PORT" "$TLS_PORT" "$WS_PORT" "$WSS_PORT" "$RUN_DIR/server.crt")
start_broker seed
timeout -k 2 45 node tests/integration/transports.mjs "${args[@]}" \
  >"$RUN_DIR/qos1-four-entry.log" 2>&1
timeout -k 2 45 node tests/integration/durability_transports.mjs seed "${args[@]}" \
  >"$RUN_DIR/seed.client.log" 2>&1
stop_broker
start_broker verify
timeout -k 2 45 node tests/integration/durability_transports.mjs verify "${args[@]}" \
  >"$RUN_DIR/verify.client.log" 2>&1
stop_broker
if [[ "${RELEASE_SOAK:-0}" == 1 ]]; then
  soak_seconds="${RELEASE_SOAK_SECONDS:-600}"
  soak_publications="${STRICT_SOAK_PUBLICATIONS:-20000}"
  start_broker soak
  timeout -k 2 "$((soak_seconds + 40))" node \
    tests/integration/durability_soak.mjs \
    "mqtt://127.0.0.1:$TCP_PORT" "$soak_seconds" "$soak_publications" \
    "$RUN_DIR/soak.json" >"$RUN_DIR/soak.client.log" 2>&1
  stop_broker
  grep -q 'DURABILITY_SOAK_PASS' "$RUN_DIR/soak.client.log"
  test -s "$RUN_DIR/soak.json"
fi
grep -qxF 'DURABILITY_TRANSPORT_SEED_PASS four-entry ACK and persistent queue' "$RUN_DIR/seed.client.log"
grep -qxF 'DURABILITY_TRANSPORT_VERIFY_PASS QoS2 recovery retained and TCP-WSS takeover' "$RUN_DIR/verify.client.log"
[[ "$(cat "$RUN_DIR/seed.exit-code")" == 0 && "$(cat "$RUN_DIR/verify.exit-code")" == 0 ]]
printf 'DURABILITY_TRANSPORTS_PASS %s\n' "$RUN_DIR"
