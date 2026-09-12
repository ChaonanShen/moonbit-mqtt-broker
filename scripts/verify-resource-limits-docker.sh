#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly IMAGE="${MOONBIT_MQTT_IMAGE:-moonbit-mqtt-broker-dev}"
exec docker run --rm --platform linux/amd64 --entrypoint bash \
  --volume "$REPO_ROOT:/workspace" --workdir /workspace "$IMAGE" \
  -c 'npm ci --prefix tests/integration --ignore-scripts && moon fmt --check && moon check --target native --deny-warn && moon test --target native --deny-warn && scripts/verify-resource-limits.sh'
