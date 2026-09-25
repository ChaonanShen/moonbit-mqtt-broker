#!/usr/bin/env bash
# Read-only release preflight. Never publishes, pushes, tags or creates a release.
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

readonly EXPECTED_VERSION="${RELEASE_VERSION:-0.3.0}"
readonly EXPECTED_SHA="${RELEASE_SHA:-$(git rev-parse HEAD)}"
readonly PACKAGE="${RELEASE_PACKAGE_PATH:-${REPO_ROOT}/_build/publish/ChaonanShen-moonbit-mqtt-broker-${EXPECTED_VERSION}.zip}"
readonly EVIDENCE_DIR="${RELEASE_EVIDENCE_DIR:-}"
readonly RELEASE_TAG="v${EXPECTED_VERSION}"

[[ "$(git rev-parse HEAD)" = "${EXPECTED_SHA}" ]]
[[ -z "$(git status --porcelain --untracked-files=no)" ]]
while IFS= read -r -d '' file; do
  case "${file}" in
    AGENTS.md|AGENTS.local.md) ;;
    *) echo "Untracked candidate file must be committed or ignored first: ${file}" >&2; exit 1 ;;
  esac
done < <(git ls-files --others --exclude-standard -z)
git remote get-url origin | grep -Eq '(^|[:/])ChaonanShen/moonbit-mqtt-broker(\.git)?$'
scripts/check-docs.sh
grep -Eq "^version = \"${EXPECTED_VERSION//./\.}\"$" moon.mod

test -f "${PACKAGE}"
[[ -n "${EVIDENCE_DIR}" ]] || { echo 'RELEASE_EVIDENCE_DIR is required' >&2; exit 1; }
test -r "${EVIDENCE_DIR}/evidence.txt"
test -r "${EVIDENCE_DIR}/artifacts.sha256"
test -r "${EVIDENCE_DIR}/package.zip"
grep -Fx "source_commit=${EXPECTED_SHA}" "${EVIDENCE_DIR}/evidence.txt"
grep -Fx 'soak=1' "${EVIDENCE_DIR}/evidence.txt"
for profile in base argon2 tls full; do
  grep -Fx "runtime_${profile}=PASS" "${EVIDENCE_DIR}/evidence.txt"
done
grep -Fx 'exit_code=0' "${EVIDENCE_DIR}/evidence.txt"
grep -q '^completed_at=' "${EVIDENCE_DIR}/evidence.txt"
(
  cd "${EVIDENCE_DIR}"
  sha256sum --check artifacts.sha256
)
cmp --silent "${PACKAGE}" "${EVIDENCE_DIR}/package.zip"
sha256sum "${PACKAGE}"
unzip -Z1 "${PACKAGE}" | wc -l
stat -c '%s bytes' "${PACKAGE}"

if git rev-parse -q --verify "refs/tags/${RELEASE_TAG}" >/dev/null; then
  [[ "$(git rev-list -n 1 "${RELEASE_TAG}")" = "${EXPECTED_SHA}" ]]
else
  echo "${RELEASE_TAG} tag is not present (expected before tag creation)"
fi
if [[ -n "${MOON_CREDENTIALS_PATH:-}" ]]; then
  test -r "${MOON_CREDENTIALS_PATH}"
  echo 'Mooncakes credential mount is readable (contents not inspected)'
fi
echo "Release preflight passed for ${EXPECTED_VERSION} at ${EXPECTED_SHA}; no external writes performed"
