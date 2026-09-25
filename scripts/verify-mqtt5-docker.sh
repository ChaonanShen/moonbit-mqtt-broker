#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly IMAGE="${MOONBIT_MQTT_IMAGE:-moonbit-mqtt-broker-dev}"
exec docker run --rm --platform linux/amd64 --entrypoint bash   --volume "$REPO_ROOT:/workspace" --workdir /workspace   "$IMAGE" -c 'npm ci --prefix tests/integration --ignore-scripts && scripts/verify-mqtt5.sh'
