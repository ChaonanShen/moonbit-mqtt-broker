#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
exec docker run --rm --platform linux/amd64 --network host --entrypoint bash \
  --env "MANAGEMENT_METRICS_OUTPUT=${MANAGEMENT_METRICS_OUTPUT:-}" \
  --volume "${ROOT}:/workspace" --workdir /workspace \
  moonbit-mqtt-broker-dev tests/integration/management_read.sh
