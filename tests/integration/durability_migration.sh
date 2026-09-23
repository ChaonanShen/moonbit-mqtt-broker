#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
BROKER="${BROKER_EXECUTABLE:-$PWD/_build/native/debug/build/cmd/broker/broker.exe}"
ARTIFACT_ROOT="${RELEASE_ARTIFACT_DIR:-$PWD/.local/durability-tests}"
mkdir -p "$ARTIFACT_ROOT"
RUN_DIR="$(mktemp -d "$ARTIFACT_ROOT/migration-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
printf 'DURABILITY_RUN_DIR=%s\n' "$RUN_DIR"
printf 'sha=%s\nbroker=%s\n' "${CANDIDATE_SHA:-$(git rev-parse HEAD)}" "$BROKER" >"$RUN_DIR/metadata.txt"
mkdir -m 700 "$RUN_DIR/data" "$RUN_DIR/backup"
port="$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
url="mqtt://127.0.0.1:$port"
pid=''
phase=''
cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
start() {
  phase="$1"
  setsid stdbuf -oL "$BROKER" --listen "127.0.0.1:$port" \
    --data-dir "$3" --persistence-mode "$2" >"$RUN_DIR/$phase.broker.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 400); do
    if grep -q 'MQTT broker listening' "$RUN_DIR/$phase.broker.log"; then return; fi
    if ! kill -0 "$pid" 2>/dev/null; then cat "$RUN_DIR/$phase.broker.log" >&2; return 1; fi
    sleep 0.025
  done
  cat "$RUN_DIR/$phase.broker.log" >&2
  return 1
}
stop() {
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null
  set +e
  wait "$pid"
  rc=$?
  set -e
  pid=''
  printf '%s\n' "$rc" >"$RUN_DIR/$phase.exit-code"
  [[ "$rc" -eq 0 ]]
}
probe() {
  timeout -k 2 15 node tests/integration/durability_recovery_probe.mjs "$1" "$url" "$2" \
    >"$RUN_DIR/$3.client.log" 2>&1
}
start snapshot snapshot "$RUN_DIR/data"
probe seed snapshot-marker snapshot
stop
test -s "$RUN_DIR/data/broker.snapshot"
test ! -e "$RUN_DIR/data/broker.manifest"
cp -a "$RUN_DIR/data/." "$RUN_DIR/backup/"
before="$(sha256sum "$RUN_DIR/backup/broker.snapshot" | awk '{print $1}')"
"$BROKER" --check-config --listen "127.0.0.1:$port" \
  --data-dir "$RUN_DIR/data" --persistence-mode strict >"$RUN_DIR/check-config.log" 2>&1
test ! -e "$RUN_DIR/data/broker.manifest"
start strict strict "$RUN_DIR/data"
test -s "$RUN_DIR/data/broker.manifest"
probe verify snapshot-marker strict-import
probe seed strict-marker strict-update
stop
test "$(sha256sum "$RUN_DIR/backup/broker.snapshot" | awk '{print $1}')" = "$before"
set +e
"$BROKER" --listen "127.0.0.1:$port" --data-dir "$RUN_DIR/data" \
  --persistence-mode snapshot >"$RUN_DIR/snapshot-refusal.log" 2>&1
refusal=$?
set -e
[[ "$refusal" -ne 0 ]]
grep -q 'strict WAL directory cannot start in snapshot mode' "$RUN_DIR/snapshot-refusal.log"
start strict-restart strict "$RUN_DIR/data"
probe verify strict-marker strict-restart
stop
start rollback snapshot "$RUN_DIR/backup"
probe verify snapshot-marker rollback
stop
printf 'MIGRATION_ROLLBACK_PASS snapshot backup, strict import, restart and rejection\n'
printf '0\n' >"$RUN_DIR/exit-code"
