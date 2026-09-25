#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
BROKER="${BROKER_EXECUTABLE:-$ROOT/_build/native/debug/build/cmd/broker/broker.exe}"
test -x "$BROKER"
BASE="${MQTT5_EVIDENCE_DIR:-$ROOT/.local/mqtt5-integration}"
mkdir -p "$BASE"
RUN_DIR="$(mktemp -d "$BASE/mosquitto-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
port="$(node -e 'const n=require("net"),s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
pid=""
subpid=""
stop() {
  if [[ -n "$subpid" ]]; then
    kill "$subpid" 2>/dev/null || true
    wait "$subpid" 2>/dev/null || true
  fi
  if [[ -n "$pid" ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}
trap stop EXIT
printf 'candidate_sha=%s\nbroker=%s\nport=%s\nstarted_at=%s\n'   "${CANDIDATE_SHA:-unbound}" "$BROKER" "$port" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"   >"$RUN_DIR/metadata.txt"
dpkg-query -W mosquitto-clients >"$RUN_DIR/mosquitto-version.txt"
test "$(awk '{print $2}' "$RUN_DIR/mosquitto-version.txt")" = "2.0.18-1build3"
stdbuf -oL "$BROKER" --listen "127.0.0.1:$port" --mqtt5-enabled true   --persistence-mode off >"$RUN_DIR/broker.log" 2>&1 &
pid="$!"
for _ in $(seq 1 160); do
  if grep -q broker_listening "$RUN_DIR/broker.log"; then break; fi
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$RUN_DIR/broker.log" >&2
    exit 1
  fi
  sleep 0.05
done
grep -q broker_listening "$RUN_DIR/broker.log"
run_pair() {
  local label="$1" subscriber_version="$2" publisher_version="$3"
  local topic="interop/$label" payload="mosquitto-$label"
  timeout 12 stdbuf -oL -eL mosquitto_sub -h 127.0.0.1 -p "$port" -V "$subscriber_version" -i "interop-sub-$label" -t "$topic" -q 1 -C 1 -W 10 -F "PAYLOAD:%p" -d >"$RUN_DIR/$label.sub.log" 2>&1 &
  subpid="$!"
  local subscribed=0
  for _ in $(seq 1 100); do
    if grep -qi 'received SUBACK' "$RUN_DIR/$label.sub.log"; then
      subscribed=1
      break
    fi
    if ! kill -0 "$subpid" 2>/dev/null; then break; fi
    sleep 0.05
  done
  if [[ "$subscribed" != 1 ]]; then
    cat "$RUN_DIR/$label.sub.log" >&2
    return 1
  fi
  timeout 12 mosquitto_pub -h 127.0.0.1 -p "$port" -V "$publisher_version"     -i "interop-pub-$label" -t "$topic" -q 1 -m "$payload" -d     >"$RUN_DIR/$label.pub.log" 2>&1
  wait "$subpid"
  subpid=""
  grep -Fxq "PAYLOAD:$payload" "$RUN_DIR/$label.sub.log"
  echo "C-T13/X-T15 Mosquitto $subscriber_version <- $publisher_version passed"
}
run_pair v5-to-v311 mqttv311 mqttv5
run_pair v311-to-v5 mqttv5 mqttv311
kill -TERM "$pid"
wait "$pid"
pid=""
printf 'completed_at=%s\nexit_code=0\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"   >>"$RUN_DIR/metadata.txt"
echo "MQTT5_MOSQUITTO_PASS $RUN_DIR"
