#!/usr/bin/env bash
set -Eeuo pipefail
readonly ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
readonly BROKER="${BROKER_EXECUTABLE:-$ROOT/_build/native/debug/build/cmd/broker/broker.exe}"
readonly ARTIFACT_ROOT="${RELEASE_ARTIFACT_DIR:-$ROOT/.local/durability-tests}"
mkdir -p "$ARTIFACT_ROOT"
readonly RUN_DIR="$(mktemp -d "$ARTIFACT_ROOT/commit-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
printf 'DURABILITY_RUN_DIR=%s\n' "$RUN_DIR"
candidate_sha="${CANDIDATE_SHA:-$(git rev-parse HEAD)}"
[[ "$candidate_sha" =~ ^[0-9a-f]{40}$ ]]
printf 'sha=%s\nbroker=%s\n' "$candidate_sha" "$BROKER" >"$RUN_DIR/metadata.txt"
mkdir -m 700 "$RUN_DIR/data"
cc -std=c11 -Wall -Wextra -Werror -shared -fPIC \
  tests/integration/durability_fsync_hold.c -ldl -o "$RUN_DIR/hold-fsync.so"
port="$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
printf 'port=%s\n' "$port" >>"$RUN_DIR/metadata.txt"
marker="$RUN_DIR/fsync-held.marker"
release="$RUN_DIR/fsync-release.marker"
arm="$RUN_DIR/fsync-arm.marker"
broker_pid=''
cleanup() {
  if [[ -n "$broker_pid" ]] && kill -0 "$broker_pid" 2>/dev/null; then
    kill -- "-$broker_pid" 2>/dev/null || kill "$broker_pid" 2>/dev/null || true
    wait "$broker_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
start_broker() {
  local phase="$1"
  shift
  setsid stdbuf -oL env "$@" "$BROKER" \
    --listen "127.0.0.1:$port" --data-dir "$RUN_DIR/data" \
    --persistence-mode strict --keep-alive-check-interval-ms 20 \
    >"$RUN_DIR/$phase.broker.log" 2>&1 &
  broker_pid=$!
  for _ in $(seq 1 400); do
    if grep -q 'MQTT broker listening' "$RUN_DIR/$phase.broker.log"; then return 0; fi
    if ! kill -0 "$broker_pid" 2>/dev/null; then
      cat "$RUN_DIR/$phase.broker.log" >&2
      return 1
    fi
    sleep 0.025
  done
  cat "$RUN_DIR/$phase.broker.log" >&2
  return 1
}
start_broker held \
  "LD_PRELOAD=$RUN_DIR/hold-fsync.so:/usr/libexec/coreutils/libstdbuf.so" \
  "MQTT_WAL_FSYNC_ARM=$arm" \
  "MQTT_WAL_FSYNC_MARKER=$marker" \
  "MQTT_WAL_FSYNC_RELEASE=$release"
timeout -k 2 25 node tests/integration/durability_commit.mjs barrier \
  "mqtt://127.0.0.1:$port" "$arm" "$marker" "$release" \
  "$RUN_DIR/barrier.json" >"$RUN_DIR/barrier.client.log" 2>&1
[[ -s "$RUN_DIR/barrier.json" && -s "$marker" && -s "$release" ]]
# Kill only the broker after the independent client has recorded its PUBACK.
kill -KILL -- "-$broker_pid" 2>/dev/null || kill -KILL "$broker_pid"
set +e
wait "$broker_pid"
kill_rc=$?
set -e
broker_pid=''
printf '%s\n' "$kill_rc" >"$RUN_DIR/held.kill.exit-code"
[[ "$kill_rc" -eq 137 || "$kill_rc" -eq 9 ]]
start_broker recovered
timeout -k 2 20 node tests/integration/durability_commit.mjs verify \
  "mqtt://127.0.0.1:$port" >"$RUN_DIR/recovered.client.log" 2>&1
kill -- "-$broker_pid" 2>/dev/null || kill "$broker_pid"
set +e
wait "$broker_pid"
stop_rc=$?
set -e
broker_pid=''
printf '%s\n' "$stop_rc" >"$RUN_DIR/recovered.exit-code"
[[ "$stop_rc" -eq 0 ]]
grep -qF 'DURABILITY_BARRIER_PASS' "$RUN_DIR/barrier.client.log"
grep -qF 'DURABILITY_CRASH_RECOVERY_PASS' "$RUN_DIR/recovered.client.log"
sha256sum "$RUN_DIR"/data/wal-*.log >"$RUN_DIR/wal-hashes.txt"
printf 'DURABILITY_COMMIT_PASS %s\n' "$RUN_DIR"
