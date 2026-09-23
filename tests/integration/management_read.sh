#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"
moon build --target native
readonly BROKER="${ROOT}/_build/native/debug/build/cmd/broker/broker.exe"
WORK_DIR="$(mktemp -d)"
BROKER_PID=""
cleanup() {
  if [[ -n "${BROKER_PID}" ]] && kill -0 "${BROKER_PID}" 2>/dev/null; then
    kill -TERM "${BROKER_PID}" 2>/dev/null || true
    wait "${BROKER_PID}" 2>/dev/null || true
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT
free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}
mqtt_port="$(free_port)"
admin_port="$(free_port)"
if [[ "${mqtt_port}" = "${admin_port}" ]]; then admin_port="$(free_port)"; fi
METRICS_TOKEN='metrics1.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
READ_TOKEN='reader1.abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
node -e '
const c=require("crypto");
const entries=[
  [process.argv[1],"metrics"],
  [process.argv[2],"read"]
];
for(const [token,scope] of entries){
  const id=token.split(".")[0];
  const digest=c.createHash("sha256")
    .update("moonbit-mqtt-broker/admin/v1:"+token).digest("hex");
  process.stdout.write(id+":"+digest+":"+scope+"\n");
}
' "${METRICS_TOKEN}" "${READ_TOKEN}" >"${WORK_DIR}/tokens"
chmod 0600 "${WORK_DIR}/tokens"
"${BROKER}" --listen "127.0.0.1:${mqtt_port}" \
  --management-enabled true \
  --management-listen "127.0.0.1:${admin_port}" \
  --management-token-file "${WORK_DIR}/tokens" \
  --management-snapshot-interval-ms 100 \
  --management-snapshot-max-age-ms 500 \
  >"${WORK_DIR}/broker.log" 2>&1 &
BROKER_PID="$!"
for _ in $(seq 1 100); do
  if curl -fsS --max-time 1 "http://127.0.0.1:${admin_port}/health/live" \
      >/dev/null 2>&1; then break; fi
  if ! kill -0 "${BROKER_PID}" 2>/dev/null; then
    cat "${WORK_DIR}/broker.log" >&2
    exit 1
  fi
  sleep 0.05
done
curl -fsS --max-time 2 "http://127.0.0.1:${admin_port}/health/ready" \
  >"${WORK_DIR}/ready"
grep -qF '"status":"ready"' "${WORK_DIR}/ready"
unauthorized="$(curl -sS --max-time 2 -o "${WORK_DIR}/unauthorized" -w '%{http_code}' \
  "http://127.0.0.1:${admin_port}/metrics")"
test "${unauthorized}" = 401
grep -qF '"code":"unauthenticated"' "${WORK_DIR}/unauthorized"
forged="$(curl -sS --max-time 2 -o "${WORK_DIR}/forged" -w '%{http_code}' \
  -H 'Authorization: Bearer metrics1.ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' \
  "http://127.0.0.1:${admin_port}/metrics")"
test "${forged}" = 401
curl -fsS --max-time 2 -H "Authorization: Bearer ${METRICS_TOKEN}" \
  "http://127.0.0.1:${admin_port}/metrics" >"${WORK_DIR}/metrics"
grep -qF 'moonbit_mqtt_broker_build_info' "${WORK_DIR}/metrics"
if [[ -n "${MANAGEMENT_METRICS_OUTPUT:-}" ]]; then
  cp "${WORK_DIR}/metrics" "${MANAGEMENT_METRICS_OUTPUT}"
fi
forbidden="$(curl -sS --max-time 2 -o "${WORK_DIR}/forbidden" -w '%{http_code}' \
  -H "Authorization: Bearer ${METRICS_TOKEN}" \
  "http://127.0.0.1:${admin_port}/v1/status")"
test "${forbidden}" = 403
mosquitto_pub -h 127.0.0.1 -p "${mqtt_port}" -i management-smoke \
  -t a08/smoke -q 1 -m delivered
curl -fsS --max-time 2 -H "Authorization: Bearer ${READ_TOKEN}" \
  "http://127.0.0.1:${admin_port}/v1/status" >"${WORK_DIR}/status"
grep -qF '"api_version":"1"' "${WORK_DIR}/status"
grep -qF '"version":"0.2.0"' "${WORK_DIR}/status"
! grep -qF "${WORK_DIR}/tokens" "${WORK_DIR}/status"
! grep -qF "${METRICS_TOKEN}" "${WORK_DIR}/broker.log"
! grep -qF "${READ_TOKEN}" "${WORK_DIR}/broker.log"
kill -TERM "${BROKER_PID}"
wait "${BROKER_PID}"
BROKER_PID=""
echo 'MANAGEMENT live, ready, scopes, status, metrics and MQTT QoS1 passed'
