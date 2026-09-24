#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
RELOAD_EVIDENCE_DIR="${RELOAD_EVIDENCE_DIR:-$ROOT/.local/reload-integration/shutdown-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
moon build --target native >/dev/null
readonly BROKER="$ROOT/_build/native/debug/build/cmd/broker/broker.exe"
work="$(mktemp -d)"
broker_pid=""
watchdog_pid=""
recovered=""
cleanup() {
  rc=$?
  if [[ -n "$watchdog_pid" ]]; then kill "$watchdog_pid" 2>/dev/null || true; fi
  if [[ -n "$broker_pid" ]]; then
    kill -TERM "$broker_pid" 2>/dev/null || true
    wait "$broker_pid" 2>/dev/null || true
  fi
  mkdir -p "$RELOAD_EVIDENCE_DIR"
  grep -Eh 'event=(broker_listening|wal_restored|reload_completed|reload_failed|shutdown_requested|wal_fenced)|PolicySourceMismatch' \
    "$work"/*.log >"$RELOAD_EVIDENCE_DIR/shutdown-events.log" 2>/dev/null || true
  printf 'case=reload_shutdown\nexit_code=%s\nrecovered_bundle=%s\n' "$rc" "$recovered" \
    >"$RELOAD_EVIDENCE_DIR/shutdown-summary.txt"
  if [[ "$rc" -ne 0 ]]; then cp "$work"/*.log "$RELOAD_EVIDENCE_DIR/" 2>/dev/null || true; fi
  rm -rf -- "$work"
  exit "$rc"
}
trap cleanup EXIT
mkdir -m 700 "$work/data"
cc -std=c11 -Wall -Wextra -Werror -shared -fPIC \
  tests/integration/durability_fsync_hold.c -ldl -o "$work/hold.so"
port="$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
write_bundle() {
  local acl="$1"
  cat >"$work/config.toml" <<EOF
[server]
listen = "127.0.0.1:$port"
[persistence]
mode = "strict"
data_dir = "$work/data"
[security]
allow_anonymous = true
EOF
  if [[ "$acl" = yes ]]; then
    printf 'acl_file = "%s/acl.txt"\n' "$work" >>"$work/config.toml"
  fi
  cat >>"$work/config.toml" <<EOF
[reload]
enabled = true
manifest_file = "$work/manifest.toml"
EOF
  cat >"$work/manifest.toml" <<EOF
version = 1
[[materials]]
role = "config"
path = "$work/config.toml"
sha256 = "$(sha256sum "$work/config.toml" | cut -d' ' -f1)"
EOF
  if [[ "$acl" = yes ]]; then
    cat >>"$work/manifest.toml" <<EOF
[[materials]]
role = "acl"
path = "$work/acl.txt"
sha256 = "$(sha256sum "$work/acl.txt" | cut -d' ' -f1)"
EOF
  fi
  chmod 600 "$work/manifest.toml"
}
wait_listening() {
  local log="$1"
  for _ in $(seq 1 400); do
    if grep -q broker_listening "$log"; then return; fi
    if ! kill -0 "$broker_pid" 2>/dev/null; then cat "$log" >&2; return 1; fi
    sleep 0.025
  done
  cat "$log" >&2
  return 1
}
write_bundle no
cp "$work/config.toml" "$work/old-config"
cp "$work/manifest.toml" "$work/old-manifest"
arm="$work/arm"
marker="$work/held"
release="$work/release"
setsid stdbuf -oL env \
  "LD_PRELOAD=$work/hold.so:/usr/libexec/coreutils/libstdbuf.so" \
  "MQTT_WAL_FSYNC_ARM=$arm" \
  "MQTT_WAL_FSYNC_MARKER=$marker" \
  "MQTT_WAL_FSYNC_RELEASE=$release" \
  "$BROKER" --config "$work/config.toml" >"$work/held.log" 2>&1 &
broker_pid=$!
wait_listening "$work/held.log"
printf 'anonymous\ntopic read safe/#\n' >"$work/acl.txt"
write_bundle yes
touch "$arm"
kill -HUP "$broker_pid"
for _ in $(seq 1 600); do
  if [[ -s "$marker" ]]; then break; fi
  if ! kill -0 "$broker_pid" 2>/dev/null; then cat "$work/held.log" >&2; exit 1; fi
  sleep 0.025
done
[[ -s "$marker" ]]
! grep -q reload_completed "$work/held.log"
kill -TERM "$broker_pid"
touch "$release"
(sleep 15; kill -KILL "$broker_pid" 2>/dev/null || true) &
watchdog_pid=$!
stop_status=0
wait "$broker_pid" 2>/dev/null || stop_status=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
broker_pid=""
[[ "$stop_status" -eq 0 ]]
# The committed policy may win the shutdown race; the matching bundle must
# be the only one admitted on recovery.
setsid stdbuf -oL -eL "$BROKER" --config "$work/config.toml" \
  >"$work/new-recovery.log" 2>&1 &
broker_pid=$!
recovered=new
if ! wait_listening "$work/new-recovery.log"; then
  wait "$broker_pid" 2>/dev/null || true
  broker_pid=""
  grep -q PolicySourceMismatch "$work/new-recovery.log"
  cp "$work/old-config" "$work/config.toml"
  cp "$work/old-manifest" "$work/manifest.toml"
  setsid stdbuf -oL -eL "$BROKER" --config "$work/config.toml" \
    >"$work/old-recovery.log" 2>&1 &
  broker_pid=$!
  wait_listening "$work/old-recovery.log"
  recovered=old
fi
kill -TERM "$broker_pid"
wait "$broker_pid"
broker_pid=""
echo "reload shutdown at held WAL commit recovered with $recovered bundle"
