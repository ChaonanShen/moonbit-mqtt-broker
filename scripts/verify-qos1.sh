#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

scripts/verify-network.sh
moon fmt --check
moon check --target native

readonly QOS1_TEST_COUNT="$(grep -RhE '^(async )?test "' src | wc -l | tr -d ' ')"
if [[ "${QOS1_TEST_COUNT}" -lt 130 ]]; then
  echo "QOS1 acceptance suite has only ${QOS1_TEST_COUNT} tests; expected at least 130" >&2
  exit 1
fi

for required_test in \
  'packet id allocator wraps without reusing inflight ids' \
  'inbound qos1 publish is acknowledged with the same packet id' \
  'outbound qos1 remains inflight until puback at runtime' \
  'persistent reconnect sets session present and preserves subscriptions' \
  'unacknowledged qos1 replay keeps packet id and sets dup' \
  'offline persistent session queues qos1 but drops qos0' \
  'puback promotes pending qos1 in fifo order' \
  'clean session discards previous persistent state' \
  'qos1 will survives offline routing and reconnect' \
  'session inflight and pending limits are atomic' \
  'snapshot roundtrip preserves persistent qos1 state' \
  'snapshot import rejects corruption without partial state' \
  'restored broker state resumes before accept'; do
  if ! grep -RqsE "^(async )?test \"${required_test}\" \{" src; then
    echo "QOS1 acceptance test is missing: ${required_test}" >&2
    exit 1
  fi
done

moon test --target native
moon build --target native
tests/integration/qos1_interop.sh
echo 'QOS1 verification passed'
