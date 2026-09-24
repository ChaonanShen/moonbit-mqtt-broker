#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
moon build --target native >/dev/null
readonly BROKER="$REPO_ROOT/_build/native/debug/build/cmd/broker/broker.exe"
work="$(mktemp -d)"
broker_pid=""
cleanup() {
  rc=$?
  if [[ -n "$broker_pid" ]]; then
    kill -TERM "$broker_pid" 2>/dev/null || true
    wait "$broker_pid" 2>/dev/null || true
  fi
  mkdir -p "${RELOAD_EVIDENCE_DIR:-.local/reload-integration}"
  grep -Eh 'event=(broker_listening|wal_restored|reload_completed|reload_failed|shutdown_requested)|PolicySourceMismatch' \
    "$work"/*.log >"${RELOAD_EVIDENCE_DIR:-.local/reload-integration}/durability-events.log" 2>/dev/null || true
  printf 'case=reload_durability\nexit_code=%s\n' "$rc" \
    >"${RELOAD_EVIDENCE_DIR:-.local/reload-integration}/durability-summary.txt"
  rm -rf -- "$work"
  exit "$rc"
}
trap cleanup EXIT
port="$(node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
write_config() {
  cat >"$work/config.toml" <<EOF
[server]
listen = "127.0.0.1:$port"
[persistence]
mode = "strict"
data_dir = "$work/data"
[security]
allow_anonymous = true
$1
[reload]
enabled = true
manifest_file = "$work/manifest.toml"
EOF
}
make_manifest() {
  cat >"$work/manifest.toml" <<EOF
version = 1
[[materials]]
role = "config"
path = "$work/config.toml"
sha256 = "$(sha256sum "$work/config.toml" | cut -d' ' -f1)"
EOF
  if [[ -f "$work/acl.txt" ]]; then
    cat >>"$work/manifest.toml" <<EOF
[[materials]]
role = "acl"
path = "$work/acl.txt"
sha256 = "$(sha256sum "$work/acl.txt" | cut -d' ' -f1)"
EOF
  fi
  chmod 600 "$work/manifest.toml"
}
start_broker() {
  local log="$1"
  : >"$log"
  setsid stdbuf -oL -eL "$BROKER" --config "$work/config.toml" >"$log" 2>&1 &
  broker_pid=$!
  for _ in $(seq 1 800); do
    if grep -q broker_listening "$log"; then return; fi
    if ! kill -0 "$broker_pid" 2>/dev/null; then cat "$log" >&2; exit 1; fi
    sleep 0.025
  done
  cat "$log" >&2
  exit 1
}
stop_broker() {
  kill -TERM "$broker_pid"
  wait "$broker_pid"
  broker_pid=""
}
write_config ""
make_manifest
start_broker "$work/initial.log"
printf 'anonymous\ntopic read safe/#\n' >"$work/acl.txt"
write_config "acl_file = \"$work/acl.txt\""
make_manifest
kill -HUP "$broker_pid"
for _ in $(seq 1 800); do
  if grep -q 'reload_completed.*config_epoch=1' "$work/initial.log"; then break; fi
  if ! kill -0 "$broker_pid" 2>/dev/null; then cat "$work/initial.log" >&2; exit 1; fi
  sleep 0.025
done
grep -q 'reload_completed.*config_epoch=1' "$work/initial.log"
stop_broker
start_broker "$work/recovered.log"
grep -q wal_restored "$work/recovered.log"
stop_broker
printf 'anonymous\ntopic read other/#\n' >"$work/acl.txt"
make_manifest
if timeout 10 "$BROKER" --config "$work/config.toml" >"$work/mismatch.log" 2>&1; then
  echo "strict source mismatch unexpectedly started" >&2
  exit 1
fi
grep -q PolicySourceMismatch "$work/mismatch.log"
! grep -q broker_listening "$work/mismatch.log"
printf 'anonymous\ntopic read safe/#\n' >"$work/acl.txt"
make_manifest
start_broker "$work/rollback.log"
grep -q wal_restored "$work/rollback.log"
stop_broker
echo 'reload strict activation, recovery and mismatch passed'

