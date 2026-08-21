#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
scripts/m0-verify.sh
moon fmt --check
moon check --target native
moon test --target native
moon build --target native
if grep -REn 'async|socket|server|framing|filesystem|clock|random' src/topic src/session src/router; then
  echo 'M1 pure-state packages imported a forbidden runtime concern' >&2
  exit 1
fi
echo 'M1 verification passed'
