#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

source_stage="$(mktemp -d)"
clean_room="$(mktemp -d)"
package_list="$(mktemp)"
cleanup() { rm -rf "${source_stage}" "${clean_room}"; rm -f "${package_list}"; }
trap cleanup EXIT

git ls-files --cached --others --exclude-standard -z \
  | tar --null -T - -cf - \
  | tar -xf - -C "${source_stage}"
(
  cd "${source_stage}"
  moon update
  moon check --target native
  moon package --frozen --list >/dev/null 2>&1
  moon package --frozen >/dev/null 2>&1
)
readonly STAGED_PACKAGE="${source_stage}/_build/publish/ChaonanShen-moonbit-mqtt-broker-0.1.0.zip"
test -f "${STAGED_PACKAGE}"
unzip -Z1 "${STAGED_PACKAGE}" >"${package_list}"
if grep -Eiq '(^|/)(\.git|_build|target|\.moon(cakes)?|node_modules|test-results|coverage|tmp)(/|$)|(^|/)\.env($|\.)|\.local($|\.)|broker\.snapshot|broker\.lock|\.DS_Store|credentials' "${package_list}"; then
  echo 'release package contains a denied local/cache/credential/runtime path' >&2
  exit 1
fi
for required in moon.mod README.md LICENSE CHANGELOG.md THIRD_PARTY_NOTICES.md \
  docs/release.md examples/basic_pubsub.sh src/cmd/broker/main.mbt; do
  grep -qx "${required}" "${package_list}" || { echo "release package missing ${required}" >&2; exit 1; }
done
if grep -Ev '^(moon\.mod|README\.md|LICENSE|CHANGELOG\.md|THIRD_PARTY_NOTICES\.md|Dockerfile|\.gitignore|docs/|examples/|scripts/|src/|tests/|tools/)' "${package_list}" | grep -q .; then
  echo 'release package contains a path outside the top-level allowlist' >&2
  exit 1
fi

readonly PACKAGE="${REPO_ROOT}/_build/publish/ChaonanShen-moonbit-mqtt-broker-0.1.0.zip"
mkdir -p "$(dirname "${PACKAGE}")"
cp "${STAGED_PACKAGE}" "${PACKAGE}"
file_count="$(unzip -Z1 "${PACKAGE}" | wc -l | tr -d ' ')"
uncompressed_bytes="$(unzip -l "${PACKAGE}" | tail -n 1 | awk '{print $1}')"
package_bytes="$(stat -c %s "${PACKAGE}")"
[[ "${file_count}" -le 500 ]]
[[ "${uncompressed_bytes}" -le 20971520 ]]
[[ "${package_bytes}" -le 10485760 ]]

unzip -q "${PACKAGE}" -d "${clean_room}"
if find "${clean_room}" -type d \( -name _build -o -name .mooncakes -o -name node_modules \) -print -quit | grep -q .; then
  echo 'packaged archive contains a build or dependency cache' >&2
  exit 1
fi
(
  cd "${clean_room}"
  moon update
  moon check --target native
  moon check --target native --frozen
  moon build --target native --frozen
  version="$(moon run --target native src/cmd/broker -- --version)"
  [[ "${version}" = '0.1.0' ]]
)

sha256="$(sha256sum "${PACKAGE}" | awk '{print $1}')"
echo "M5_PACKAGE=${PACKAGE}"
echo "M5_PACKAGE_SHA256=${sha256} FILES=${file_count} ZIP_BYTES=${package_bytes} UNCOMPRESSED_BYTES=${uncompressed_bytes}"
echo 'M5 clean-room release package audit passed'
