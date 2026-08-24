#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE="${MOONBIT_MQTT_IMAGE:-moonbit-mqtt-broker-dev}"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec docker run --rm --platform linux/amd64 --entrypoint bash \
  --env "RELEASE_SOAK=${RELEASE_SOAK:-0}" \
  --env "RELEASE_SOAK_SECONDS=${RELEASE_SOAK_SECONDS:-600}" \
  --env "RELEASE_SOAK_PUBLICATIONS=${RELEASE_SOAK_PUBLICATIONS:-100000}" \
  --volume "${REPO_ROOT}:/workspace" --workdir /workspace \
  --volume /workspace/tests/integration/node_modules \
  --volume /workspace/tools/codec_oracle/node_modules \
  --volume /workspace/tools/reference_brokers/node_modules \
  "${IMAGE}" scripts/verify-observability.sh
