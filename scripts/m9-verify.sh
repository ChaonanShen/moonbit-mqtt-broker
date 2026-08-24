#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

scripts/m8-verify.sh
tests/integration/m9_session_expiry.sh
echo 'M9 verification passed'
