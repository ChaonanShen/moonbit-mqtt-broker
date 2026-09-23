#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
readonly IMAGE="$(cat tests/prometheus/image.txt)"
if [[ ! "${IMAGE}" =~ ^prom/prometheus@sha256:[0-9a-f]{64}$ ]]; then
  echo 'Prometheus image must be pinned by SHA256 digest' >&2
  exit 1
fi
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  docker pull --platform linux/amd64 "${IMAGE}"
fi
docker run --rm --platform linux/amd64 --network none \
  --entrypoint /bin/promtool "${IMAGE}" --version
docker run --rm -i --platform linux/amd64 --network none \
  --entrypoint /bin/promtool "${IMAGE}" check metrics \
  < tests/prometheus/fixture.prom
echo 'PROMETHEUS fixed fixture parsed successfully'

# Optional live mode shares the existing Broker network namespace. The Broker
# remains the exact runtime candidate under test; this script never starts one.
if [[ -z "${PROMETHEUS_BROKER_CONTAINER:-}" ]]; then
  exit 0
fi
: "${PROMETHEUS_TOKEN_FILE:?set host path to a client bearer token file}"
[[ -f "${PROMETHEUS_TOKEN_FILE}" ]]
readonly PROM_DIR="$(mktemp -d)"
readonly PROM_CONTAINER="moonbit-mqtt-prometheus-$$"
cleanup() {
  docker rm --force "${PROM_CONTAINER}" >/dev/null 2>&1 || true
  rm -rf "${PROM_DIR}"
}
trap cleanup EXIT
cp "${PROMETHEUS_TOKEN_FILE}" "${PROM_DIR}/good-token"
printf '%s\n' 'invalid-client-token' >"${PROM_DIR}/bad-token"
chmod 0444 "${PROM_DIR}/good-token" "${PROM_DIR}/bad-token"
cat >"${PROM_DIR}/prometheus.yml" <<'YAML'
global:
  scrape_interval: 1s
  scrape_timeout: 750ms
scrape_configs:
  - job_name: management-good
    metrics_path: /metrics
    bearer_token_file: /etc/prometheus/good-token
    static_configs:
      - targets: ['127.0.0.1:9091']
  - job_name: management-bad
    metrics_path: /metrics
    bearer_token_file: /etc/prometheus/bad-token
    static_configs:
      - targets: ['127.0.0.1:9091']
YAML
chmod 0444 "${PROM_DIR}/prometheus.yml"
docker run --detach --platform linux/amd64 \
  --name "${PROM_CONTAINER}" --network "container:${PROMETHEUS_BROKER_CONTAINER}" \
  --volume "${PROM_DIR}/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  --volume "${PROM_DIR}/good-token:/etc/prometheus/good-token:ro" \
  --volume "${PROM_DIR}/bad-token:/etc/prometheus/bad-token:ro" \
  --tmpfs /prometheus:rw,mode=1777 \
  --entrypoint /bin/prometheus "${IMAGE}" \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --web.listen-address=127.0.0.1:9092 \
  >/dev/null
query() {
  docker run --rm --platform linux/amd64 \
    --network "container:${PROMETHEUS_BROKER_CONTAINER}" \
    --entrypoint curl moonbit-mqtt-broker-dev \
    --silent --show-error --fail --max-time 2 --get \
    --data-urlencode "query=$1" \
    'http://127.0.0.1:9092/api/v1/query'
}
live_ok=0
for _ in $(seq 1 30); do
  if query 'up{job="management-good"}' >"${PROM_DIR}/good.json" 2>/dev/null &&
     query 'up{job="management-bad"}' >"${PROM_DIR}/bad.json" 2>/dev/null &&
     python3 - "${PROM_DIR}/good.json" "${PROM_DIR}/bad.json" <<'PY'
import json, sys
good, bad = [json.load(open(path)) for path in sys.argv[1:]]
def values(payload):
    assert payload['status'] == 'success'
    return [float(item['value'][1]) for item in payload['data']['result']]
assert values(good) == [1.0], good
assert values(bad) == [0.0], bad
PY
  then
    live_ok=1
    break
  fi
  sleep 1
done
if [[ "${live_ok}" -ne 1 ]]; then
  docker logs "${PROM_CONTAINER}" >&2
  echo 'Prometheus live scrape did not reach up=1/good and up=0/bad' >&2
  exit 1
fi
query 'moonbit_mqtt_broker_build_info{job="management-good",version="0.2.0",target="native"}' \
  >"${PROM_DIR}/sample.json"
python3 - "${PROM_DIR}/sample.json" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
assert payload['status'] == 'success'
values = [float(item['value'][1]) for item in payload['data']['result']]
assert values == [1.0], payload
PY
echo 'PROMETHEUS live scrape passed: authorized up=1, denied up=0, build_info=1'
