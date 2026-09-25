#!/usr/bin/env bash
# Gate: release metadata is consistently versioned 0.3.0
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

for file in README*.md docs/*.md; do
  while IFS= read -r target; do
    target="${target#(}"
    target="${target%)}"
    [[ "${target}" = http://* || "${target}" = https://* ]] && continue
    [[ -e "$(dirname "${file}")/${target}" ]] || { echo "broken link in ${file}: ${target}" >&2; exit 1; }
  done < <(rg -o '\([^ )#]+\.(md|sh)\)' "${file}" || true)
done

# Mooncakes turns relative Markdown links into raw source assets without a UTF-8
# charset. Published documentation must link to rendered, versioned pages.
node <<'JS'
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const base = 'https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/';
const files = execFileSync('git', ['-c', 'safe.directory=/workspace', 'ls-files', '--', 'README*.md', 'docs/*.md'],
  { encoding: 'utf8' }).trim().split('\n');
for (const source of files) {
  const markdown = fs.readFileSync(source, 'utf8');
  for (const [, target] of markdown.matchAll(/\]\(([^)\s]+)\)/g)) {
    const document = target.split('#', 1)[0];
    if (!document.endsWith('.md')) continue;
    if (document.startsWith(base)) {
      const dest = document.slice(base.length);
      if (!fs.existsSync(dest) || !fs.statSync(dest).isFile()) {
        throw new Error(`broken versioned documentation link: ${source}: ${target}`);
      }
    } else if (!document.includes('://')) {
      throw new Error(`raw Mooncakes documentation link: ${source}: ${target}`);
    }
  }
}
JS

grep -Eq '^version = "0\.3\.0"$' moon.mod
grep -Eq '^const RELEASE_VERSION : String = "0\.3\.0"$' src/cmd/broker/main.mbt
grep -Fq '("version", "0.3.0")' src/server/broker_runtime.mbt
grep -Fq "!== '0.3.0'" tests/integration/observability.mjs
grep -Fq "= '0.3.0'" tests/integration/release_smoke.sh
grep -Fq 'moonbit-mqtt-broker-0.3.0.zip' scripts/check-package.sh
grep -Eq '^## \[0\.3\.0\]$' CHANGELOG.md
grep -q 'MQTT 5' README.md
grep -q 'QoS 2' README.md
grep -q 'strict local durability' README.md
grep -q 'latest-committed' README.md
grep -q 'Linux x86_64' README.md
if internal_labels="$(git -c safe.directory="${REPO_ROOT}" grep -n -I -i -E 'P0-(01|02|03)' -- '*.md' ':!AGENTS.md')"; then
  printf '%s\n' "${internal_labels}"
  echo 'public documentation must use feature names instead of internal milestone labels' >&2
  exit 1
else
  label_status=$?
  [[ "${label_status}" -eq 1 ]] || exit "${label_status}"
fi
echo 'RELEASE documentation links, support contract, and version are consistent'
