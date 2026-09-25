#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
BROKER="$ROOT/_build/native/debug/build/cmd/broker/broker.exe"
if [[ -v BROKER_EXECUTABLE ]]; then BROKER="$BROKER_EXECUTABLE"; fi
if [[ $# -eq 0 || "$1" != "--prepared" ]]; then moon build --target native; fi
BASE="$ROOT/.local/mqtt5-integration"
if [[ -v RELEASE_ARTIFACT_DIR ]]; then BASE="$RELEASE_ARTIFACT_DIR"; fi
if [[ -v MQTT5_EVIDENCE_DIR ]]; then BASE="$MQTT5_EVIDENCE_DIR"; fi
mkdir -p "$BASE"
RUN_DIR="$(mktemp -d "$BASE/migration-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
mkdir -m 700 "$RUN_DIR/data" "$RUN_DIR/backup"
sha="unbound"
if [[ -v CANDIDATE_SHA ]]; then sha="$CANDIDATE_SHA"; fi
printf 'sha=%s\nbroker=%s\n' "$sha" "$BROKER" >"$RUN_DIR/metadata.txt"
port="$(node -e 'const n=require("net"),s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
pid=""
start() {
  local phase="$1" enabled="$2" data="$3" mode="strict"
  if [[ $# -ge 4 ]]; then mode="$4"; fi
  stdbuf -oL "$BROKER" --listen "127.0.0.1:$port" \
    --mqtt5-enabled "$enabled" --data-dir "$data" \
    --persistence-mode "$mode" >"$RUN_DIR/$phase.broker.log" 2>&1 &
  pid="$!"
  for _ in $(seq 1 200); do
    if grep -q broker_listening "$RUN_DIR/$phase.broker.log"; then return; fi
    if ! kill -0 "$pid" 2>/dev/null; then cat "$RUN_DIR/$phase.broker.log" >&2; exit 1; fi
    sleep 0.05
  done
  cat "$RUN_DIR/$phase.broker.log" >&2
  exit 1
}
stop() { kill -TERM "$pid"; wait "$pid"; pid=""; }
trap 'if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi' EXIT
stage() {
  local label="$1"
  if [[ $# -ge 2 ]]; then label="$2"; fi
  timeout 15 node tests/integration/mqtt5_migration.mjs "$1" "$port" \
    >"$RUN_DIR/$label.client.log" 2>&1
  cat "$RUN_DIR/$label.client.log"
}
start seed false "$RUN_DIR/data"
stage seed
stop
cp -a "$RUN_DIR/data/." "$RUN_DIR/backup/"
start migrated true "$RUN_DIR/data"
stage migrated
stop
start restarted true "$RUN_DIR/data"
stage restarted
stop
start rollback false "$RUN_DIR/backup"
stage rollback
stop
mkdir -m 700 "$RUN_DIR/snapshot-data" "$RUN_DIR/snapshot-backup"
start snapshot-seed false "$RUN_DIR/snapshot-data" snapshot
stage seed snapshot-seed
stop
cp -a "$RUN_DIR/snapshot-data/." "$RUN_DIR/snapshot-backup/"
start snapshot-migrated true "$RUN_DIR/snapshot-data" snapshot
stage migrated snapshot-migrated
stop
start snapshot-restarted true "$RUN_DIR/snapshot-data" snapshot
stage restarted snapshot-restarted
stop
start snapshot-rollback false "$RUN_DIR/snapshot-backup" snapshot
stage rollback snapshot-rollback
stop
printf 'exit_code=0\n' >>"$RUN_DIR/metadata.txt"
echo "MQTT5_MIGRATION_PASS $RUN_DIR"
