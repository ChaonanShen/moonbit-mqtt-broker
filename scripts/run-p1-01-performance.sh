#!/usr/bin/env bash
set -Eeuo pipefail
readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
: "${PERF_EXPECTED_SHA:?PERF_EXPECTED_SHA must be the pushed 40-character candidate SHA}"
[[ "${PERF_EXPECTED_SHA}" =~ ^[0-9a-f]{40}$ ]]
[[ "$(git rev-parse HEAD)" == "${PERF_EXPECTED_SHA}" ]]
if [[ "${PERF_QUICK:-0}" != 1 ]]; then
  [[ -z "$(git status --porcelain --untracked-files=no)" ]]
fi
mkdir -p "$ROOT/.local/manual-verification/p1-01/${PERF_EXPECTED_SHA}"
readonly RUN_DIR="$(mktemp -d "$ROOT/.local/manual-verification/p1-01/${PERF_EXPECTED_SHA}/performance-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
printf 'PERF_RUN_DIR=%s\n' "$RUN_DIR"
printf 'sha=%s\nstarted_at=%s\nquick=%s\n' "$PERF_EXPECTED_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PERF_QUICK:-0}" >"$RUN_DIR/metadata.txt"
docker image inspect moonbit-mqtt-broker-dev --format 'image={{.Id}}' >>"$RUN_DIR/metadata.txt"
docker info --format 'docker_root={{.DockerRootDir}} storage_driver={{.Driver}}' >>"$RUN_DIR/metadata.txt"
findmnt -T "$(docker info --format '{{.DockerRootDir}}')" >>"$RUN_DIR/filesystem.txt"
scripts/moon-docker.sh build --target native >"$RUN_DIR/build.log" 2>&1
readonly BROKER="$ROOT/_build/native/debug/build/cmd/broker/broker.exe"
test -x "$BROKER"
sha256sum "$BROKER" >>"$RUN_DIR/metadata.txt"
cc -std=c11 -Wall -Wextra -Werror -shared -fPIC tests/integration/durability_fsync_trace.c -ldl -o "$RUN_DIR/fsync-trace.so"
mkdir "$RUN_DIR/client"
cp tests/integration/durability_performance.mjs tests/integration/durability_recovery_probe.mjs tests/integration/package.json tests/integration/package-lock.json "$RUN_DIR/client/"
npm ci --prefix "$RUN_DIR/client" --no-audit --no-fund >"$RUN_DIR/npm.log" 2>&1
container=''
logger_pid=''
stats_pid=''
current_volume=''
finish() {
  local rc=$?
  trap - EXIT
  if [[ -n "$stats_pid" ]]; then kill "$stats_pid" 2>/dev/null || true; wait "$stats_pid" 2>/dev/null || true; fi
  if [[ -n "$logger_pid" ]]; then kill "$logger_pid" 2>/dev/null || true; wait "$logger_pid" 2>/dev/null || true; fi
  if [[ -n "$container" ]]; then
    docker logs "$container" >"$RUN_DIR/incomplete-broker.log" 2>&1 || true
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
  printf 'ended_at=%s\nexit_code=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >>"$RUN_DIR/metadata.txt"
  [[ "$(git rev-parse HEAD)" == "$PERF_EXPECTED_SHA" ]] || rc=1
  if [[ "${PERF_QUICK:-0}" != 1 && -n "$(git status --porcelain --untracked-files=no)" ]]; then rc=1; fi
  printf '%s\n' "$rc" >"$RUN_DIR/exit-code"
  printf 'PERF_EXIT=%s PERF_RUN_DIR=%s\n' "$rc" "$RUN_DIR"
  exit "$rc"
}
trap finish EXIT
readonly MODES=(off snapshot strict)
readonly SCENARIOS=(low concurrent large fanout qos2 offline)
rounds=3
if [[ "${PERF_QUICK:-0}" == 1 ]]; then rounds=1; fi
for ((round=0; round<rounds; round++)); do
  for ((index=0; index<3; index++)); do
    mode="${MODES[$(((index+round)%3))]}"
    prefix="$RUN_DIR/round-$((round+1))-$mode"
    mkdir "$prefix"
    current_volume="mqtt-perf-${PERF_EXPECTED_SHA:0:8}-$((round+1))-$mode-$$"
    docker volume create "$current_volume" >/dev/null
    printf '%s\n' "$current_volume" >"$prefix/volume.txt"
    docker run --rm --platform linux/amd64 --user 0 --volume "$current_volume:/data" \
      --entrypoint sh moonbit-mqtt-broker-dev -c 'chown 65532:65532 /data && chmod 0700 /data'
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    args=(--listen "127.0.0.1:$port" --max-connections 128 --max-pending-per-session 256 --max-pending-total 2048 --rate-limits-enabled false --per-ip-limits-enabled false)
    if [[ "$mode" != off ]]; then
      args+=(--data-dir /data --persistence-mode "$mode")
    fi
    printf "%q " "${args[@]}" >"$prefix/broker-args.txt"
    printf "\n" >>"$prefix/broker-args.txt"
    container="mqtt-perf-${PERF_EXPECTED_SHA:0:8}-$((round+1))-$mode-$$"
    touch "$prefix/fsync.tsv"
    chmod 0666 "$prefix/fsync.tsv"
    docker run -d --platform linux/amd64 --name "$container" --network host \
      --cpus 2 --memory 512m --pids-limit 64 --read-only --tmpfs /tmp:rw,mode=1777 \
      --user 65532:65532 --cap-drop ALL --security-opt no-new-privileges \
      --volume "$current_volume:/data:rw" --mount "type=bind,src=$BROKER,dst=/broker,readonly" \
      --mount "type=bind,src=$RUN_DIR/fsync-trace.so,dst=/fsync-trace.so,readonly" \
      --mount "type=bind,src=$prefix/fsync.tsv,dst=/fsync.tsv" \
      --env LD_PRELOAD=/fsync-trace.so --env MQTT_FSYNC_TRACE=/fsync.tsv \
      --entrypoint /usr/bin/stdbuf moonbit-mqtt-broker-dev -oL /broker "${args[@]}" >"$prefix/container-id.txt"
    docker logs --follow "$container" >"$prefix/broker.log" 2>&1 &
    logger_pid=$!
    for _ in $(seq 1 200); do
      if grep -q 'MQTT broker listening' "$prefix/broker.log"; then break; fi
      if [[ "$(docker inspect --format '{{.State.Running}}' "$container")" != true ]]; then
        cat "$prefix/broker.log" >&2; exit 1
      fi
      sleep 0.05
    done
    grep -q 'MQTT broker listening' "$prefix/broker.log"
    host_pid="$(docker inspect --format '{{.State.Pid}}' "$container")"
    (
      printf 'utc\tcpu_jiffies\trss_kib\n'
      while test -r "/proc/$host_pid/stat"; do
        printf '%s\t' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        awk '{printf "%d\t", $14+$15}' "/proc/$host_pid/stat" 2>/dev/null || break
        awk '/^VmRSS:/ {print $2}' "/proc/$host_pid/status" 2>/dev/null || break
        sleep 0.5
      done
    ) >"$prefix/resources.tsv" &
    stats_pid=$!
    current_scenarios=("${SCENARIOS[@]}")
    if [[ "$mode" == strict ]]; then current_scenarios+=(checkpoint); fi
    for scenario in "${current_scenarios[@]}"; do
      quick_arg=''
      if [[ "${PERF_QUICK:-0}" == 1 ]]; then quick_arg=quick; fi
      timeout -k 5 210 node "$RUN_DIR/client/durability_performance.mjs" \
        "mqtt://127.0.0.1:$port" "$scenario" "$prefix/$scenario.json" "$quick_arg" \
        >"$prefix/$scenario.log" 2>&1
      grep -qF "PERFORMANCE_SCENARIO_PASS $scenario" "$prefix/$scenario.log"
    done
    if [[ "$mode" != off ]]; then
      timeout -k 2 15 node "$RUN_DIR/client/durability_recovery_probe.mjs" seed "mqtt://127.0.0.1:$port" >"$prefix/recovery-seed.log" 2>&1
      grep -qF "PERFORMANCE_RECOVERY_SEED_PASS" "$prefix/recovery-seed.log"
    fi
    docker stats --no-stream --format '{{json .}}' "$container" >"$prefix/docker-stats.json"
    docker stop --time 15 "$container" >/dev/null
    printf '%s\n' "$(docker inspect --format '{{.State.ExitCode}}' "$container")" >"$prefix/broker.exit-code"
    [[ "$(cat "$prefix/broker.exit-code")" == 0 ]]
    docker logs "$container" >"$prefix/broker.log" 2>&1
    docker rm "$container" >/dev/null
    container=''
    kill "$logger_pid" 2>/dev/null || true; wait "$logger_pid" 2>/dev/null || true; logger_pid=''
    kill "$stats_pid" 2>/dev/null || true; wait "$stats_pid" 2>/dev/null || true; stats_pid=''
    if [[ "$mode" != off ]]; then
      container="mqtt-perf-recovery-${PERF_EXPECTED_SHA:0:8}-$((round+1))-$mode-$$"
      started_ns="$(date +%s%N)"
      docker run -d --platform linux/amd64 --name "$container" --network host \
        --cpus 2 --memory 512m --pids-limit 64 --read-only --tmpfs /tmp:rw,mode=1777 \
        --user 65532:65532 --cap-drop ALL --security-opt no-new-privileges \
        --volume "$current_volume:/data:rw" --mount "type=bind,src=$BROKER,dst=/broker,readonly" \
        --entrypoint /usr/bin/stdbuf moonbit-mqtt-broker-dev -oL /broker "${args[@]}" >"$prefix/recovery-container-id.txt"
      docker logs --follow "$container" >"$prefix/recovery-broker.log" 2>&1 &
      logger_pid=$!
      for _ in $(seq 1 200); do
        if grep -q "MQTT broker listening" "$prefix/recovery-broker.log"; then break; fi
        if [[ "$(docker inspect --format '{{.State.Running}}' "$container")" != true ]]; then
          cat "$prefix/recovery-broker.log" >&2; exit 1
        fi
        sleep 0.05
      done
      grep -q "MQTT broker listening" "$prefix/recovery-broker.log"
      elapsed_ns="$(( $(date +%s%N) - started_ns ))"
      printf '{"recovery_to_listen_ms": %.3f}\n' "$(awk "BEGIN {print $elapsed_ns/1000000}")" >"$prefix/recovery.json"
      timeout -k 2 15 node "$RUN_DIR/client/durability_recovery_probe.mjs" verify "mqtt://127.0.0.1:$port" >"$prefix/recovery-verify.log" 2>&1
      grep -qF "PERFORMANCE_RECOVERY_VERIFY_PASS" "$prefix/recovery-verify.log"
      docker stop --time 15 "$container" >/dev/null
      [[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" == 0 ]]
      docker logs "$container" >"$prefix/recovery-broker.log" 2>&1
      docker rm "$container" >/dev/null
      container=''
      kill "$logger_pid" 2>/dev/null || true; wait "$logger_pid" 2>/dev/null || true; logger_pid=''
    fi
    docker run --rm --platform linux/amd64 --user 0 --volume "$current_volume:/data:ro" \
      --entrypoint sh moonbit-mqtt-broker-dev -c 'du -sb /data; find /data -maxdepth 1 -type f -printf "%f %s\n" | sort' \
      >"$prefix/storage.txt"
    if [[ "$mode" == strict ]]; then
      if [[ "${PERF_QUICK:-0}" != 1 ]]; then
        grep -q "^checkpoint-2.snap " "$prefix/storage.txt"
      fi
      mkdir "$prefix/wal-copy"
      docker run --rm --platform linux/amd64 --user 0 --volume "$current_volume:/data:ro" \
        --volume "$prefix/wal-copy:/out:rw" --entrypoint sh moonbit-mqtt-broker-dev \
        -c 'cp /data/wal-*.log /out/ && chmod 0644 /out/*.log'
      python3 tests/integration/durability_wal_batch_stats.py "$prefix/wal-copy" >"$prefix/wal-batches.json"
      sha256sum "$prefix"/wal-copy/*.log >"$prefix/wal-sha256.txt"
    fi
    python3 - "$prefix" <<'PY_STATS'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
samples=[]
for row in (root/"fsync.tsv").read_text().splitlines():
    fields=row.split("\t")
    if len(fields)==5 and fields[2]=="0":
        samples.append({"kind":fields[1], "nanoseconds":int(fields[3]), "path":fields[4]})
def percentile(values, f):
    values=sorted(values)
    return values[min(len(values)-1, int(len(values)*f))] if values else None
durations=[s["nanoseconds"]/1e6 for s in samples]
if root.name.endswith(("-snapshot","-strict")): assert durations, "fsync trace empty"
(root/"fsync-summary.json").write_text(json.dumps({
    "calls":len(durations), "milliseconds_p50":percentile(durations,.5),
    "milliseconds_p95":percentile(durations,.95),
    "milliseconds_p99":percentile(durations,.99),
    "milliseconds_max":max(durations,default=None)}, indent=2)+"\n")
PY_STATS
    printf 'round=%s mode=%s volume=%s complete\n' "$((round+1))" "$mode" "$current_volume" >>"$RUN_DIR/metadata.txt"
    current_volume=''
  done
done
python3 - "$RUN_DIR" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
rows=[]
for item in sorted(root.glob("round-*-*")):
    round_name, round_number, mode=item.name.split("-")
    for p in sorted(item.glob("*.json")):
        if p.stem not in {"low","concurrent","large","fanout","qos2","offline","checkpoint"}: continue
        data=json.loads(p.read_text())
        assert data["status"]=="PASS"
        rows.append((round_number,mode,data["scenario"],data["messages"],data["throughput_per_second"],data["ack_ms_p50"],data["ack_ms_p95"],data["ack_ms_p99"],data["ack_ms_max"]))
with (root/"summary.tsv").open("w") as out:
    out.write("round\tmode\tscenario\tmessages\tthroughput_per_second\tack_ms_p50\tack_ms_p95\tack_ms_p99\tack_ms_max\n")
    for row in rows: out.write("\t".join(map(str,row))+"\n")
expected=6*len(list(root.glob("round-*-*")))+len(list(root.glob("round-*-strict")))
assert len(rows)==expected, (len(rows),expected)
PY
printf 'PERFORMANCE_MEASUREMENT_COMPLETE %s\n' "$RUN_DIR"
