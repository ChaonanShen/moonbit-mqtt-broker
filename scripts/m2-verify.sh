#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

scripts/m1-verify.sh
moon fmt --check
moon check --target native

for required_test in \
  'runtime remains deterministic and invariant-safe for 10000 events' \
  'twenty concurrent qos0 clients connect ping and disconnect' \
  'network qos0 subscribe publish and unsubscribe acknowledgements' \
  'network client takeover closes old generation and keeps new active' \
  'network keepalive timeout publishes will at 1.5 times deadline'; do
  if ! grep -Rqs "test \"${required_test}\"" src/server; then
    echo "M2 acceptance test is missing: ${required_test}" >&2
    exit 1
  fi
done

moon test --target native
moon build --target native
tests/integration/m2_interop.sh
echo 'M2 verification passed'
