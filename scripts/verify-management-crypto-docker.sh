#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
exec docker run --rm --platform linux/amd64 --network none --entrypoint bash \
  --volume "${ROOT}:/workspace" --workdir /workspace \
  moonbit-mqtt-broker-dev tests/integration/management_crypto.sh
