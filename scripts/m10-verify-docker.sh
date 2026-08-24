#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE="${MOONBIT_MQTT_IMAGE:-moonbit-mqtt-broker-dev}"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec docker run --rm --platform linux/amd64 --entrypoint bash \
  --env "M5_SOAK=${M5_SOAK:-0}" \
  --env "M5_SOAK_SECONDS=${M5_SOAK_SECONDS:-600}" \
  --env "M5_SOAK_PUBLICATIONS=${M5_SOAK_PUBLICATIONS:-100000}" \
  --volume "${REPO_ROOT}:/workspace" --workdir /workspace \
  --volume /workspace/tests/integration/node_modules \
  --volume /workspace/tools/codec_oracle/node_modules \
  --volume /workspace/tools/reference_brokers/node_modules \
  "${IMAGE}" scripts/m10-verify.sh
