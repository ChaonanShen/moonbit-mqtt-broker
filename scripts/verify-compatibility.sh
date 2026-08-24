#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

scripts/verify-persistence.sh
npm ci --prefix tools/reference_brokers --ignore-scripts
moon fmt --check
moon check --target native --frozen

readonly RELEASE_TEST_COUNT="$(grep -RhE '^(async )?test "' src | wc -l | tr -d ' ')"
if [[ "${RELEASE_TEST_COUNT}" -lt 186 ]]; then
  echo "RELEASE acceptance suite has only ${RELEASE_TEST_COUNT} MoonBit tests; expected at least 186" >&2
  exit 1
fi
for gate in \
  'mqtt311 final packet matrix matches supported contract' \
  'reference brokers agree on common mqtt311 behavior' \
  'one hundred clients connect ping and disconnect concurrently' \
  'ten thousand qos0 messages preserve sequence without global stall' \
  'ten persistent sessions drain one hundred offline qos1 messages each' \
  'slow consumer is isolated while healthy clients continue' \
  'connection churn returns file descriptors to bounded baseline' \
  'repeated committed restarts preserve current state without snapshot growth' \
  'broker help has no filesystem or listener side effects' \
  'basic publish subscribe example passes' \
  'persistent session example passes' \
  'restart persistence example passes' \
  'release package excludes local cache credentials and runtime state' \
  'release package builds and runs outside the source checkout' \
  'release metadata is consistently versioned 0.1.0'; do
  rg -qF "${gate}" scripts tests/integration || { echo "RELEASE exact gate is missing: ${gate}" >&2; exit 1; }
done

moon test --target native --frozen
moon build --target native --frozen
while IFS= read -r script; do bash -n "${script}"; done < <(git ls-files '*.sh')
while IFS= read -r script; do node --check "${script}"; done < <(git ls-files '*.mjs')
scripts/check-docs.sh
tests/integration/reference_capability.sh
tests/integration/protocol_matrix.sh
tests/integration/reference_diff.sh
tests/integration/stability.sh
tests/integration/release_smoke.sh
scripts/check-package.sh

if git ls-files | rg -q '(^|/).*\.local(\.|$)|(^|/)(node_modules|_build|\.mooncakes)(/|$)|pkg\.generated\.mbti$|broker\.snapshot|credentials|(^|/)\.env($|\.)'; then
  echo 'tracked local/generated/cache/credential/runtime artifact detected' >&2
  exit 1
fi
echo "RELEASE verification passed (${RELEASE_TEST_COUNT} MoonBit tests, soak=${RELEASE_SOAK:-0})"
