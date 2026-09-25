#!/usr/bin/env bash
set -Eeuo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
: "${PERF_EXPECTED_SHA:?set PERF_EXPECTED_SHA to the fixed 40-character candidate}"
[[ "$PERF_EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$(git rev-parse HEAD)" == "$PERF_EXPECTED_SHA" ]]
if [[ "${PERF_QUICK:-0}" != 1 ]]; then
  [[ -z "$(git status --porcelain --untracked-files=no)" ]]
fi
WARM="${PERF_WARM_SECONDS:-10}"
MEASURE="${PERF_MEASURE_SECONDS:-30}"
REPEATS="${PERF_REPEATS:-3}"
if [[ "${PERF_QUICK:-0}" == 1 ]]; then
  WARM=0
  MEASURE=2
  REPEATS=1
fi
[[ "$WARM" =~ ^[0-9]+$ && "$MEASURE" =~ ^[0-9]+$ && "$REPEATS" =~ ^[0-9]+$ ]]
readonly BASE="$ROOT/.local/manual-verification/p1-04/$PERF_EXPECTED_SHA"
mkdir -p "$BASE"
readonly RUN_DIR="$(mktemp -d "$BASE/performance-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
printf 'PERF_RUN_DIR=%s\n' "$RUN_DIR"
exec > >(tee "$RUN_DIR/run.log") 2>&1
printf 'sha=%s\nstarted_at=%s\nwarm_s=%s\nmeasure_s=%s\nrepeats=%s\nquick=%s\n' \
  "$PERF_EXPECTED_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WARM" "$MEASURE" "$REPEATS" "${PERF_QUICK:-0}" >"$RUN_DIR/metadata.txt"
docker image inspect moonbit-mqtt-broker-dev --format 'image={{.Id}}' >>"$RUN_DIR/metadata.txt"
printf 'PERF_EXPECTED_SHA=%q PERF_QUICK=%q PERF_WARM_SECONDS=%q PERF_MEASURE_SECONDS=%q PERF_REPEATS=%q scripts/run-p1-04-performance.sh\n' \
  "$PERF_EXPECTED_SHA" "${PERF_QUICK:-0}" "$WARM" "$MEASURE" "$REPEATS" >"$RUN_DIR/command.txt"
uname -a >"$RUN_DIR/host.txt"
lscpu >>"$RUN_DIR/host.txt"
free -m >>"$RUN_DIR/host.txt"
docker info --format 'docker_root={{.DockerRootDir}} storage_driver={{.Driver}}' >>"$RUN_DIR/host.txt"
findmnt -T "$(docker info --format '{{.DockerRootDir}}')" >>"$RUN_DIR/host.txt"
current_container=""
current_fixture=""
finish() {
  rc=$?
  trap - EXIT
  if [[ -n "$current_container" ]]; then
    docker logs "$current_container" >"$RUN_DIR/failed-broker.log" 2>&1 || true
    docker rm -f "$current_container" >/dev/null 2>&1 || true
  fi
  if [[ -n "$current_fixture" ]]; then rm -rf -- "$current_fixture"; fi
  [[ "$(git rev-parse HEAD)" == "$PERF_EXPECTED_SHA" ]] || rc=97
  printf 'completed_at=%s\nexit_code=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >>"$RUN_DIR/metadata.txt"
  printf '%s\n' "$rc" >"$RUN_DIR/exit-code.txt"
  exit "$rc"
}
trap finish EXIT
scripts/moon-docker.sh build --target native >"$RUN_DIR/build.log" 2>&1
readonly BROKER="$ROOT/_build/native/debug/build/cmd/broker/broker.exe"
sha256sum "$BROKER" >>"$RUN_DIR/metadata.txt"
if [[ ! -d tests/integration/node_modules/mqtt ]]; then
  docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" \
    --entrypoint npm --volume "$ROOT:/workspace" --workdir /workspace \
    moonbit-mqtt-broker-dev ci --prefix tests/integration --ignore-scripts \
    >"$RUN_DIR/npm.log" 2>&1
fi
material="$(mktemp -d "$RUN_DIR/material-XXXXXX")"
current_fixture="$material"
docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" \
  --entrypoint openssl --volume "$material:/fixture" moonbit-mqtt-broker-dev \
  req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 -subj /CN=localhost \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout /fixture/key.pem -out /fixture/cert.pem >/dev/null 2>&1
docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" \
  --entrypoint openssl --volume "$material:/fixture" moonbit-mqtt-broker-dev \
  req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 -subj /CN=localhost \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout /fixture/key.next -out /fixture/cert.next >/dev/null 2>&1
chmod 600 "$material"/key.*
hash_load="$(printf load-secret | docker run --rm -i --platform linux/amd64 --entrypoint argon2 moonbit-mqtt-broker-dev reload-salt-0001 -id -e -t 2 -m 12 -p 1)"
hash_rotate="$(printf rotate-secret | docker run --rm -i --platform linux/amd64 --entrypoint argon2 moonbit-mqtt-broker-dev reload-salt-0001 -id -e -t 2 -m 12 -p 1)"
hash_next="$(printf next-secret | docker run --rm -i --platform linux/amd64 --entrypoint argon2 moonbit-mqtt-broker-dev reload-salt-0001 -id -e -t 2 -m 12 -p 1)"
token='reloadperf.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
digest="$(printf 'moonbit-mqtt-broker/admin/v1:%s' "$token" | sha256sum | cut -d' ' -f1)"
free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
make_manifest() {
  local fixture="$1" role path
  printf 'version = 1\n' >"$fixture/manifest.toml"
  for role in config passwords mqtt_cert mqtt_key; do
    case "$role" in
      config) path=config.toml ;;
      passwords) path=passwords ;;
      mqtt_cert) path=cert.pem ;;
      mqtt_key) path=key.pem ;;
    esac
    printf '[[materials]]\nrole = "%s"\n' "$role" >>"$fixture/manifest.toml"
    if [[ "$role" == mqtt_* ]]; then
      printf 'listener_id = "mqtt"\n' >>"$fixture/manifest.toml"
    fi
    printf 'path = "/fixture/%s"\nsha256 = "%s"\n' \
      "$path" "$(sha256sum "$fixture/$path" | cut -d' ' -f1)" \
      >>"$fixture/manifest.toml"
  done
  chmod 600 "$fixture/manifest.toml"
}
for round in $(seq 1 "$REPEATS"); do
  for mode in off snapshot strict; do
    for scenario in baseline idle active; do
      prefix="$RUN_DIR/round-$round-$mode-$scenario"
      mkdir "$prefix"
      fixture="$(mktemp -d "$RUN_DIR/fixture-XXXXXX")"
      current_fixture="$fixture"
      chmod 700 "$fixture"
      cp "$material"/cert.pem "$fixture/cert.pem"
      cp "$material"/key.pem "$fixture/key.pem"
      cp "$material"/cert.next "$fixture/cert.next"
      cp "$material"/key.next "$fixture/key.next"
      chmod 600 "$fixture"/key.*
      printf 'load:%s\nrotate:%s\n' "$hash_load" "$hash_rotate" >"$fixture/passwords"
      printf 'load:%s\nrotate:%s\n' "$hash_load" "$hash_next" >"$fixture/passwords.next"
      chmod 600 "$fixture"/passwords*
      mkdir "$fixture/material" "$fixture/data"
      chmod 700 "$fixture/material" "$fixture/data"
      printf 'reloadperf:%s:config_admin\n' "$digest" >"$fixture/tokens"
      chmod 600 "$fixture/tokens"
      port="$(free_port)"
      admin_port="$(free_port)"
      while [[ "$admin_port" == "$port" ]]; do admin_port="$(free_port)"; done
      cat >"$fixture/config.toml" <<EOF
[server]
listen = "127.0.0.1:$port"
[persistence]
mode = "$mode"
EOF
      if [[ "$mode" != off ]]; then
        printf 'data_dir = "/fixture/data"\n' >>"$fixture/config.toml"
      fi
      cat >>"$fixture/config.toml" <<EOF
[tls]
cert = "/fixture/cert.pem"
key = "/fixture/key.pem"
[security]
allow_anonymous = false
password_file = "/fixture/passwords"
[management]
enabled = true
listen = "127.0.0.1:$admin_port"
token_file = "/fixture/tokens"
details_enabled = false
operations_enabled = false
[limits]
enabled = false
per_ip_enabled = false
[reload]
enabled = $([[ "$scenario" = baseline ]] && echo false || echo true)
EOF
      if [[ "$scenario" != baseline ]]; then
        cat >>"$fixture/config.toml" <<EOF
