#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
scripts/verify-observability.sh
tests/integration/configuration.sh
echo 'RELEASE verification passed'
