#!/usr/bin/env bash
set -Eeuo pipefail
readonly REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
moon build --target native
readonly BROKER="$REPO_ROOT/_build/native/debug/build/cmd/broker/broker.exe"
readonly WORK_DIR="$(mktemp -d)"
broker_pid=""
cleanup() {
  if [[ -n "$broker_pid" ]]; then
    kill "$broker_pid" 2>/dev/null || true
    wait "$broker_pid" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
free_port() {
  node -e 'const n=require("node:net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}
tcp_port="$(free_port)"
tls_port="$(free_port)"
ws_port="$(free_port)"
wss_port="$(free_port)"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1   -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'   -keyout "$WORK_DIR/server.key" -out "$WORK_DIR/server.crt" >/dev/null 2>&1
chmod 0600 "$WORK_DIR/server.key"
for variant in missing symbols; do
  extra=()
  if [[ "$variant" = symbols ]]; then
    extra=(-DMANAGEMENT_TEST_NO_SYMBOLS)
  fi
  cc -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -shared -fPIC     "${extra[@]}" tests/integration/management_crypto_missing.c -ldl     -o "$WORK_DIR/$variant-libcrypto.so"
  if LD_PRELOAD="$WORK_DIR/$variant-libcrypto.so" "$BROKER"       --listener-id browser --listener-transport ws       --listener-listen 127.0.0.1:8083 --check-config       >"$WORK_DIR/$variant-ws.log" 2>&1; then
    echo "WS unexpectedly accepted $variant libcrypto" >&2
    exit 1
  fi
  grep -qF 'WS/WSS requires libcrypto.so.3' "$WORK_DIR/$variant-ws.log"
  LD_PRELOAD="$WORK_DIR/$variant-libcrypto.so" "$BROKER" --check-config |
    grep -qxF 'configuration valid'
done
cat >"$WORK_DIR/broker.toml" <<EOF
[server]
max_connections = 32
[[listeners]]
id = "tcp"
transport = "tcp"
listen = "127.0.0.1:$tcp_port"
max_connections = 32
[[listeners]]
id = "tls"
transport = "tls"
listen = "127.0.0.1:$tls_port"
max_connections = 32
tls_cert = "$WORK_DIR/server.crt"
tls_key = "$WORK_DIR/server.key"
[[listeners]]
id = "ws"
transport = "ws"
listen = "127.0.0.1:$ws_port"
max_connections = 32
[[listeners]]
id = "wss"
transport = "wss"
listen = "127.0.0.1:$wss_port"
max_connections = 32
tls_cert = "$WORK_DIR/server.crt"
tls_key = "$WORK_DIR/server.key"
EOF
"$BROKER" --config "$WORK_DIR/broker.toml" >"$WORK_DIR/broker.log" 2>&1 &
broker_pid=$!
if ! timeout 45 node tests/integration/transports.mjs   "$tcp_port" "$tls_port" "$ws_port" "$wss_port" "$WORK_DIR/server.crt"; then
  cat "$WORK_DIR/broker.log" >&2
  exit 1
fi
echo 'TRANSPORTS integration passed'
