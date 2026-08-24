#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

scripts/m3-verify.sh
moon fmt --check
moon check --target native
moon test --target native
moon build --target native

readonly M4_TEST_COUNT="$(grep -RhE '^(async )?test "' src | wc -l | tr -d ' ')"
if [[ "${M4_TEST_COUNT}" -lt 186 ]]; then
  echo "M4 acceptance suite has only ${M4_TEST_COUNT} tests; expected at least 186" >&2
  exit 1
fi

for required_test in \
  'snapshot codec is deterministic and checksum protected' \
  'snapshot decoder rejects truncation before allocation' \
  'atomic save preserves previous snapshot on failure' \
  'stale temp never replaces committed snapshot' \
  'second broker cannot acquire snapshot lock' \
  'debounce collapses revisions and max delay forces commit' \
  'failed save retries latest snapshot without blocking router' \
  'exact snapshot size limit is accepted and plus one rejected' \
  'clean sessions are absent from disk snapshot'; do
  if ! grep -RqsE "^(async )?test \"${required_test}\" \{" src; then
    echo "M4 acceptance test is missing: ${required_test}" >&2
    exit 1
  fi
done

for required_integration in \
  'retained state survives broker restart' \
  'persistent subscriptions survive broker restart' \
  'offline qos1 fifo survives broker restart' \
  'inflight qos1 keeps packet id and dup after broker restart' \
  'next packet id survives broker restart' \
  'startup rejects corrupt snapshot before listen'; do
  if ! grep -RqsF "${required_integration}" tests/integration/m4_*.sh; then
    echo "M4 integration gate is missing: ${required_integration}" >&2
    exit 1
  fi
done

if rg -q 'moonbitlang/async/fs' src/router src/session src/topic; then
  echo 'Router/session/topic package purity violation: filesystem import' >&2
  exit 1
fi
if rg -q 'moonbit-mqtt-broker/(server|protocol_adapter)|async/socket' src/persistence; then
  echo 'Persistence package purity violation: server/protocol/socket import' >&2
  exit 1
fi
tests/integration/m4_restart.sh
tests/integration/m4_crash.sh
tests/integration/m4_interop.sh

if git ls-files | rg -q '(^|/).*\.local(\.|$)|pkg\.generated\.mbti$|broker\.snapshot|broker\.snapshot\.tmp'; then
  echo 'Tracked local/generated/snapshot artifact detected' >&2
  exit 1
fi

echo "M4 verification passed (${M4_TEST_COUNT} tests)"
