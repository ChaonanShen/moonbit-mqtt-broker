#!/usr/bin/env bash
# Gate: release metadata is consistently versioned 0.1.0
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

for file in README.md docs/*.md; do
  while IFS= read -r target; do
    target="${target#(}"
    target="${target%)}"
    [[ "${target}" = http://* || "${target}" = https://* ]] && continue
    [[ -e "$(dirname "${file}")/${target}" ]] || { echo "broken link in ${file}: ${target}" >&2; exit 1; }
  done < <(rg -o '\([^ )#]+\.(md|sh)\)' "${file}" || true)
done

grep -Eq '^version = "0\.1\.0"$' moon.mod
grep -Eq '^const RELEASE_VERSION : String = "0\.1\.0"$' src/cmd/broker/main.mbt
grep -Eq '^## \[0\.1\.0\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$' CHANGELOG.md
grep -q 'MQTT 5' README.md
grep -q 'QoS 2' README.md
grep -q 'zero-loss durability' README.md
grep -q 'latest-committed' README.md
grep -q 'Linux x86_64' README.md
echo 'RELEASE documentation links, support contract, and version are consistent'
