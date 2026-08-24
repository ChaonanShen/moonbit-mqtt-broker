#!/usr/bin/env bash
# Read-only release preflight. Never publishes, pushes, or creates a release.
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

readonly EXPECTED_SHA="${RELEASE_SHA:-$(git rev-parse HEAD)}"
readonly PACKAGE="${RELEASE_PACKAGE_PATH:-${REPO_ROOT}/_build/publish/ChaonanShen-moonbit-mqtt-broker-0.1.0.zip}"
[[ "$(git rev-parse HEAD)" = "${EXPECTED_SHA}" ]]
[[ -z "$(git status --porcelain --untracked-files=all)" ]]
git remote get-url origin | grep -Eq '(^|[:/])ChaonanShen/moonbit-mqtt-broker(\.git)?$'
scripts/check-docs.sh
test -f "${PACKAGE}"
sha256sum "${PACKAGE}"
unzip -Z1 "${PACKAGE}" | wc -l
stat -c '%s bytes' "${PACKAGE}"

if git rev-parse -q --verify refs/tags/v0.1.0 >/dev/null; then
  [[ "$(git rev-list -n 1 v0.1.0)" = "${EXPECTED_SHA}" ]]
else
  echo 'v0.1.0 tag is not present (expected before tag creation)'
fi
if [[ -n "${RELEASE_VERIFIER_RECORD:-}" ]]; then
  test -r "${RELEASE_VERIFIER_RECORD}"
  [[ "$(grep -c '^PASS ' "${RELEASE_VERIFIER_RECORD}")" -ge 3 ]]
  grep -q '^SOAK PASS ' "${RELEASE_VERIFIER_RECORD}"
else
  echo 'RELEASE_VERIFIER_RECORD is not set; verifier/soak evidence is required before publish' >&2
  exit 1
fi
if [[ -n "${MOON_CREDENTIALS_PATH:-}" ]]; then
  test -r "${MOON_CREDENTIALS_PATH}"
  echo 'Mooncakes credential mount is readable (contents not inspected)'
fi
echo "Release preflight passed for ${EXPECTED_SHA}; no external writes performed"
