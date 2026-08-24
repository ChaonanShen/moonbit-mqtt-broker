#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

scripts/m6-verify.sh
tests/integration/m7_tls.sh
echo 'M7 verification passed'
