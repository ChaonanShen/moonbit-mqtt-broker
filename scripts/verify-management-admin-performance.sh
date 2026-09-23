#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
readonly ROOT="$PWD"
# Prepare the pinned client dependency set and Native binary independently.
docker run --rm --platform linux/amd64 --entrypoint bash \
  --volume "${ROOT}:/workspace" --workdir /workspace \
  moonbit-mqtt-broker-dev -c 'moon build --target native && npm ci --prefix tests/integration --ignore-scripts >/dev/null'
readonly WARM="${PERF_WARM_SECONDS:-10}"
readonly MEASURE="${PERF_MEASURE_SECONDS:-60}"
readonly REPEATS="${PERF_REPEATS:-3}"
readonly OUTPUT="${PERF_OUTPUT:-.local/p1-03b-execution/performance-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "${OUTPUT}"
readonly ABS_OUTPUT="$(realpath "${OUTPUT}")"
readonly WORK="$(mktemp -d)"
container=""
cleanup() {
  if [[ -n "${container}" ]]; then
    docker logs "${container}" >"${ABS_OUTPUT}/${container}-failure.log" 2>&1 || true
    docker rm --force "${container}" >/dev/null 2>&1 || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT
port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
readonly MQTT_PORT="$(port)"
readonly ADMIN_PORT="$(port)"
python3 - "${WORK}" <<'PY'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1])
token='perfadmin.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
digest=hashlib.sha256(('moonbit-mqtt-broker/admin/v1:'+token).encode()).hexdigest()
(p/'tokens').write_text('perfadmin:'+digest+':metrics,read,operator\n')
(p/'tokens').chmod(0o600)
PY
readonly TOKEN='perfadmin.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
run_one() {
  local mode="$1" round="$2"
  container="moonbit-mqtt-perf-${mode}-${round}-$$"
  local args=(--listen "127.0.0.1:$MQTT_PORT"
    --management-enabled true --management-listen "127.0.0.1:$ADMIN_PORT"
    --management-token-file /secrets/tokens --management-max-connections 32
    --management-max-bytes-total 33554432)
  if [[ "$mode" != base ]]; then
    args+=(--management-details-enabled true --management-operations-enabled true
      --management-max-cursor-records 1024)
  fi
  docker run --detach --platform linux/amd64 --network host \
    --memory 256m --cpus 2 --pids-limit 64 \
    --user "$(id -u):$(id -g)" --name "${container}" \
    --volume "${ROOT}:/workspace:ro" --volume "${WORK}:/secrets:ro" \
    --entrypoint /workspace/_build/native/debug/build/cmd/broker/broker.exe \
    moonbit-mqtt-broker-dev "${args[@]}" >/dev/null
  for _ in $(seq 1 50); do
    if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(1); s.connect(("127.0.0.1",int(sys.argv[1]))); s.close()' "${MQTT_PORT}" >/dev/null 2>&1; then break; fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "${container}")" != true ]]; then
      docker logs "${container}" >&2; exit 1
    fi
    sleep 0.1
  done
  local pid fd_before fd_after
  pid="$(docker inspect -f '{{.State.Pid}}' "${container}")"
  fd_before="$(find "/proc/${pid}/fd" -maxdepth 1 -type l | wc -l)"
  docker run --rm --platform linux/amd64 --network host \
    --volume "${ROOT}:/workspace:ro" --workdir /workspace \
    --env "PERF_TOKEN=${TOKEN}" --entrypoint node moonbit-mqtt-broker-dev \
    tests/integration/management_admin_performance.mjs \
    "${mode}" "${MQTT_PORT}" "${ADMIN_PORT}" "${WARM}" "${MEASURE}" \
    >"${ABS_OUTPUT}/${mode}-${round}.json"
  sleep 0.2
  fd_after="$(find "/proc/${pid}/fd" -maxdepth 1 -type l | wc -l)"
  printf '%s %s %s %s\n' "${mode}" "${round}" "${fd_before}" "${fd_after}" \
    >>"${ABS_OUTPUT}/fd.tsv"
  docker logs "${container}" >"${ABS_OUTPUT}/${mode}-${round}.log" 2>&1
  docker stop --time 10 "${container}" >/dev/null
  [[ "$(docker inspect -f '{{.State.ExitCode}}' "${container}")" = 0 ]]
  docker rm "${container}" >/dev/null
  container=""
  cat "${ABS_OUTPUT}/${mode}-${round}.json"
}
for round in $(seq 1 "${REPEATS}"); do
  run_one base "${round}"
  run_one managed "${round}"
done
run_one overload 1
python3 - "${ABS_OUTPUT}" "${REPEATS}" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); count=int(sys.argv[2])
rows=[]
for index in range(1,count+1):
    base=json.loads((root/f'base-{index}.json').read_text())
    managed=json.loads((root/f'managed-{index}.json').read_text())
    ratio=managed['throughput_per_sec']/base['throughput_per_sec']
    ping_limit=max(2*base['ping_p99_ms'],base['ping_p99_ms']+20)
    ack_limit=max(2*base['puback_p99_ms'],base['puback_p99_ms']+20)
    rows.append(dict(round=index,throughput_ratio=ratio,
        ping_p99_ms=managed['ping_p99_ms'],ping_limit_ms=ping_limit,
        puback_p99_ms=managed['puback_p99_ms'],puback_limit_ms=ack_limit))
    assert ratio>=0.9, rows[-1]
    assert managed['ping_p99_ms']<=ping_limit, rows[-1]
    assert managed['puback_p99_ms']<=ack_limit, rows[-1]
for line in (root/'fd.tsv').read_text().splitlines():
    mode,round,before,after=line.split()
    assert int(after)<=int(before)+2,line
overload=json.loads((root/'overload-1.json').read_text())
assert all(overload['ping_by_5s']),overload
summary=dict(result='PASS',warmup_s=int(rows and json.loads((root/'base-1.json').read_text())['warmup_ms']/1000),
             measure_s=int(json.loads((root/'base-1.json').read_text())['measure_ms']/1000),
             rounds=rows,overload_ping_by_5s=overload['ping_by_5s'])
(root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
PY
echo "PERFORMANCE_RESULTS=${ABS_OUTPUT}"
