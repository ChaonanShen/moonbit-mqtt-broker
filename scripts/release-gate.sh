#!/usr/bin/env bash
# Host-side final release evidence. Each cumulative pass gets fresh anonymous
# dependency volumes so one pass cannot pollute the next package audit.
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
for pass in 1 2 3; do
  scripts/verify-release-docker.sh
  echo "RELEASE_PASS=${pass}"
done
RELEASE_SOAK=1 scripts/verify-release-docker.sh
echo 'RELEASE_SOAK_PASS=1'
docker run --rm --platform linux/amd64 --entrypoint bash \
  --volume "${REPO_ROOT}:/workspace" --workdir /workspace \
  --volume /workspace/tests/integration/node_modules \
  --volume /workspace/tools/codec_oracle/node_modules \
  --volume /workspace/tools/reference_brokers/node_modules \
  moonbit-mqtt-broker-dev -lc \
  'npm ci --prefix tests/integration --ignore-scripts >/dev/null && tests/integration/shutdown_cycles.sh && scripts/check-secrets.sh && scripts/check-package.sh'
echo 'Final release gate passed'
