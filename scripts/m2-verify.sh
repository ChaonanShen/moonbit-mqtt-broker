#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

scripts/m1-verify.sh
moon fmt --check
moon check --target native

readonly M2_TEST_COUNT="$(grep -RhE '^(async )?test "' src/server | wc -l | tr -d ' ')"
if [ "${M2_TEST_COUNT}" -lt 58 ]; then
  echo "M2 acceptance suite has only ${M2_TEST_COUNT} tests; expected at least 58" >&2
  exit 1
fi

for required_test in \
  'runtime takeover ignores stale connection events' \
  'keep alive expires at one and a half intervals' \
  'slow consumer does not block healthy clients' \
  'normal disconnect suppresses qos0 will' \
  'protocol error publishes qos0 will' \
  'suback precedes retained replay' \
  'initial broker state is injected before accept' \
  'receive buffer equality preserves a complete packet plus sticky suffix' \
  'connection supervisor reports exactly one terminal event' \
  'queue close wakes blocked driver and supervisor tasks' \
  'closed socket maps reader and writer io failures' \
  'read and write failures do not block healthy clients' \
  'bounded runtime event queue preserves packet order' \
  'retained empty payload deletes stored message over tcp' \
  'runtime remains deterministic and invariant-safe for 10000 events' \
  'twenty concurrent qos0 clients connect ping and disconnect' \
  'network qos0 subscribe publish and unsubscribe acknowledgements' \
  'network client takeover closes old generation and keeps new active' \
  'network keepalive timeout publishes will at 1.5 times deadline'; do
  if ! grep -RqsE "^(async )?test \"${required_test}\" \\{" src/server; then
    echo "M2 acceptance test is missing: ${required_test}" >&2
    exit 1
  fi
done

moon test --target native
moon build --target native
tests/integration/m2_interop.sh
echo 'M2 verification passed'
