#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE="${MOONBIT_MQTT_IMAGE:-moonbit-mqtt-broker-dev}"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec docker run --rm \
  --platform linux/amd64 \
  --entrypoint bash \
  --volume "${REPO_ROOT}:/workspace" \
  --workdir /workspace \
  "${IMAGE}" scripts/m0-verify.sh
