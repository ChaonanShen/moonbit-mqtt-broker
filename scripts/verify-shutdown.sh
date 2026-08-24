#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

scripts/verify-compatibility.sh

for gate in \
  'SIGTERM forces the latest snapshot before broker exit' \
  'SIGINT forces the latest snapshot before broker exit' \
  'server shutdown suppresses active client Wills'; do
  rg -qF "${gate}" tests/integration/graceful_shutdown.sh || {
    echo "SHUTDOWN exact gate is missing: ${gate}" >&2
    exit 1
  }
done

tests/integration/graceful_shutdown.sh
echo 'SHUTDOWN verification passed'
