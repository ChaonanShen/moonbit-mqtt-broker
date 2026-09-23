#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly ROOT
cd "$ROOT"
exec docker run --rm --platform linux/amd64 --network host --entrypoint bash \
  --env MANAGEMENT_ADMIN_OUTPUT --env MANAGEMENT_ADMIN_STRESS \
  --volume "$ROOT:/workspace" --workdir /workspace \
  moonbit-mqtt-broker-dev tests/integration/management_admin.sh
