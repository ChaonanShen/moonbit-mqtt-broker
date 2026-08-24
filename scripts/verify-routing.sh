#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
scripts/verify-connect.sh
moon fmt --check
moon check --target native

readonly ROUTING_TEST_COUNT="$(grep -Rh '^test "' src/topic src/session src/router | wc -l | tr -d ' ')"
if [ "${ROUTING_TEST_COUNT}" -lt 24 ]; then
  echo "ROUTING acceptance suite has only ${ROUTING_TEST_COUNT} tests; expected at least 24" >&2
  exit 1
fi

for required_test in \
  'one thousand deterministic topic matches' \
  'ten thousand deterministic router transitions' \
  'router errors are atomic' \
  'router containers do not alias caller state' \
  'action ordering ignores insertion order' \
  'subscription index rejects reverse-only corruption'; do
  if ! grep -Rqs "test \"${required_test}\"" src/topic src/session src/router; then
    echo "ROUTING acceptance test is missing: ${required_test}" >&2
    exit 1
  fi
done

moon test --target native
moon build --target native
if grep -REn 'async|socket|server|framing|filesystem|clock|random' src/topic src/session src/router; then
  echo 'ROUTING pure-state packages imported a forbidden runtime concern' >&2
  exit 1
fi
echo 'ROUTING verification passed'
