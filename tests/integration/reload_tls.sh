#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
RELOAD_EVIDENCE_DIR="${RELOAD_EVIDENCE_DIR:-$REPO_ROOT/.local/reload-integration/reload-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
moon build --target native >/dev/null
if [[ ! -d tests/integration/node_modules/mqtt ]]; then
  npm ci --prefix tests/integration --ignore-scripts >/dev/null
fi
readonly BROKER="$REPO_ROOT/_build/native/debug/build/cmd/broker/broker.exe"
work="$(mktemp -d)"
broker_pid=""
cleanup() {
  rc=$?
  if [[ -n "$broker_pid" ]]; then
    kill -TERM "$broker_pid" 2>/dev/null || true
    wait "$broker_pid" 2>/dev/null || true
  fi
  mkdir -p "$RELOAD_EVIDENCE_DIR"
  grep -E 'event=(broker_listening|reload_completed|reload_failed|shutdown_requested)' \
    "$work/broker.log" >"$RELOAD_EVIDENCE_DIR/tls-events.log" 2>/dev/null || true
  printf 'case=reload_tls\nexit_code=%s\n' "$rc" \
    >"$RELOAD_EVIDENCE_DIR/tls-summary.txt"
  if [[ "$rc" -ne 0 ]]; then
    cp "$work/broker.log" "$RELOAD_EVIDENCE_DIR/debug-broker.log" || true
  fi
  rm -rf -- "$work"
  exit "$rc"
}
trap cleanup EXIT
free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}
tls_port="$(free_port)"
wss_port="$(free_port)"
mkdir "$work/runtime"
chmod 700 "$work/runtime"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
  -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
chmod 600 "$work/key.pem"
cat >"$work/config.toml" <<EOF
[limits]
enabled = false
per_ip_enabled = false
[reload]
enabled = true
manifest_file = "$work/manifest.toml"
material_runtime_dir = "$work/runtime"
[[listeners]]
id = "edge"
transport = "tls"
listen = "127.0.0.1:$tls_port"
tls_cert = "$work/cert.pem"
tls_key = "$work/key.pem"
[[listeners]]
id = "browser"
transport = "wss"
listen = "127.0.0.1:$wss_port"
tls_cert = "$work/cert.pem"
tls_key = "$work/key.pem"
EOF
cat >"$work/manifest.toml" <<EOF
version = 1
[[materials]]
role = "config"
path = "$work/config.toml"
sha256 = "$(sha256sum "$work/config.toml" | cut -d' ' -f1)"
[[materials]]
role = "mqtt_cert"
listener_id = "edge"
path = "$work/cert.pem"
sha256 = "$(sha256sum "$work/cert.pem" | cut -d' ' -f1)"
[[materials]]
role = "mqtt_key"
listener_id = "edge"
path = "$work/key.pem"
sha256 = "$(sha256sum "$work/key.pem" | cut -d' ' -f1)"
[[materials]]
role = "mqtt_cert"
listener_id = "browser"
path = "$work/cert.pem"
sha256 = "$(sha256sum "$work/cert.pem" | cut -d' ' -f1)"
[[materials]]
role = "mqtt_key"
listener_id = "browser"
path = "$work/key.pem"
sha256 = "$(sha256sum "$work/key.pem" | cut -d' ' -f1)"
EOF
chmod 600 "$work/manifest.toml"
: >"$work/broker.log"
setsid stdbuf -oL -eL "$BROKER" --config "$work/config.toml" \
  >"$work/broker.log" 2>&1 &
broker_pid=$!
for _ in $(seq 1 800); do
  if grep -q broker_listening "$work/broker.log"; then break; fi
  if ! kill -0 "$broker_pid" 2>/dev/null; then cat "$work/broker.log" >&2; exit 1; fi
  sleep 0.025
done
grep -q broker_listening "$work/broker.log"
node tests/integration/reload_tls.mjs \
  "$tls_port" "$wss_port" "$work/config.toml" "$work/manifest.toml" \
  "$work/cert.pem" "$work/key.pem" "$work/runtime" "$work/broker.log" "$broker_pid" "$BROKER"
grep -q reload_completed "$work/broker.log"
kill -TERM "$broker_pid"
wait "$broker_pid"
broker_pid=""
test -z "$(find "$work/runtime" -mindepth 1 -print -quit)"
echo 'reload TLS/WSS passed'

