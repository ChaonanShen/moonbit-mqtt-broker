#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
scripts/verify-observability.sh
scripts/verify-qos2.sh
scripts/verify-resource-limits.sh
tests/integration/configuration.sh
tests/integration/management_crypto.sh
tests/integration/management_read.sh --prepared
echo 'RELEASE verification passed'
