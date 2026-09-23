#!/usr/bin/env bash
set -euo pipefail
trap 'echo "management admin gate failed at line $LINENO" >&2' ERR
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
readonly ROOT
cd "$ROOT"
moon build --target native
if [[ "$#" -eq 0 || "$1" != "--prepared" ]]; then
  npm ci --prefix tests/integration --ignore-scripts >/dev/null
fi
readonly BROKER="$ROOT/_build/native/debug/build/cmd/broker/broker.exe"
WORK_DIR="$(mktemp -d)"
BROKER_PID=""
SLOW_PID=""
cleanup() {
  if [[ -n "$SLOW_PID" ]] && kill -0 "$SLOW_PID" 2>/dev/null; then
    kill "$SLOW_PID" 2>/dev/null || true
    wait "$SLOW_PID" 2>/dev/null || true
  fi
  if [[ -n "$BROKER_PID" ]] && kill -0 "$BROKER_PID" 2>/dev/null; then
    kill -TERM "$BROKER_PID" 2>/dev/null || true
    wait "$BROKER_PID" 2>/dev/null || true
  fi
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}
mqtt_port="$(free_port)"
admin_port="$(free_port)"
if [[ "$mqtt_port" = "$admin_port" ]]; then admin_port="$(free_port)"; fi
READ_TOKEN='breader.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
OPERATOR_TOKEN='boperator.abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
CONFIG_TOKEN='bconfig.00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'
node -e '
const c=require("crypto");
for(const [token,scopes] of [[process.argv[1],"read"],[process.argv[2],"operator"],[process.argv[3],"config_admin"]]){
  const id=token.split(".")[0];
  const digest=c.createHash("sha256").update("moonbit-mqtt-broker/admin/v1:"+token).digest("hex");
  process.stdout.write(id+":"+digest+":"+scopes+"\n");
}
' "$READ_TOKEN" "$OPERATOR_TOKEN" "$CONFIG_TOKEN" >"$WORK_DIR/tokens"
chmod 0600 "$WORK_DIR/tokens"
"$BROKER" --listen "127.0.0.1:$mqtt_port" --rate-limits-enabled false \
  --management-enabled true --management-details-enabled true \
  --management-operations-enabled true --management-max-bytes-total 33554432 \
  --management-max-audit-records 64 \
  --management-request-rate 10000 --management-request-burst 20000 \
  --management-connection-rate 10000 --management-connection-burst 20000 \
  --management-command-rate 1000 --management-command-burst 2000 \
  --management-listen "127.0.0.1:$admin_port" \
  --management-token-file "$WORK_DIR/tokens" >"$WORK_DIR/broker.log" 2>&1 &
BROKER_PID="$!"
for _ in $(seq 1 100); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$admin_port/health/live" >/dev/null 2>&1; then break; fi
  if ! kill -0 "$BROKER_PID" 2>/dev/null; then
    cat "$WORK_DIR/broker.log" >&2
    exit 1
  fi
  sleep 0.05
done
fd_before="$(find "/proc/$BROKER_PID/fd" -maxdepth 1 -type l | wc -l)"
if [[ ! -v MANAGEMENT_ADMIN_STRESS ]]; then MANAGEMENT_ADMIN_STRESS=0; fi
MANAGEMENT_ADMIN_STRESS="$MANAGEMENT_ADMIN_STRESS" \
  node tests/integration/management_admin.mjs "$admin_port" "$mqtt_port" \
  "$READ_TOKEN" "$OPERATOR_TOKEN" "$CONFIG_TOKEN" >"$WORK_DIR/result.json"
cat "$WORK_DIR/result.json"
sleep 0.2
fd_after="$(find "/proc/$BROKER_PID/fd" -maxdepth 1 -type l | wc -l)"
if (( fd_after > fd_before + 3 )); then
  echo "management admin fd growth: before=$fd_before after=$fd_after" >&2
  exit 1
fi
if [[ -v MANAGEMENT_ADMIN_OUTPUT && -n "$MANAGEMENT_ADMIN_OUTPUT" ]]; then
  cp "$WORK_DIR/result.json" "$MANAGEMENT_ADMIN_OUTPUT"
fi
! grep -qF "$READ_TOKEN" "$WORK_DIR/broker.log"
! grep -qF "$OPERATOR_TOKEN" "$WORK_DIR/broker.log"
! grep -qF "$CONFIG_TOKEN" "$WORK_DIR/broker.log"
node -e '
const net=require("net"),fs=require("fs");
const socket=net.connect(Number(process.argv[1]),"127.0.0.1",()=>{
  socket.write("GET /v1/sessions HTTP/1.1\r\nHost: ");
  fs.writeFileSync(process.argv[2],"ready");
});
socket.on("error",()=>process.exit(2));
setInterval(()=>{},1000);
' "$admin_port" "$WORK_DIR/slow-ready" >"$WORK_DIR/slow.log" 2>&1 &
SLOW_PID="$!"
for _ in $(seq 1 100); do
  test -e "$WORK_DIR/slow-ready" && break
  sleep 0.01
done
test -e "$WORK_DIR/slow-ready"
kill -TERM "$BROKER_PID"
for _ in $(seq 1 100); do
  state="$(ps -o stat= -p "$BROKER_PID" 2>/dev/null | tr -d ' ' || true)"
  [[ -z "$state" || "$state" = Z* ]] && break
  sleep 0.05
done
state="$(ps -o stat= -p "$BROKER_PID" 2>/dev/null | tr -d ' ' || true)"
if [[ -n "$state" && "$state" != Z* ]]; then
  echo 'management admin shutdown did not drain' >&2
  exit 1
fi
wait "$BROKER_PID"
BROKER_PID=""
kill "$SLOW_PID" 2>/dev/null || true
wait "$SLOW_PID" 2>/dev/null || true
SLOW_PID=""
echo 'MANAGEMENT admin detail, delete, kick, idempotency, audit and shutdown passed'