manifest_file = "/fixture/manifest.toml"
material_runtime_dir = "/fixture/material"
EOF
        make_manifest "$fixture"
      fi
      current_container="reload-perf-$round-$mode-$scenario-$$"
      docker run -d --platform linux/amd64 --name "$current_container" \
        --network host --cpus 2 --memory 512m --pids-limit 64 \
        --read-only --tmpfs /tmp:rw,mode=1777 --user "$(id -u):$(id -g)" \
        --cap-drop ALL --security-opt no-new-privileges \
        --volume "$fixture:/fixture:rw" --volume "$BROKER:/broker:ro" \
        --entrypoint /usr/bin/stdbuf moonbit-mqtt-broker-dev \
        -oL /broker --config /fixture/config.toml >/dev/null
      for _ in $(seq 1 200); do
        if docker logs "$current_container" 2>&1 | grep -q broker_listening; then break; fi
        if [[ "$(docker inspect --format '{{.State.Running}}' "$current_container")" != true ]]; then
          docker logs "$current_container" >&2; exit 1
        fi
        sleep 0.05
      done
      docker logs "$current_container" 2>&1 | grep -q broker_listening
      docker run --rm --platform linux/amd64 --network host \
        --user "$(id -u):$(id -g)" --entrypoint node \
        --volume "$ROOT:/workspace:ro" --volume "$fixture:/fixture:rw" \
        --workdir /workspace moonbit-mqtt-broker-dev \
        tests/integration/reload_performance.mjs "$port" "$admin_port" "$mode" "$scenario" \
        /fixture "$WARM" "$MEASURE" >"$prefix/result.json"
      docker stats --no-stream --format '{{json .}}' "$current_container" >"$prefix/docker-stats.json"
      docker stop --time 15 "$current_container" >/dev/null
      [[ "$(docker inspect --format '{{.State.ExitCode}}' "$current_container")" == 0 ]]
      docker logs "$current_container" >"$prefix/broker.log" 2>&1
      docker rm "$current_container" >/dev/null
      current_container=""
      [[ -z "$(find "$fixture/material" -mindepth 1 -print -quit)" ]]
      rm -rf -- "$fixture"
      current_fixture=""
      printf 'round=%s mode=%s scenario=%s complete\n' "$round" "$mode" "$scenario" >>"$RUN_DIR/metadata.txt"
    done
  done
done
python3 - "$RUN_DIR" "$REPEATS" <<'PY_SUMMARY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1]); repeats=int(sys.argv[2]); rows=[]
for round in range(1,repeats+1):
    for mode in ('off','snapshot','strict'):
        values={scenario:json.loads((root/f'round-{round}-{mode}-{scenario}'/'result.json').read_text())
                for scenario in ('baseline','idle','active')}
        base, idle, active=(values[key] for key in ('baseline','idle','active'))
        ratio=idle['throughput_per_sec']/base['throughput_per_sec']
        idle_limit=max(2*base['ack_p99_ms'],base['ack_p99_ms']+20)
        active_limit=max(3*idle['ack_p99_ms'],idle['ack_p99_ms']+50)
        row=dict(round=round,mode=mode,idle_throughput_ratio=ratio,
                 idle_ack_p99_ms=idle['ack_p99_ms'],idle_limit_ms=idle_limit,
                 active_ack_p99_ms=active['ack_p99_ms'],active_limit_ms=active_limit,
                 reload_ms=active['reload_ms'])
        rows.append(row)
        if ratio<.9 or idle['ack_p99_ms']>idle_limit or active['ack_p99_ms']>active_limit:
            raise SystemExit(f'performance threshold failed: {row}')
        if active['reload_ms'] is None or active['reload_ms']>10000:
            raise SystemExit(f'reload progress threshold failed: {row}')
(root/'summary.json').write_text(json.dumps({'result':'PASS','rounds':rows},indent=2)+'\n')
print('PERFORMANCE_PASS',root/'summary.json')
PY_SUMMARY
rm -rf -- "$material"
current_fixture=""
echo "PERFORMANCE_RESULTS=$RUN_DIR"
