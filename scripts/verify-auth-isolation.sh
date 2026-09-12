#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
scripts/check-auth-executor.sh
tests/integration/auth_isolation.sh
echo 'AUTH ISOLATION verification passed'
