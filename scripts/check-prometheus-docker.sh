#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
readonly IMAGE="$(cat tests/prometheus/image.txt)"
if [[ ! "${IMAGE}" =~ ^prom/prometheus@sha256:[0-9a-f]{64}$ ]]; then
  echo 'Prometheus image must be pinned by SHA256 digest' >&2
  exit 1
fi
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  docker pull --platform linux/amd64 "${IMAGE}"
fi
docker run --rm --platform linux/amd64 --network none \
  --entrypoint /bin/promtool "${IMAGE}" --version
docker run --rm -i --platform linux/amd64 --network none \
  --entrypoint /bin/promtool "${IMAGE}" check metrics \
  < tests/prometheus/fixture.prom
echo 'PROMETHEUS fixed fixture parsed successfully'
