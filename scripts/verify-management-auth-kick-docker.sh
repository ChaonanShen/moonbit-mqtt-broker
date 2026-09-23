#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly ROOT
cd "$ROOT"
exec docker run --rm --platform linux/amd64 --network host --entrypoint bash \
  --volume "$ROOT:/workspace" --workdir /workspace \
  moonbit-mqtt-broker-dev tests/integration/management_auth_kick.sh
