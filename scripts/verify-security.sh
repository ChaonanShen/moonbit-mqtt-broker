#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

scripts/verify-tls.sh
tests/integration/security.sh
scripts/verify-auth-isolation.sh
echo 'SECURITY verification passed'
