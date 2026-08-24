#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

scripts/verify-security.sh
tests/integration/session_expiry.sh
echo 'SESSION_EXPIRY verification passed'
